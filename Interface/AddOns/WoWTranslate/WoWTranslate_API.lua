-- WoWTranslate_API.lua
-- DLL communication via UnitXP interface
-- Handles async translation requests and polling
-- v0.13: Removed credit tracking; Translate() now accepts fromLang parameter

WoWTranslate_API = {}

-- Internal state
local pendingRequests = {}
local pendingTexts = {}   -- text -> requestId; deduplicates identical in-flight requests
local dllAvailable = false
local requestCounter = 0
local pollFrame = nil
local activePendingCount = 0
local healthCheckElapsed = 0
local HEALTH_CHECK_INTERVAL = 60  -- Re-ping DLL every 60s; wakes HTTP client after alt-tab
local lastCallbackError = nil     -- last error captured from a pcall'd callback

-- Backoff state: tracks consecutive "API error" responses (the error the DLL
-- returns when Google's response body can't be parsed — the most common cause is
-- a 429 rate-limit page that contains no [[[...]] translation array).
-- "network error" and "timeout" are NOT counted — they are transient and shouldn't
-- suppress future requests.  Three consecutive API errors trigger a backoff.
local consecutiveApiErrors = 0
local rateLimitedUntil     = 0    -- GetTime() timestamp; 0 = not limited
local rateLimitBackoff     = 15   -- current backoff seconds (doubles on each hit, cap 300)
local BACKOFF_TRIGGER      = 3    -- how many consecutive API errors before backing off
local lastError            = nil  -- last provider error reported by the DLL

-- Constants
local POLL_INTERVAL = 0.1   -- Poll every 100ms
local REQUEST_TIMEOUT = 30  -- Timeout requests after 30 seconds
local MAX_PENDING = 4        -- Max concurrent DLL requests; prevents queue overflow

-- ============================================================================
-- LUA 5.0 COMPATIBILITY
-- ============================================================================
-- strsplit is not available in WoW 1.12, implement it
local function strsplit(delimiter, text, limit)
    if not text then return nil end
    if not delimiter or delimiter == "" then return text end

    local result = {}
    local count = 0
    local start = 1
    local delimStart, delimEnd = string.find(text, delimiter, start, true)

    while delimStart do
        count = count + 1
        if limit and count >= limit then
            break
        end
        table.insert(result, string.sub(text, start, delimStart - 1))
        start = delimEnd + 1
        delimStart, delimEnd = string.find(text, delimiter, start, true)
    end

    table.insert(result, string.sub(text, start))
    return unpack(result)
end

-- ============================================================================
-- MINIMAL JSON READER (for the fixed provider_status shape the DLL returns)
-- ============================================================================
local function trim(text)
    return string.gsub(text or "", "^%s*(.-)%s*$", "%1")
end

local function JsonUnescape(value)
    if not value then return "" end

    local result = ""
    local i = 1
    while i <= string.len(value) do
        local ch = string.sub(value, i, i)
        if ch == "\\" and i < string.len(value) then
            local nextCh = string.sub(value, i + 1, i + 1)
            if nextCh == "\"" then result = result .. "\""
            elseif nextCh == "\\" then result = result .. "\\"
            elseif nextCh == "/" then result = result .. "/"
            elseif nextCh == "n" then result = result .. "\n"
            elseif nextCh == "r" then result = result .. "\r"
            elseif nextCh == "t" then result = result .. "\t"
            elseif nextCh == "b" then result = result .. "\b"
            elseif nextCh == "f" then result = result .. "\f"
            elseif nextCh == "u" and i + 5 <= string.len(value) then
                -- DLL emits UTF-8 directly for normal text; keep uncommon escapes readable.
                result = result .. "?"
                i = i + 4
            else
                result = result .. nextCh
            end
            i = i + 2
        else
            result = result .. ch
            i = i + 1
        end
    end

    return result
end

local function JsonGetRaw(jsonText, key)
    if not jsonText or not key then return nil end

    local search = "\"" .. key .. "\""
    local keyStart, keyEnd = string.find(jsonText, search, 1, true)
    if not keyStart then return nil end

    local colon = string.find(jsonText, ":", keyEnd + 1, true)
    if not colon then return nil end

    local start = colon + 1
    while start <= string.len(jsonText) do
        local ch = string.sub(jsonText, start, start)
        if ch ~= " " and ch ~= "\t" and ch ~= "\n" and ch ~= "\r" then
            break
        end
        start = start + 1
    end

    if string.sub(jsonText, start, start) == "\"" then
        local pos = start + 1
        while pos <= string.len(jsonText) do
            local ch = string.sub(jsonText, pos, pos)
            if ch == "\\" then
                pos = pos + 2
            elseif ch == "\"" then
                return string.sub(jsonText, start + 1, pos - 1), true
            else
                pos = pos + 1
            end
        end
        return nil
    end

    local finish = start
    while finish <= string.len(jsonText) do
        local ch = string.sub(jsonText, finish, finish)
        if ch == "," or ch == "}" then
            break
        end
        finish = finish + 1
    end

    return trim(string.sub(jsonText, start, finish - 1)), false
end

local function JsonGetString(jsonText, key)
    local raw, quoted = JsonGetRaw(jsonText, key)
    if raw == nil then return nil end
    if quoted then
        return JsonUnescape(raw)
    end
    if raw == "null" then return nil end
    return raw
end

local function JsonGetBool(jsonText, key)
    local raw = JsonGetRaw(jsonText, key)
    return raw == "true"
end

local function JsonGetNumber(jsonText, key)
    local raw = JsonGetRaw(jsonText, key)
    if raw then return tonumber(raw) end
    return nil
end

local function ParseBridgeResult(result)
    if result == "ok" then
        return true, nil
    end
    if result and string.find(result, "error|", 1, true) == 1 then
        return false, string.sub(result, 7)
    end
    return true, nil
end

-- ============================================================================
-- DLL STATUS FUNCTIONS
-- ============================================================================

-- Check if DLL is loaded and responding
function WoWTranslate_API.CheckDLL()
    if UnitXP then
        local success, result = pcall(function()
            return UnitXP("WoWTranslate", "ping")
        end)
        if success and result == "pong" then
            dllAvailable = true
            return true
        end
    end
    dllAvailable = false
    return false
end

-- Get DLL status
function WoWTranslate_API.IsAvailable()
    return dllAvailable
end

-- ============================================================================
-- DEMAND-BASED POLLING HELPERS
-- ============================================================================

-- Called when a new request is queued
local function OnRequestQueued()
    activePendingCount = activePendingCount + 1
    if not pollFrame then
        WoWTranslate_API.StartPolling()
    end
end

-- Called when a request completes or times out
local function OnRequestCompleted()
    activePendingCount = activePendingCount - 1
    if activePendingCount <= 0 then
        activePendingCount = 0
        WoWTranslate_API.StopPolling()
    end
end

-- ============================================================================
-- TRANSLATION FUNCTIONS
-- ============================================================================

-- Request an async translation
-- callback(translation, error) will be called when complete
function WoWTranslate_API.Translate(text, callback, fromLang)
    if not dllAvailable then
        if callback then
            callback(nil, "DLL not available")
        end
        return false
    end

    if not text or text == "" then
        if callback then
            callback(nil, "Empty text")
        end
        return false
    end

    -- Silently skip when the DLL queue is already full.
    -- Excess requests would be dropped by the DLL internally, leaving Lua-side
    -- pendingRequests entries that only time out after 30s, degrading the DLL state.
    if activePendingCount >= MAX_PENDING then
        return false
    end

    -- Silently skip during API error backoff window.
    if GetTime() < rateLimitedUntil then
        return false
    end

    -- Deduplicate: the same chat message fires in every chat frame at once, producing
    -- 4-5 identical requests before any result is cached.  Only the first needs to go
    -- to the DLL; the rest will get a cache hit when the first callback completes.
    if pendingTexts[text] then
        return false
    end

    -- Generate unique request ID
    requestCounter = requestCounter + 1
    local requestId = tostring(requestCounter)

    -- Store pending request
    pendingRequests[requestId] = {
        callback = callback,
        text = text,
        timestamp = GetTime()
    }
    pendingTexts[text] = requestId

    -- Send request to DLL with caller-detected source language
    fromLang = fromLang or "zh"
    local toLang = WoWTranslateDB and WoWTranslateDB.incomingToLang or "en"
    local success, err = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, text, fromLang, toLang)
    end)

    if not success then
        pendingRequests[requestId] = nil
		pendingTexts[text] = nil 
        if callback then
            callback(nil, "DLL call failed: " .. tostring(err))
        end
        return false
    end

    OnRequestQueued()
    return true, requestId
end

-- ============================================================================
-- POLLING SYSTEM
-- ============================================================================

-- Poll DLL for completed translations
local function PollTranslations()
    if not dllAvailable then return end

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "poll")
    end)

    if not success then
        -- UnitXP call itself threw — DLL is gone or broken
        dllAvailable = false
        return
    end

    if success and result and result ~= "" then
        -- Parse result format: "requestId|translation|error"
        local firstPipe = string.find(result, "|", 1, true)
        if firstPipe then
            local requestId = string.sub(result, 1, firstPipe - 1)
            local remainder = string.sub(result, firstPipe + 1)

            local secondPipe = string.find(remainder, "|", 1, true)
            local translation, err
            if secondPipe then
                translation = string.sub(remainder, 1, secondPipe - 1)
                err = string.sub(remainder, secondPipe + 1)
            else
                translation = remainder
                err = ""
            end

            if requestId and pendingRequests[requestId] then
                local req = pendingRequests[requestId]
                pendingRequests[requestId] = nil
                pendingTexts[req.text] = nil
                OnRequestCompleted()

                if req.callback then
                    -- pcall prevents a callback error from disabling the pollFrame OnUpdate.
                    -- Capture errors so /wt status can surface them for diagnosis.
                    local _cbOk, _cbErr
                    if err and err ~= "" then
                        if err == "rate limited" then
                            -- DLL confirmed HTTP 429: back off immediately on first hit.
                            rateLimitedUntil     = GetTime() + rateLimitBackoff
                            rateLimitBackoff     = math.min(rateLimitBackoff * 2, 300)
                            consecutiveApiErrors = 0
                        elseif err == "API error" then
                            -- Generic parse failure: could be an undetected rate-limit
                            -- variant or a content-policy block.  Back off after
                            -- BACKOFF_TRIGGER consecutive hits as a safety net.
                            consecutiveApiErrors = consecutiveApiErrors + 1
                            if consecutiveApiErrors >= BACKOFF_TRIGGER then
                                rateLimitedUntil     = GetTime() + rateLimitBackoff
                                rateLimitBackoff     = math.min(rateLimitBackoff * 2, 300)
                                consecutiveApiErrors = 0
                            end
                        else
                            -- "network error", "timeout", etc. — transient, don't count.
                            consecutiveApiErrors = 0
                        end
                        _cbOk, _cbErr = pcall(req.callback, nil, err)
                    else
                        -- Successful response: reset everything.
                        consecutiveApiErrors = 0
                        rateLimitBackoff     = 15
                        _cbOk, _cbErr = pcall(req.callback, translation, nil)
                    end
                    if not _cbOk then
                        lastCallbackError = tostring(_cbErr)
                    end
                end
            end
        end
    end

    -- Cleanup timed-out requests
    local now = GetTime()
    for id, req in pairs(pendingRequests) do
        if now - req.timestamp > REQUEST_TIMEOUT then
            pendingRequests[id] = nil
            pendingTexts[req.text] = nil
            OnRequestCompleted()
            if req.callback then
                pcall(req.callback, nil, "Request timed out")  -- pcall: don't break polling on error
            end
        end
    end
end

-- Start the polling frame
function WoWTranslate_API.StartPolling()
    if pollFrame then return end

    pollFrame = CreateFrame("Frame")
    local elapsed = 0

    pollFrame:SetScript("OnUpdate", function()
        elapsed = elapsed + arg1
        if elapsed >= POLL_INTERVAL then
            elapsed = 0
            PollTranslations()
        end
    end)
end

-- Stop the polling frame
function WoWTranslate_API.StopPolling()
    if pollFrame then
        pollFrame:SetScript("OnUpdate", nil)
        pollFrame = nil
    end
end

-- Passive health check: re-ping DLL every 60s so we detect silent failure and
-- keep the DLL's HTTP connection warm (prevents alt-tab stall).
local healthCheckFrame = CreateFrame("Frame")
healthCheckFrame:SetScript("OnUpdate", function()
    healthCheckElapsed = healthCheckElapsed + arg1
    if healthCheckElapsed >= HEALTH_CHECK_INTERVAL then
        healthCheckElapsed = 0
        WoWTranslate_API.CheckDLL() -- always; restores dllAvailable if DLL recovers
    end
end)

-- ============================================================================
-- OUTGOING TRANSLATION (English -> Chinese)
-- ============================================================================

-- Request an async outgoing translation (en -> zh)
-- callback(translation, error) will be called when complete
function WoWTranslate_API.TranslateOutgoing(text, callback)
    if not dllAvailable then
        if callback then
            callback(nil, "DLL not available")
        end
        return false
    end

    if not text or text == "" then
        if callback then
            callback(nil, "Empty text")
        end
        return false
    end

    if activePendingCount >= MAX_PENDING then
        if callback then callback(nil, "Queue full, try again shortly") end
        return false
    end

    if GetTime() < rateLimitedUntil then
        return false
    end

    -- Generate unique request ID with "out_" prefix to distinguish from incoming
    requestCounter = requestCounter + 1
    local requestId = "out_" .. tostring(requestCounter)

    -- Store pending request
    pendingRequests[requestId] = {
        callback = callback,
        text = text,
        timestamp = GetTime()
    }

    -- Send request to DLL with configurable language direction
    local fromLang = WoWTranslateDB and WoWTranslateDB.outgoingFromLang or "en"
    local toLang = WoWTranslateDB and WoWTranslateDB.outgoingToLang or "zh"
    local success, err = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, text, fromLang, toLang)
    end)

    if not success then
        pendingRequests[requestId] = nil
		pendingTexts[text] = nil 
        if callback then
            callback(nil, "DLL call failed: " .. tostring(err))
        end
        return false
    end

    OnRequestQueued()
    return true, requestId
end

-- Request an async back-translation of what was sent (zh -> en by default).
-- Separate from Translate() so incoming-message dedup cannot steal the slot.
function WoWTranslate_API.TranslateBack(text, callback)
    if not dllAvailable then
        if callback then
            callback(nil, "DLL not available")
        end
        return false
    end

    if not text or text == "" then
        if callback then
            callback(nil, "Empty text")
        end
        return false
    end

    if activePendingCount >= MAX_PENDING then
        if callback then callback(nil, "Queue full, try again shortly") end
        return false
    end

    if GetTime() < rateLimitedUntil then
        if callback then callback(nil, "Rate limited") end
        return false
    end

    requestCounter = requestCounter + 1
    local requestId = "back_" .. tostring(requestCounter)

    pendingRequests[requestId] = {
        callback = callback,
        text = text,
        timestamp = GetTime()
    }

    local fromLang = WoWTranslateDB and WoWTranslateDB.outgoingToLang or "zh"
    local toLang = WoWTranslateDB and WoWTranslateDB.outgoingFromLang or "en"
    local success, err = pcall(function()
        UnitXP("WoWTranslate", "translate_async", requestId, text, fromLang, toLang)
    end)

    if not success then
        pendingRequests[requestId] = nil
        if callback then
            callback(nil, "DLL call failed: " .. tostring(err))
        end
        return false
    end

    OnRequestQueued()
    return true, requestId
end

-- ============================================================================
-- BACKOFF FUNCTIONS
-- ============================================================================

-- Returns: isLimited (bool), secondsRemaining (int, 0 if not limited)
function WoWTranslate_API.GetRateLimitInfo()
    local remaining = rateLimitedUntil - GetTime()
    if remaining > 0 then
        return true, math.ceil(remaining)
    end
    return false, 0
end

-- Reset backoff state; called by /wt reset so a manual recovery clears the window.
function WoWTranslate_API.ResetBackoff()
    consecutiveApiErrors = 0
    rateLimitedUntil     = 0
    rateLimitBackoff     = 15
end

-- ============================================================================
-- PROVIDER STATUS + CONFIGURATION
-- ============================================================================
function WoWTranslate_API.GetLastError()
    if dllAvailable and UnitXP then
        local success, result = pcall(function()
            return UnitXP("WoWTranslate", "last_error")
        end)
        if success and result and result ~= "" then
            lastError = result
        end
    end
    return lastError
end

function WoWTranslate_API.GetProviderStatus()
    local status = {
        provider = WoWTranslateDB and WoWTranslateDB.provider or "google_free",
        configured = false,
        ready = false,
        endpoint = "",
        lastHttpStatus = 0,
    }

    if not dllAvailable or not UnitXP then
        return status
    end

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "provider_status")
    end)

    if success and result and result ~= "" then
        status.provider = JsonGetString(result, "provider") or status.provider
        status.configured = JsonGetBool(result, "configured")
        status.ready = JsonGetBool(result, "ready")
        status.endpoint = JsonGetString(result, "endpoint") or ""
        status.lastHttpStatus = JsonGetNumber(result, "lastHttpStatus") or 0
    end

    return status
end

-- Switches back to the free translate.googleapis.com (gtx) endpoint. No key needed.
function WoWTranslate_API.ConfigureGoogleFree()
    if not dllAvailable then
        return false, "DLL not available"
    end

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "configure_google_free")
    end)

    if not success then
        lastError = tostring(result)
        return false, lastError
    end

    local ok, err = ParseBridgeResult(result)
    lastError = err
    return ok, err
end

-- Points the translator at a user-supplied HTTPS JSON endpoint.
--   endpoint        - required, must be https://...
--   apiKey          - optional; sent as "<authScheme> <apiKey>" in the authHeader header
--   authHeader      - defaults to "Authorization"
--   authScheme      - defaults to "Bearer"; use "none" to send apiKey with no prefix
--   requestTemplate - JSON body sent with every request; {text}/{source}/{target} are substituted
--   responsePath    - dotted/bracketed path to the translation in the JSON response
function WoWTranslate_API.ConfigureCustomHttp(endpoint, apiKey, authHeader, authScheme, requestTemplate, responsePath)
    if not dllAvailable then
        return false, "DLL not available"
    end

    if not endpoint or endpoint == "" then
        return false, "endpoint required"
    end

    local success, result = pcall(function()
        return UnitXP("WoWTranslate", "configure_custom",
            endpoint,
            apiKey or "",
            authHeader or "Authorization",
            authScheme or "Bearer",
            requestTemplate or "",
            responsePath or "translation")
    end)

    if not success then
        lastError = tostring(result)
        return false, lastError
    end

    local ok, err = ParseBridgeResult(result)
    lastError = err
    return ok, err
end

-- ============================================================================
-- DEBUG FUNCTIONS
-- ============================================================================

-- Get pending request count
function WoWTranslate_API.GetPendingCount()
    local count = 0
    for _ in pairs(pendingRequests) do
        count = count + 1
    end
    return count
end

-- Get last error thrown by a callback (nil if no error yet)
function WoWTranslate_API.GetLastCallbackError()
    return lastCallbackError
end

-- Clear all pending requests (used by /wt reset for recovery)
function WoWTranslate_API.ClearPending()
    for id, req in pairs(pendingRequests) do
        if req.callback then
            pcall(req.callback, nil, "Cleared by reset")
        end
        pendingRequests[id] = nil
    end
    pendingTexts = {}
    activePendingCount = 0
    WoWTranslate_API.StopPolling()
end

-- Get all pending request info (for debugging)
function WoWTranslate_API.GetPendingRequests()
    local info = {}
    local now = GetTime()
    for id, req in pairs(pendingRequests) do
        table.insert(info, {
            id = id,
            text = req.text,
            age = now - req.timestamp
        })
    end
    return info
end

