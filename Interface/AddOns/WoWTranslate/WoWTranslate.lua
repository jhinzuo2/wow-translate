-- WoWTranslate.lua
-- Main addon file: chat hooks, display, and coordination
-- Chinese to English translation for WoW 1.12

-- ============================================================================
-- SAVED VARIABLES (initialized on load)
-- ============================================================================
WoWTranslateDB = WoWTranslateDB or {}
WoWTranslateDebugLog = WoWTranslateDebugLog or {}

-- ============================================================================
-- LOCAL STATE
-- ============================================================================
local DEBUG_MODE = false
local addonLoaded = false
local originalAddMessage = nil
local playerIsAFK = false
local dllWarnShown = false
local translationErrWarnShown = false
local hookCallCount = 0         -- incremented every time any hook body executes

local pendingMessages = {}
local messageCounter = 0

-- Maps capturedArg1 (raw message text) -> {frame -> true}
-- Collects every chat frame that showed the original Chinese message so the async
-- translation callback can post to all of them.  Multiple frames fire the same
-- OnEvent for one message; dedup lets only the first reach the DLL, but all frames
-- that displayed the original must also show the translation.
local frameTranslationTargets = {}

-- Waiters for in-flight player-name translations (rawName -> { callbacks = {} })
local pendingNameTranslations = {}
local wtNamePollFrame = nil

-- Outgoing translation state
local outgoingQueue = {}
local outgoingCounter = 0
local originalSendChatMessage = SendChatMessage

-- WIM integration state
local wimHookInstalled = false
local wimWhoInfoHookInstalled = false
local wimOrigPost = nil
local wimOutgoingPending = {}   -- [user] -> { original, translated, time, displayed }
local wimPostedMessages = {}    -- [msgText] -> timestamp (dedup per whisper)
local wtFriendTransCache = {}   -- [name] -> translated string or false
local wtFriendTransPending = {} -- [name] -> true while API in flight
local wtFriendsListHookInstalled = false

-- Pre-translated prefixes for outgoing messages (zero API cost)
local TRANSLATED_PREFIXES = {
    zh = "[由WoWTranslate翻译]",
    en = "[Translated by WoWTranslate]",
    ko = "[WoWTranslate 번역]",
    ja = "[WoWTranslate翻訳]",
    ru = "[Переведено WoWTranslate]",
    de = "[Übersetzt von WoWTranslate]",
    fr = "[Traduit par WoWTranslate]",
    es = "[Traducido por WoWTranslate]",
    pt = "[Traduzido por WoWTranslate]",
}
local DEFAULT_PREFIX = "[Translated by WoWTranslate]"

-- Incoming channel detection state
local currentIncomingChannel = nil
local currentIsSystemEvent = false  -- True for system/emote/NPC events

local EVENT_TO_CHANNEL = {
    CHAT_MSG_SAY = "SAY",
    CHAT_MSG_YELL = "YELL",
    CHAT_MSG_WHISPER = "WHISPER",
    CHAT_MSG_PARTY = "PARTY",
    CHAT_MSG_GUILD = "GUILD",
    CHAT_MSG_OFFICER = "GUILD",
    CHAT_MSG_RAID = "RAID",
    CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_RAID_WARNING = "RAID",
    CHAT_MSG_BATTLEGROUND = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_CHANNEL = "CHANNEL",
    CHAT_MSG_HARDCORE = "HARDCORE",
}

-- Events to skip translation for (system msgs, emotes, NPC speech, notifications)
-- Only these specific events are skipped; unknown events (like WHISPER_INFORM) still translate
local SYSTEM_EVENTS = {
    CHAT_MSG_SYSTEM = true,
    CHAT_MSG_EMOTE = true,
    CHAT_MSG_TEXT_EMOTE = true,
    CHAT_MSG_MONSTER_SAY = true,
    CHAT_MSG_MONSTER_YELL = true,
    CHAT_MSG_MONSTER_EMOTE = true,
    CHAT_MSG_MONSTER_WHISPER = true,
    CHAT_MSG_CHANNEL_JOIN = true,
    CHAT_MSG_CHANNEL_LEAVE = true,
    CHAT_MSG_LOOT = true,
    CHAT_MSG_MONEY = true,
    CHAT_MSG_OPENING = true,
    CHAT_MSG_SKILL = true,
    CHAT_MSG_COMBAT_HONOR_GAIN = true,
    CHAT_MSG_COMBAT_XP_GAIN = true,
    CHAT_MSG_COMBAT_MISC_INFO = true,
}

local defaults = {
    enabled = true,
    debugMode = false,
    -- Outgoing translation settings
    outgoingEnabled = false,  -- Off by default
    outgoingChannels = {
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        SAY = true,
        YELL = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    incomingChannels = {
        SAY = true,
        YELL = true,
        WHISPER = true,
        PARTY = true,
        GUILD = true,
        RAID = true,
        BATTLEGROUND = true,
        CHANNEL = true,
        HARDCORE = false,
        ENGLISH = false,
    },
    outgoingPrefix = "[Translated by WoWTranslate]",
    outgoingPrefixEnabled = true,
    disableWhileAfk = false,
    translateSystemMessages = false,  -- Don't translate system msgs, emotes, NPC speech
    -- Language settings (any-to-any translation)
    enabledSourceLangs = { zh = true, ja = true, ko = true, ru = true, en = false },
    incomingToLang = "en",
    outgoingFromLang = "en",
    outgoingToLang = "zh",
    translationColor = "",       -- Hex RRGGBB for translated text body; empty = default chat color
    translationColorFollow = false,  -- If true, body color follows the source channel color
    replaceMode = false,         -- [EXPERIMENTAL] Replace original message with translation instead of appending
    translatePlayerNames = false,  -- Sender names in [WT] chat and tooltips (default off)
    translateGuildNames = false,   -- Guild names in tooltips (default off)
    translateNameplates = false,   -- Nameplate translation via ShaguPlates (default off)
    outgoingButtonPos = { x = 100, y = 100 },
    nameplateShortNames = false, -- If true, show translation only on nameplates (compact)
    nameplateHideHealthOOC = false, -- Hide nameplate health bars while unit is out of combat
    nameplateGuildOOC = false,   -- Show guild name under player name on nameplates while out of combat
    nameplateAutoscaleNames = false, -- Shrink long nameplate player names to fit width
    nameplateAutoscaleNamesRatio = 0.5, -- Name length-shrink strength when autoscale on (0 .. 1)
    nameplateAutoscaleNamesScale = 1, -- Name autoscale size multiplier (0.33 .. 1.5x)
    nameplatePlayerNameScale = 1,  -- Extra size multiplier for player nameplates only (0.5 .. 3x)
    nameplateTargetNameScale = 1,  -- Extra size multiplier for current target nameplate (0.5 .. 3x)
    nameplateAutoscaleGuild = false, -- Shrink long nameplate guild lines to fit width
    nameplateAutoscaleGuildRatio = 0.5, -- Guild length-shrink strength when autoscale on (0 .. 1)
    nameplateAutoscaleGuildScale = 1, -- Guild autoscale amount (-2 .. 2x)
    nameplateNameColor = "",     -- Hex RRGGBB base name color on Shagu plates when Colored names is off
    nameplateGuildColor = "",    -- Hex RRGGBB base guild line color on Shagu plates
    playerNameClassColor = true,  -- Class color for friendly players; hostile players stay red
}

-- ============================================================================
-- LUA 5.0 COMPATIBILITY
-- ============================================================================
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
-- DEBUG LOGGING
-- ============================================================================
local function DebugLog(a1, a2, a3, a4, a5)
    if not DEBUG_MODE then return end

    local msg = ""
    if a1 then msg = msg .. tostring(a1) .. " " end
    if a2 then msg = msg .. tostring(a2) .. " " end
    if a3 then msg = msg .. tostring(a3) .. " " end
    if a4 then msg = msg .. tostring(a4) .. " " end
    if a5 then msg = msg .. tostring(a5) .. " " end

    local timestamp = string.format("%.1f", GetTime())
    local logEntry = "[" .. timestamp .. "] " .. msg

    if originalAddMessage then
        originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFFFF00[WT-DEBUG] " .. msg .. "|r")
    end

    table.insert(WoWTranslateDebugLog, logEntry)

    while table.getn(WoWTranslateDebugLog) > 500 do
        table.remove(WoWTranslateDebugLog, 1)
    end
end

-- ============================================================================
-- SOURCE LANGUAGE CHARACTER DETECTION
-- ============================================================================
-- Detects if text contains characters from the configured source language
-- Supports: zh (Chinese), ja (Japanese), ko (Korean), ru (Russian)
-- For Latin-based languages (en, de, fr, es, pt): detects non-ASCII characters

local function ContainsLanguageChars(text, lang)
    if not text then return false end

    -- English: pure ASCII text with >= 4 alpha characters.
    -- Any non-ASCII byte (>= 128) means the text contains CJK/Russian/etc., so it is
    -- NOT purely English. Without this guard, Chinese messages that mix in WoW
    -- abbreviations like "MC DPS LFG" (4+ Latin chars) would falsely be detected
    -- as "already English" and skip outgoing translation.
    if lang == "en" then
        local count = 0
        for i = 1, string.len(text) do
            local b = string.byte(text, i)
            if b >= 128 then
                return false  -- non-ASCII character: not a pure English message
            elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
                count = count + 1
            end
        end
        return count >= 4
    end

    for i = 1, string.len(text) do
        local byte = string.byte(text, i)

        if lang == "zh" then
            -- Chinese: CJK Unified Ideographs (U+4E00-U+9FFF)
            -- UTF-8: bytes 228-233 as first byte
            if byte >= 228 and byte <= 233 then
                return true
            end
        elseif lang == "ja" then
            -- Japanese: Hiragana, Katakana, and CJK
            -- Hiragana/Katakana: U+3040-U+30FF (UTF-8: 227 as first byte)
            -- CJK: same as Chinese
            if byte == 227 or (byte >= 228 and byte <= 233) then
                return true
            end
        elseif lang == "ko" then
            -- Korean: Hangul syllables U+AC00-U+D7AF
            -- UTF-8: bytes 234-237 as first byte (covers Hangul range)
            if byte >= 234 and byte <= 237 then
                return true
            end
        elseif lang == "ru" then
            -- Russian: Cyrillic U+0400-U+04FF
            -- UTF-8: bytes 208-209 as first byte
            if byte == 208 or byte == 209 then
                return true
            end
        else
            -- Latin-based languages (en, de, fr, es, pt)
            -- Detect extended ASCII / accented characters (UTF-8 multi-byte)
            -- Any byte >= 128 indicates non-ASCII (potential accented chars)
            if byte >= 192 and byte <= 223 then
                -- 2-byte UTF-8 sequence start (covers Latin Extended, etc.)
                return true
            end
        end
    end
    return false
end

-- Check if text contains characters that need translation based on incoming settings
local function ContainsSourceLanguage(text)
    if not text then return false end
    local sourceLang = WoWTranslateDB and WoWTranslateDB.incomingFromLang or "zh"
    return ContainsLanguageChars(text, sourceLang)
end

-- Check if text contains outgoing target language (to prevent double-translation)
local function ContainsOutgoingTargetLanguage(text)
    if not text then return false end
    local targetLang = WoWTranslateDB and WoWTranslateDB.outgoingToLang or "zh"
    return ContainsLanguageChars(text, targetLang)
end

-- Legacy function name for compatibility
local function ContainsChinese(text)
    return ContainsLanguageChars(text, "zh")
end

-- Pattern-based preprocessing for incoming CJK messages.
-- Converts WoW-CN specific shorthands that the static glossary cannot handle.
local function PreprocessIncoming(text)
    if not text then return text end
    -- Normalize Chinese sentence terminators so Google returns a single translation
    -- segment instead of splitting on sentence boundaries (DLL only reads first segment).
    text = string.gsub(text, "\227\128\130", ". ")   -- 。 U+3002
    text = string.gsub(text, "\239\188\129", "! ")   -- ！ U+FF01
    text = string.gsub(text, "\239\188\159", "? ")   -- ？ U+FF1F
    -- Currency: XG = X gold, XY = X silver. Only when not followed by a letter
    -- so "YY" (Shadowfang Keep), "GM" etc. are not touched.
    -- Run BEFORE 88 handling so "88Y" → "88s" (silver), not "bye Y".
    text = string.gsub(text, "(%d+)G([^%a])", "%1g%2")
    text = string.gsub(text, "(%d+)G$", "%1g")
    text = string.gsub(text, "(%d+)Y([^%a])", "%1s%2")
    text = string.gsub(text, "(%d+)Y$", "%1s")
    -- 110 = patrol mob (China police emergency number used as WoW slang)
    text = string.gsub(text, "([^%w])110([^%w])", "%1patrol%2")
    text = string.gsub(text, "([^%w])110$",        "%1patrol")
    text = string.gsub(text, "^110([^%w])",         "patrol%1")
    text = string.gsub(text, "^110$",               "patrol")
    -- 88 = bye bye (CN internet send-off). Only when isolated (not part of e.g. "880").
    text = string.gsub(text, "([^%w])88([^%w])", "%1bye%2")
    text = string.gsub(text, "([^%w])88$",        "%1bye")
    text = string.gsub(text, "^88([^%w])",         "bye%1")
    text = string.gsub(text, "^88$",               "bye")
    -- 999 = res me (jiǔ = save/rescue, sounds like 9). Isolated only.
    text = string.gsub(text, "([^%w])999([^%w])", "%1res me%2")
    text = string.gsub(text, "([^%w])999$",        "%1res me")
    text = string.gsub(text, "^999([^%w])",         "res me%1")
    text = string.gsub(text, "^999$",               "res me")
    -- 11 = yāo yāo = affirmative / "yes yes". [^%w] boundary; note: may fire on
    -- "我要11个" (I want 11 of them) since CJK chars are not %w in Lua 5.0.
    text = string.gsub(text, "([^%w])11([^%w])", "%1yes%2")
    text = string.gsub(text, "([^%w])11$",        "%1yes")
    text = string.gsub(text, "^11([^%w])",         "yes%1")
    text = string.gsub(text, "^11$",               "yes")
    return text
end

-- Pattern-based preprocessing for outgoing English messages.
-- Converts standard WoW EN currency notation to CN server notation before API.
local function PreprocessOutgoing(text)
    if not text then return text end
    -- Gold: Xg → XG
    text = string.gsub(text, "(%d+)g([^%a])", "%1G%2")
    text = string.gsub(text, "(%d+)g$",        "%1G")
    -- Silver: Xs → XY only when the message also contains a gold amount.
    -- Without this guard "3s CD" or "8s cast time" would wrongly become "3Y CD".
    if string.find(text, "%d+[gG]") then
        text = string.gsub(text, "(%d+)s([^%a])", "%1Y%2")
        text = string.gsub(text, "(%d+)s$",        "%1Y")
    end
    return text
end

-- Auto-detect which source language a message is in.
-- Returns "zh", "ja", "ko", "ru", or nil if no supported language found.
local function DetectSourceLanguage(text)
    if not text then return nil end
    local enabled = (WoWTranslateDB and WoWTranslateDB.enabledSourceLangs)
                    or { zh=true, ja=true, ko=true, ru=true }
    -- If table exists but every lang is nil/false, fall back to all-enabled
    if not enabled.zh and not enabled.ja and not enabled.ko and not enabled.ru then
        enabled = { zh=true, ja=true, ko=true, ru=true }
    end

    local hasKorean   = false
    local hasHiragana = false
    local hasCJK      = false
    local hasRussian  = false
    local asciiAlpha  = 0

    for i = 1, string.len(text) do
        local b = string.byte(text, i)
        if b >= 234 and b <= 237 then hasKorean = true
        elseif b == 227            then hasHiragana = true
        elseif b >= 228 and b <= 233 then hasCJK = true
        elseif b == 208 or b == 209  then hasRussian = true
        elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
            asciiAlpha = asciiAlpha + 1
        end
    end

    if enabled.ko and hasKorean   then return "ko" end
    -- Check zh BEFORE ja: Chinese punctuation (。、「」 etc.) uses UTF-8 byte 0xE3 (227),
    -- the same first byte as Japanese hiragana/katakana. Chinese messages containing
    -- both punctuation (byte 227 → hasHiragana) and characters (bytes 228-233 → hasCJK)
    -- must be treated as Chinese, not Japanese.
    if enabled.zh and hasCJK      then return "zh" end
    if enabled.ja and hasHiragana then return "ja" end
    if enabled.ru and hasRussian  then return "ru" end
    -- English: >= 4 ASCII alpha chars, no CJK/Korean/Japanese/Russian.
    -- Detection is unconditional (same-language skip prevents en→en no-ops).
    if asciiAlpha >= 4 and not (hasCJK or hasKorean or hasHiragana or hasRussian) then
        return "en"
    end
    return nil
end

-- ============================================================================
-- HYPERLINK LOCALIZATION
-- ============================================================================
-- Parse hyperlinks and replace Chinese display names with English equivalents
-- using the client's GetItemInfo() API

-- Queue for messages waiting on item cache
local itemCacheQueue = {}
local itemCacheCounter = 0

-- Hidden tooltip for forcing item cache population
local itemCacheTooltip = CreateFrame("GameTooltip", "WoWTranslateItemCacheTooltip", nil, "GameTooltipTemplate")
itemCacheTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

-- Force item data to be requested from server using SetHyperlink
-- This is more reliable than just calling GetItemInfo()
local function TriggerItemCache(itemId)
    local itemString = "item:" .. itemId .. ":0:0:0"
    itemCacheTooltip:SetHyperlink(itemString)
    DebugLog("Triggered cache for item:", itemId)
end

-- Extract all item IDs from a text string
local function ExtractItemIds(text)
    local itemIds = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for item links: |Hitem:ITEMID:
        local linkStart = string.find(text, "|Hitem:", pos, true)
        if not linkStart then
            break
        end

        -- Find the item ID (numbers after "item:")
        local idStart = linkStart + 7  -- length of "|Hitem:"
        local idEnd = string.find(text, ":", idStart, true)
        if idEnd then
            local itemIdStr = string.sub(text, idStart, idEnd - 1)
            local itemId = tonumber(itemIdStr)
            DebugLog("Extracted item ID:", itemIdStr, "->", itemId or "INVALID")
            if itemId then
                table.insert(itemIds, itemId)
            end
        end

        pos = linkStart + 1
    end

    DebugLog("Total item IDs extracted:", table.getn(itemIds))
    return itemIds
end

-- Check if all item IDs are cached, trigger cache for uncached ones
-- Returns: allCached (boolean), uncachedIds (table)
local function CheckItemCache(itemIds, triggerCache)
    local uncachedIds = {}

    for _, itemId in ipairs(itemIds) do
        local name, link = GetItemInfo(itemId)
        if not name then
            table.insert(uncachedIds, itemId)
            -- Use SetHyperlink to force server to send item data
            if triggerCache then
                TriggerItemCache(itemId)
            end
        end
    end

    return table.getn(uncachedIds) == 0, uncachedIds
end

-- Parse a hyperlink to extract its components
-- Returns: linkType, linkData, displayText, colorCode (or nils if parse fails)
local function ParseHyperlink(link)
    local colorCode = nil
    local linkType = nil
    local linkData = nil
    local displayText = nil

    -- Check for colored link: |cFFRRGGBB|H...
    local colorStart = string.find(link, "^|c........")
    if colorStart then
        colorCode = string.sub(link, 3, 10)  -- Extract FFRRGGBB
    end

    -- Find |H to start of link data
    local hStart, hEnd = string.find(link, "|H")
    if not hStart then return nil end

    -- Find |h[ to find end of link data and start of display text
    local displayStart, displayStartEnd = string.find(link, "|h%[", hEnd)
    if not displayStart then return nil end

    -- Extract type:data between |H and |h[
    local typeData = string.sub(link, hEnd + 1, displayStart - 1)

    -- Split type:data by first colon
    local colonPos = string.find(typeData, ":")
    if colonPos then
        linkType = string.sub(typeData, 1, colonPos - 1)
        linkData = string.sub(typeData, colonPos + 1)
    else
        linkType = typeData
        linkData = ""
    end

    -- Find ]|h to get display text
    local displayEnd = string.find(link, "%]|h", displayStartEnd)
    if not displayEnd then return nil end

    displayText = string.sub(link, displayStartEnd + 1, displayEnd - 1)

    return linkType, linkData, displayText, colorCode
end

-- Extract item ID from link data (format: itemId:enchantId:suffixId:uniqueId)
local function GetItemIdFromLinkData(linkData)
    local colonPos = string.find(linkData, ":")
    if colonPos then
        return tonumber(string.sub(linkData, 1, colonPos - 1))
    else
        return tonumber(linkData)
    end
end

-- Extract quest ID from link data (format: questId:questLevel)
local function GetQuestIdFromLinkData(linkData)
    local colonPos = string.find(linkData, ":")
    if colonPos then
        return tonumber(string.sub(linkData, 1, colonPos - 1))
    else
        return tonumber(linkData)
    end
end

-- Get English quest name from pfQuest database
-- Returns nil if pfQuest not loaded or quest not found
local function GetEnglishQuestName(questId)
    if not pfDB or not pfDB["quests"] then
        return nil  -- pfQuest not loaded
    end

    -- Try custom quests first (more specific)
    local customQuests = pfDB["quests"]["enUS-turtle"]
    if customQuests and customQuests[questId] then
        local entry = customQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
        -- "_" means deleted, fall through to vanilla
    end

    -- Try vanilla quests
    local vanillaQuests = pfDB["quests"]["enUS"]
    if vanillaQuests and vanillaQuests[questId] then
        local entry = vanillaQuests[questId]
        if type(entry) == "table" and entry["T"] then
            return entry["T"]
        end
    end

    return nil  -- Quest not in database
end

-- Localize a hyperlink by replacing the display text with the English name
-- Currently supports: items (via GetItemInfo)
-- Falls back to original if localization not available
local function LocalizeHyperlink(link)
    DebugLog("LocalizeHyperlink called:", string.sub(link, 1, 40))

    local linkType, linkData, displayText, colorCode = ParseHyperlink(link)

    if not linkType then
        DebugLog("  Parse failed, returning original")
        return link  -- Couldn't parse, return original
    end

    DebugLog("  Parsed:", linkType, linkData and string.sub(linkData, 1, 20) or "nil")

    if linkType == "item" then
        local itemId = GetItemIdFromLinkData(linkData)
        DebugLog("  Item ID:", itemId)
        if itemId then
            -- GetItemInfo returns: name, link, quality, iLevel, ...
            local itemName, itemLink = GetItemInfo(itemId)
            DebugLog("  GetItemInfo returned:", itemName or "nil")

            if itemName then
                -- Always rebuild the link manually to ensure correct structure
                -- Use original color code from the Chinese link, just replace the name
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. itemName .. "]|h"
                end
                DebugLog("  Rebuilt link with English name")
                return result
            else
                -- Item not in client cache yet; trigger a server request so next
                -- occurrence of this item link will resolve to the English name.
                TriggerItemCache(itemId)
            end
        end
    elseif linkType == "quest" then
        local questId = GetQuestIdFromLinkData(linkData)
        DebugLog("  Quest ID:", questId)
        if questId then
            local questName = GetEnglishQuestName(questId)
            DebugLog("  GetEnglishQuestName returned:", questName or "nil")

            if questName then
                local result
                if colorCode then
                    result = "|c" .. colorCode .. "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h|r"
                else
                    result = "|H" .. linkType .. ":" .. linkData .. "|h[" .. questName .. "]|h"
                end
                DebugLog("  Rebuilt quest link with English name")
                return result
            end
        end
    else
        DebugLog("  Not an item or quest link, skipping localization")
    end
    -- Quest localization uses pfQuest database (if available)
    -- Spell localization not supported in vanilla WoW 1.12 (no GetSpellInfo API)

    DebugLog("  No localized name, returning original")
    return link  -- No localized name found, return original
end

-- ============================================================================
-- ROBUST HYPERLINK EXTRACTION
-- ============================================================================
-- WoW 1.12 hyperlink format: |cFFRRGGBB|Htype:data|h[DisplayText]|h|r
-- Key: Extract FULL hyperlinks including color codes as single units

-- Find all hyperlinks in text, returning their positions and content
local function FindAllHyperlinks(text)
    local hyperlinks = {}
    local pos = 1

    while pos <= string.len(text) do
        -- Look for hyperlink start - either |c (colored) or |H (plain)
        local colorStart = string.find(text, "|c........|H", pos)
        local plainStart = string.find(text, "|H", pos)

        local linkStart = nil
        local hasColor = false

        -- Determine which comes first
        if colorStart and (not plainStart or colorStart <= plainStart) then
            linkStart = colorStart
            hasColor = true
        elseif plainStart then
            -- Make sure this |H isn't part of a colored link we already found
            if not colorStart or plainStart < colorStart then
                linkStart = plainStart
                hasColor = false
            end
        end

        if not linkStart then
            break
        end

        -- Find the end of the hyperlink: |h[...]|h followed by optional |r
        -- Pattern: find |h[ then find ]|h
        local displayStart = string.find(text, "|h%[", linkStart)
        if not displayStart then
            pos = linkStart + 1
        else
            -- Find closing ]|h
            local displayEnd = string.find(text, "%]|h", displayStart)
            if not displayEnd then
                pos = linkStart + 1
            else
                local linkEnd = displayEnd + 2  -- Position after ]|h

                -- Check for |r after the link
                if string.sub(text, linkEnd + 1, linkEnd + 2) == "|r" then
                    linkEnd = linkEnd + 2
                end

                -- If we have color, make sure we started from |c
                local actualStart = linkStart
                if hasColor then
                    actualStart = colorStart
                end

                local fullLink = string.sub(text, actualStart, linkEnd)

                DebugLog("Found hyperlink:", string.sub(fullLink, 1, 80))

                table.insert(hyperlinks, {
                    startPos = actualStart,
                    endPos = linkEnd,
                    content = fullLink
                })

                pos = linkEnd + 1
            end
        end
    end

    return hyperlinks
end

-- Split message into segments: text and hyperlinks
-- Returns array of {type="text"|"link", content=string}
local function SplitIntoSegments(text)
    local segments = {}
    local hyperlinks = FindAllHyperlinks(text)

    if table.getn(hyperlinks) == 0 then
        -- No hyperlinks, entire text is translatable
        if text ~= "" then
            table.insert(segments, {type = "text", content = text})
        end
        return segments
    end

    local lastEnd = 0
    for _, link in ipairs(hyperlinks) do
        -- Add text before this hyperlink
        if link.startPos > lastEnd + 1 then
            local textBefore = string.sub(text, lastEnd + 1, link.startPos - 1)
            if textBefore ~= "" then
                table.insert(segments, {type = "text", content = textBefore})
            end
        end

        -- Add the hyperlink (with localized display name if available)
        table.insert(segments, {type = "link", content = LocalizeHyperlink(link.content)})
        lastEnd = link.endPos
    end

    -- Add text after last hyperlink
    if lastEnd < string.len(text) then
        local textAfter = string.sub(text, lastEnd + 1)
        if textAfter ~= "" then
            table.insert(segments, {type = "text", content = textAfter})
        end
    end

    return segments
end

-- Check if any text segments contain source language characters
local function HasTranslatableContent(segments)
    for _, seg in ipairs(segments) do
        if seg.type == "text" and DetectSourceLanguage(seg.content) then
            return true
        end
    end
    return false
end

-- Strip WoW color codes from text before sending to translation API.
-- |cFFRRGGBB...text...|r sequences are not valid UTF-8 markup and confuse Google.
-- The pipe character in translations would also break the requestId|result|error wire format.
local function StripColorCodes(text)
    if not text then return text end
    -- Use "." (any char) instead of %x to avoid any pattern-class compatibility concerns.
    -- WoW color codes are always |c followed by exactly 8 hex characters.
    local result = string.gsub(text, "|c........", "")
    result = string.gsub(result, "|r", "")
    return result
end

-- Split a fully-formatted chat line into header and message body.
-- The header is everything up to and including the first ": " separator
-- (e.g. "|cFF...[PlayerName]|r says: ").  The body is what follows.
-- If no separator is found the header is empty and body is the full text.
local function SplitHeaderAndMessage(text)
    local pos1 = string.find(text, ": ", 1, true)
    local pos2 = string.find(text, "\239\188\154", 1, true) -- UTF-8 fullwidth colon
    local pos3 = string.find(text, "\163\186", 1, true)     -- GBK colon

    local bestPos = nil
    local bestLen = 0
    if pos1 then bestPos = pos1; bestLen = 2 end
    if pos2 and (not bestPos or pos2 < bestPos) then bestPos = pos2; bestLen = 3 end
    if pos3 and (not bestPos or pos3 < bestPos) then bestPos = pos3; bestLen = 2 end

    if not bestPos then
        return "", text
    end

    local header = string.sub(text, 1, bestPos + bestLen - 1)
    local msg    = string.sub(text, bestPos + bestLen)
    return header, msg
end

-- Build text to translate: only text segments, hyperlinks become URL placeholders
-- URLs are preserved by Google Translate because they're recognized as web addresses
local function BuildTranslatableText(segments)
    local parts = {}
    local linkIndex = 0

    for _, seg in ipairs(segments) do
        if seg.type == "text" then
            table.insert(parts, StripColorCodes(seg.content))
        else
            linkIndex = linkIndex + 1
            -- Space-pad the placeholder so Google never merges it with adjacent CJK bytes.
            -- Without spaces, "来人http://ph.wt/1" is treated as one URL and the Chinese
            -- is left untranslated.  The spaces are benign — ReconstructMessage uses a
            -- substring search so it finds "http://ph.wt/N" inside " http://ph.wt/N ".
            table.insert(parts, " http://ph.wt/" .. linkIndex .. " ")
        end
    end

    return table.concat(parts, "")
end

-- Reconstruct message from translated text and original segments
local function ReconstructMessage(segments, translatedText)
    local result = {}
    local workText = translatedText

    -- Count links
    local linkCount = 0
    local linkContents = {}
    for _, seg in ipairs(segments) do
        if seg.type == "link" then
            linkCount = linkCount + 1
            linkContents[linkCount] = seg.content
        end
    end

    if linkCount == 0 then
        return translatedText
    end

    -- Replace each URL placeholder with the original hyperlink
    for i = 1, linkCount do
        local placeholder = "http://ph.wt/" .. i
        -- Also try with https (in case API changes it)
        local placeholder2 = "https://ph.wt/" .. i
        -- Also try URL-encoded or modified versions
        local placeholder3 = "http://ph .wt/" .. i
        local placeholder4 = "http: //ph.wt/" .. i

        local found = false

        DebugLog("Link", i, "content:", string.sub(linkContents[i] or "nil", 1, 80))

        -- Try exact match first
        local startPos, endPos = string.find(workText, placeholder, 1, true)
        if startPos then
            workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
            found = true
            DebugLog("Replaced placeholder", i)
        end

        -- Try https version
        if not found then
            startPos, endPos = string.find(workText, placeholder2, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
                DebugLog("Replaced https placeholder", i)
            end
        end

        -- Try with space after http:
        if not found then
            startPos, endPos = string.find(workText, placeholder3, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
            end
        end

        if not found then
            startPos, endPos = string.find(workText, placeholder4, 1, true)
            if startPos then
                workText = string.sub(workText, 1, startPos - 1) .. linkContents[i] .. string.sub(workText, endPos + 1)
                found = true
            end
        end

        if not found then
            DebugLog("Placeholder not found:", placeholder)
            -- Append the link at the end as fallback
            workText = workText .. " " .. linkContents[i]
        end
    end

    return workText
end

-- ============================================================================
-- ============================================================================
-- PLAYER NAME TRANSLATION
-- ============================================================================
-- Cache key prefix so player names never collide with message-body cache entries.
local NAME_CACHE_PREFIX = "\1wt_name:"

local function NameCacheKey(name)
    return NAME_CACHE_PREFIX .. name
end

-- 1.12 prints "Unknown unit." for Unit* on "target"/"mouseover" when nothing is targeted/hovered.
local function TargetFrameShowsUnit()
    if not TargetFrame then return false end
    if TargetFrame.IsShown and not TargetFrame:IsShown() then return false end
    if TargetFrame.IsVisible and not TargetFrame:IsVisible() then return false end
    if TargetFrame.name and TargetFrame.name.GetText then
        local t = TargetFrame.name:GetText()
        if t and t ~= "" then return true end
    end
    return false
end

-- 1.12 prints "Unknown unit." to chat for bad tokens; pcall does not suppress it.
local function UnitTokenAllowed(unit)
    if not unit or unit == "" or type(unit) ~= "string" then return false end
    if unit == "player" or unit == "pet" or unit == "pettarget" then return true end
    if unit == "target" then return TargetFrameShowsUnit() end
    if unit == "mouseover" then return false end
    local partyIdx = string.find(unit, "^party", 1, true)
    if partyIdx == 1 then
        local i = tonumber(string.sub(unit, 6))
        if not i or i < 1 then return false end
        local n = (GetNumPartyMembers and GetNumPartyMembers()) or 0
        return i <= n
    end
    local raidIdx = string.find(unit, "^raid", 1, true)
    if raidIdx == 1 then
        local i = tonumber(string.sub(unit, 5))
        if not i or i < 1 then return false end
        local n = (GetNumRaidMembers and GetNumRaidMembers()) or 0
        return i <= n
    end
    return false
end

local function UnitExistsSafe(unit)
    if not unit or unit == "" or type(unit) ~= "string" then return false end
    if unit == "target" then
        return TargetFrameShowsUnit()
    end
    if unit == "mouseover" then
        return false
    end
    if not UnitTokenAllowed(unit) then return false end
    if not UnitExists then return false end
    local ok, exists = pcall(UnitExists, unit)
    return ok and exists
end

local function UnitNameSafe(unit)
    if not UnitExistsSafe(unit) then return nil end
    if not UnitName then return nil end
    local ok, name = pcall(UnitName, unit)
    if ok and name and name ~= "" then return name end
    return nil
end

local function UnitIsPlayerSafe(unit)
    if not UnitExistsSafe(unit) then return false end
    if not UnitIsPlayer then return false end
    local ok, is = pcall(UnitIsPlayer, unit)
    return ok and is
end

local function UnitClassSafe(unit)
    if not UnitExistsSafe(unit) then return nil end
    if not UnitClass then return nil end
    local ok, _, class = pcall(UnitClass, unit)
    if ok and class then return class end
    return nil
end

local function UnitAffectingCombatSafe(unit)
    if not UnitExistsSafe(unit) then return false end
    if not UnitAffectingCombat then return false end
    local ok, c = pcall(UnitAffectingCombat, unit)
    return ok and c
end

local function UnitPVPNameSafe(unit)
    if not UnitExistsSafe(unit) then return nil end
    if not UnitPVPName then return nil end
    local ok, name = pcall(UnitPVPName, unit)
    if ok and name and name ~= "" then return name end
    return nil
end

local function UnitIsFriendSafe(unit)
    if not UnitExistsSafe(unit) then return false end
    if not UnitIsFriend then return false end
    local ok, result = pcall(UnitIsFriend, "player", unit)
    return ok and (result == 1 or result == true)
end

local function UnitCanAttackSafe(unit)
    if not UnitExistsSafe(unit) then return false end
    if not UnitCanAttack then return false end
    local ok, result = pcall(UnitCanAttack, "player", unit)
    return ok and (result == 1 or result == true)
end

-- True when the player name contains a detected source language different from the
-- configured incoming target (e.g. Chinese name with target=en).
local function ShouldTranslatePlayerName(name)
    if not name or name == "" then return false end
    local lang = DetectSourceLanguage(name)
    if not lang then return false end
    local target = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
    return lang ~= target
end

-- Yellow asterisk marks a translated name; class color for friendly players only.
local TRANSLATED_NAME_MARK = "|cFFFFFF00*|r"

local function PlayerNameClassColorEnabled()
    return WoWTranslateDB and WoWTranslateDB.playerNameClassColor
end

local function RgbHex(colorOrR, g, b, a)
    local r, gr, bl, al
    if type(colorOrR) == "table" then
        if colorOrR.r then
            r, gr, bl, al = colorOrR.r, colorOrR.g, colorOrR.b, (colorOrR.a or 1)
        end
    elseif tonumber(colorOrR) then
        r, gr, bl, al = colorOrR, g, b, (a or 1)
    end
    if not r then return "" end
    if r > 1 then r = 1 elseif r < 0 then r = 0 end
    if gr > 1 then gr = 1 elseif gr < 0 then gr = 0 end
    if bl > 1 then bl = 1 elseif bl < 0 then bl = 0 end
    if al > 1 then al = 1 elseif al < 0 then al = 0 end
    return string.format("|c%02x%02x%02x%02x", al * 255, r * 255, gr * 255, bl * 255)
end

-- Match the client "Name Capitalization" option (title-case each word).
local function ApplyNameCapitalization(name)
    if not name or name == "" then return name end
    if type(CapitalizeName) == "function" then
        return CapitalizeName(name)
    end
    local gfind = string.gfind or string.gmatch
    if not gfind then return name end
    local parts = {}
    for word in gfind(name, "%S+") do
        if string.len(word) > 0 then
            table.insert(parts, string.upper(string.sub(word, 1, 1)) .. string.lower(string.sub(word, 2)))
        end
    end
    if table.getn(parts) == 0 then return name end
    return table.concat(parts, " ")
end

local function NameplatePartialMatches(full, partial)
    if not full or not partial or partial == "" then return false end
    if full == partial then return true end
    if string.len(partial) < 3 then return false end
    return string.find(full, partial, 1, true) == 1
end

local wtCachedTargetUnit = nil
local wtCachedTargetCheckTime = 0
local wtHadTargetUnit = false

local function GetSafeTargetUnitToken()
    local now = GetTime()
    if wtCachedTargetCheckTime and (now - wtCachedTargetCheckTime) < 0.1 then
        return wtCachedTargetUnit
    end
    wtCachedTargetCheckTime = now
    wtCachedTargetUnit = nil
    if not TargetFrameShowsUnit() then
        return nil
    end
    local u = TargetFrame.unit
    if not u or u == "" or u == "target" then
        wtCachedTargetUnit = "target"
    elseif UnitTokenAllowed(u) and UnitNameSafe(u) then
        wtCachedTargetUnit = u
    else
        wtCachedTargetUnit = "target"
    end
    if wtCachedTargetUnit and not UnitNameSafe(wtCachedTargetUnit) then
        wtCachedTargetUnit = nil
    end
    return wtCachedTargetUnit
end

local function GetSafeMouseoverUnitToken(plate)
    if plate and plate.glow and plate.glow.IsShown and not plate.glow:IsShown() then
        return nil
    end
    return nil
end

local function GetPlayerClassFromName(rawName)
    if not rawName or rawName == "" then return nil end
    if ShaguTweaks and ShaguTweaks.GetUnitData then
        local class = ShaguTweaks.GetUnitData(rawName)
        if class and class ~= "UNKNOWN" and class ~= UNKNOWN then
            return class
        end
    end
    return nil
end

local function FindPlayerUnitByName(name, plate)
    if not name or name == "" then return nil end
    local function matchUnit(unit)
        if UnitIsPlayerSafe(unit) then
            local un = UnitNameSafe(unit)
            local pvp = UnitPVPNameSafe(unit)
            if un == name or (pvp and pvp == name) then
                return unit
            end
            if NameplatePartialMatches(un, name) or NameplatePartialMatches(pvp, name) then
                return unit
            end
        end
    end
    local mouseUnit = GetSafeMouseoverUnitToken(plate)
    if mouseUnit then
        local unit = matchUnit(mouseUnit)
        if unit then return unit end
    end
    local targetUnit = GetSafeTargetUnitToken()
    if targetUnit then
        local unit = matchUnit(targetUnit)
        if unit then return unit end
    end
    local unit = matchUnit("player")
    if unit then return unit end
    local numParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, numParty do
        unit = matchUnit("party" .. i)
        if unit then return unit end
    end
    local numRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    for i = 1, numRaid do
        unit = matchUnit("raid" .. i)
        if unit then return unit end
    end
    return nil
end

local function ResolvePlayerClass(rawName, unit)
    if unit and UnitIsPlayerSafe(unit) then
        local class = UnitClassSafe(unit)
        if class then return class end
    end
    unit = FindPlayerUnitByName(rawName)
    if unit then
        local class = UnitClassSafe(unit)
        if class then return class end
    end
    if ShaguTweaks and ShaguTweaks.GetUnitData then
        local class = ShaguTweaks.GetUnitData(rawName)
        if class and class ~= "UNKNOWN" and class ~= UNKNOWN then
            return class
        end
    end
    return nil
end

-- Forward declaration; defined after nameplate hostility helpers.
local IsHostilePlayer

local function ColorizePlayerName(rawName, text, unit, plate)
    if not text or text == "" then return text end
    if not PlayerNameClassColorEnabled() then
        return StripColorCodes(text)
    end
    local plain = StripColorCodes(text)
    plain = ApplyNameCapitalization(plain)
    if IsHostilePlayer and IsHostilePlayer(rawName, unit, plate) then
        return RgbHex(1, 0, 0) .. plain .. "|r"
    end
    if IsHostilePlayer and IsHostilePlayer(rawName, unit, plate, true) then
        return RgbHex(1, 1, 0) .. plain .. "|r"
    end
    local class = ResolvePlayerClass(rawName, unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        return RgbHex(RAID_CLASS_COLORS[class]) .. plain .. "|r"
    end
    return plain
end

local function MarkTranslatedDisplayName(rawName, displayName, unit)
    if not displayName or displayName == "" then return displayName end
    local isTranslated = rawName and displayName ~= rawName
    local label = isTranslated and displayName or (rawName or displayName)
    local colored = ColorizePlayerName(rawName, label, unit)
    if not isTranslated then
        return colored
    end
    return colored .. TRANSLATED_NAME_MARK
end

-- Strip display markup so we can compare against the original unit name.
local function StripTranslatedNameMark(text)
    if not text then return text end
    local plain = StripColorCodes(text)
    if plain then
        plain = string.gsub(plain, "%*$", "")
    end
    return plain
end

-- Overhead/nameplate text: optional class color; append translation when present.
local function FormatOverheadDisplayName(rawName, displayName, unit)
    displayName = displayName or rawName
    if not rawName or displayName == rawName then
        return ColorizePlayerName(rawName, rawName, unit)
    end
    local marked = MarkTranslatedDisplayName(rawName, displayName, unit)
    if WoWTranslateDB and WoWTranslateDB.nameplateShortNames then
        return marked
    end
    return rawName .. " (" .. marked .. ")"
end

local function StripOverheadDisplaySuffix(text)
    if not text then return text end
    local plain = StripTranslatedNameMark(text)
    local prev
    repeat
        prev = plain
        local p = string.find(plain, " %(", 1, true)
        if p then
            plain = string.sub(plain, 1, p - 1)
        end
    until plain == prev or plain == ""
    return plain
end

-- Client nameplates often truncate visible text; peel a trailing "..." if present.
local function NormalizeTruncatedNameplateName(text)
    if not text then return text end
    local plain = StripOverheadDisplaySuffix(text)
    if plain and string.sub(plain, -3) == "..." then
        plain = string.sub(plain, 1, -4)
    end
    return plain
end

local function OverheadDisplayMatchesRawName(text, rawName)
    if not text or not rawName or text == "" or rawName == "" then return false end
    if text == rawName then return true end
    return StripOverheadDisplaySuffix(text) == rawName
end

-- Truncate cleanup only; nameplates never resolve via unit APIs (avoids "Unknown unit.").
local function ResolveFullPlayerName(partial, plate)
    return NormalizeTruncatedNameplateName(partial)
end

-- Forward declarations (nameplate section).
local GetNameplateFactionRgb
local GetNameplateNameTextRgb
local IsNameplatePlayerForColor

local function HexToRgb(hex, defaultR, defaultG, defaultB)
    if hex and string.len(hex) == 6 then
        local r = tonumber(string.sub(hex, 1, 2), 16)
        local g = tonumber(string.sub(hex, 3, 4), 16)
        local b = tonumber(string.sub(hex, 5, 6), 16)
        if r and g and b then
            return r / 255, g / 255, b / 255
        end
    end
    return defaultR, defaultG, defaultB
end

local function GetNameplateBaseNameRgb()
    return HexToRgb(WoWTranslateDB and WoWTranslateDB.nameplateNameColor, 1, 1, 1)
end

local function GetNameplateBaseGuildRgb()
    return HexToRgb(WoWTranslateDB and WoWTranslateDB.nameplateGuildColor, 0.75, 0.75, 0.75)
end

local function ApplyNameplateGuildTextColor(guildFs)
    if guildFs and guildFs.SetTextColor then
        local r, g, b = GetNameplateBaseGuildRgb()
        guildFs:SetTextColor(r, g, b)
    end
end

local function GetPlayerClassRgb(rawName, unit)
    local class = ResolvePlayerClass(rawName, unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return nil
end

-- Nameplate name shrink (guild uses separate thresholds below).
local NAME_FULL_LEN = 22
local NAME_MAX_LEN = 40
local NAME_MIN_FONT = 6
local NAME_MAX_WIDTH = 280
-- Length of what is actually drawn (not "Raw (Translation*)" wrapper when only translation is long).
local function NameplateDisplayPlainLength(rawName, formatted)
    local plain = StripColorCodes(formatted) or ""
    if plain == "" then return 0 end
    if rawName and rawName ~= "" then
        local marker = rawName .. " ("
        local pos = string.find(plain, marker, 1, true)
        if pos then
            local trans = string.sub(plain, pos + string.len(marker))
            trans = string.gsub(trans, "%*%)$", "")
            trans = string.gsub(trans, "%)$", "")
            local rlen = string.len(rawName)
            local tlen = string.len(trans)
            if tlen > rlen then return tlen end
            return rlen
        end
    end
    plain = string.gsub(plain, "%*$", "")
    return string.len(plain)
end

local NAME_BASE_DEFAULT = 12
local NAME_BASE_MAX = 14

local function ClampAutoscaleAmount(scaleAmount)
    local v = tonumber(scaleAmount) or 1
    if v < -1 then v = -1 elseif v > 1 then v = 1 end
    return math.floor(v * 10 + 0.5) / 10
end

-- Slider -1..1; half-strength vs old ±2 (max ~1.5x / ~0.67x). Multiplies autoscale curve output.
local function AutoscaleSizeMultiplier(scaleAmount)
    local s = ClampAutoscaleAmount(scaleAmount)
    if s == 0 or s == 1 then return 1 end
    if s > 0 then
        return 1 + s * 0.5
    end
    return 1 / (1 + (-s) * 0.5)
end

function WoWTranslate_GetAutoscaleSizeMultiplier(scaleAmount)
    return AutoscaleSizeMultiplier(scaleAmount)
end

local function NameAutoscaleSizeMultiplier(scaleAmount)
    local v = tonumber(scaleAmount) or 1
    if v < 0.33 then v = 0.33 elseif v > 1.5 then v = 1.5 end
    return math.floor(v * 100 + 0.5) / 100
end

function WoWTranslate_GetNameAutoscaleSizeMultiplier(scaleAmount)
    return NameAutoscaleSizeMultiplier(scaleAmount)
end

local function AutoscaleShrinkStrength(ratio)
    local v = tonumber(ratio)
    if not v then return 0.5 end
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return math.floor(v * 100 + 0.5) / 100
end

function WoWTranslate_GetAutoscaleShrinkStrength(ratio)
    return AutoscaleShrinkStrength(ratio)
end

local function ClampPlayerNameplateScale(scaleAmount)
    local v = tonumber(scaleAmount) or 1
    if v < 0.5 then v = 0.5 elseif v > 3 then v = 3 end
    return math.floor(v * 100 + 0.5) / 100
end

function WoWTranslate_GetPlayerNameplateScale(scaleAmount)
    return ClampPlayerNameplateScale(scaleAmount)
end

function WoWTranslate_GetTargetNameplateScale(scaleAmount)
    return ClampPlayerNameplateScale(scaleAmount)
end

local function IsNameplateActiveTarget(plate, rawName)
    if not plate or not rawName or rawName == "" then return false end
    -- Prefer live target unit over Shagu istarget (stale until next nameplate OnUpdate).
    local targetUnit = GetSafeTargetUnitToken()
    if targetUnit then
        local un = UnitNameSafe(targetUnit)
        local pvp = UnitPVPNameSafe(targetUnit)
        if un == rawName or (pvp and pvp == rawName) then return true end
        if NameplatePartialMatches(un, rawName) or NameplatePartialMatches(pvp, rawName) then
            return true
        end
        return false
    end
    -- No target — do not use stale Shagu istarget/cache.target after clear or drop.
    return false
end

local function ApplyPlayerNameplateSizeBoost(fs, plate, rawName)
    if not fs or not fs.GetFont or not fs.SetFont then return end
    if not plate or not rawName or rawName == "" then return end
    if not IsNameplatePlayerForColor or not IsNameplatePlayerForColor(plate, rawName) then return end
    local mult = ClampPlayerNameplateScale(WoWTranslateDB and WoWTranslateDB.nameplatePlayerNameScale)
    if mult == 1 then return end
    local font, size, flags = fs:GetFont()
    if not font or not size then return end
    size = math.floor(size * mult + 0.5)
    if size < 1 then size = 1 end
    fs:SetFont(font, size, flags)
end

local function ApplyTargetNameplateSizeBoost(fs, plate, rawName)
    if not fs or not fs.GetFont or not fs.SetFont then return end
    if not IsNameplateActiveTarget(plate, rawName) then return end
    local mult = ClampPlayerNameplateScale(WoWTranslateDB and WoWTranslateDB.nameplateTargetNameScale)
    if mult == 1 then return end
    local font, size, flags = fs:GetFont()
    if not font or not size then return end
    size = math.floor(size * mult + 0.5)
    if size < 1 then size = 1 end
    fs:SetFont(font, size, flags)
end

local function ClampOversizeBaseFont(size, defaultSize, maxSize)
    size = tonumber(size) or defaultSize
    if size > maxSize then size = maxSize end
    return size
end

-- SetFont clears drop shadows on 1.12; restore Blizzard defaults or copy from source.
local function GetNameplateShadowSourceFont(parent, displayFs)
    if parent then
        local overlay = parent.nameplate
        if overlay and overlay.original and overlay.original.name then
            return overlay.original.name
        end
        if parent.name then
            return parent.name
        end
    end
    return displayFs
end

local NAMEPLATE_SHADOW_OFFSET_SCALE = 0.75

local function ApplyNameplateFontShadow(dst, src)
    if not dst or not dst.SetShadowColor then return end
    local scale = NAMEPLATE_SHADOW_OFFSET_SCALE
    local r, g, b, a = 0, 0, 0, 1
    local ox, oy = 1 * scale, -1 * scale
    if src and src.GetShadowOffset and src.GetShadowColor then
        local sx, sy = src:GetShadowOffset()
        if sx and (sx ~= 0 or sy ~= 0) then
            ox, oy = sx * scale, sy * scale
            local sr, sg, sb, sa = src:GetShadowColor()
            if sr then r, g, b, a = sr, sg, sb, sa or 1 end
        end
    end
    dst:SetShadowColor(r, g, b, a)
    if dst.SetShadowOffset then
        dst:SetShadowOffset(ox, oy)
    end
end

local function FontSizeForLength(baseSize, minFont, plainLen, fullLen, maxLen, shrinkStrength)
    baseSize = baseSize or 12
    shrinkStrength = shrinkStrength or 1
    if plainLen <= fullLen then return baseSize end
    if plainLen >= maxLen then return minFont end
    local t = (plainLen - fullLen) / (maxLen - fullLen)
    local size = baseSize - t * (baseSize - minFont) * shrinkStrength
    if size < minFont then size = minFont end
    return math.floor(size + 0.5)
end

local function CaptureNameplateNameFont(parent, fs)
    if not parent then
        if fs and fs.GetFont then
            return fs:GetFont()
        end
        return nil, NAME_BASE_DEFAULT, nil
    end
    if not parent.wtNameBaseCaptured then
        local font, size, flags
        local overlay = parent.nameplate
        -- Blizzard original only — overlay.name may already be our shrunk font.
        local src = overlay and overlay.original and overlay.original.name
        if src and src.GetFont then
            font, size, flags = src:GetFont()
        elseif overlay then
            font, size, flags = "Fonts\\FRIZQT__.TTF", NAME_BASE_DEFAULT, ""
        elseif fs and fs.GetFont then
            font, size, flags = fs:GetFont()
        else
            font, size, flags = "Fonts\\FRIZQT__.TTF", NAME_BASE_DEFAULT, ""
        end
        parent.wtNameFontPath = font
        parent.wtNameFontFlags = flags
        parent.wtNameBaseFontSize = ClampOversizeBaseFont(size, NAME_BASE_DEFAULT, NAME_BASE_MAX)
        parent.wtNameBaseCaptured = true
    end
    return parent.wtNameFontPath, parent.wtNameBaseFontSize, parent.wtNameFontFlags
end

local function ApplyAutoscaleFont(fs, font, flags, opts)
    local mult = opts.sizeMult or AutoscaleSizeMultiplier(opts.scaleAmount)
    local baseSize = opts.baseSize or opts.defaultBase
    local plainLen = opts.plainLen or 0
    local size = baseSize

    if opts.autoscaleOn then
        if plainLen >= opts.maxLen then
            size = opts.minFont
        elseif plainLen > opts.fullLen then
            size = FontSizeForLength(baseSize, opts.minFont, plainLen, opts.fullLen, opts.maxLen, opts.shrinkStrength)
        else
            size = baseSize
        end
    end

    fs:SetFont(font, size, flags)

    -- Pixel width pass only when length already warrants shrinking (avoids squashing short labels).
    if opts.autoscaleOn and plainLen > opts.fullLen and fs.GetStringWidth then
        local maxW = opts.maxWidth / mult
        local w = fs:GetStringWidth()
        while w and w > maxW and size > opts.minFont do
            size = size - 1
            fs:SetFont(font, size, flags)
            w = fs:GetStringWidth()
        end
    end

    size = math.floor(size * mult + 0.5)
    if size < 1 then size = 1 end
    if opts.autoscaleOn and plainLen > opts.fullLen then
        local floorSize = math.floor(opts.minFont * mult + 0.5)
        if floorSize < 1 then floorSize = 1 end
        if size < floorSize then size = floorSize end
    end
    fs:SetFont(font, size, flags)
    if opts.shadowSrc then
        ApplyNameplateFontShadow(fs, opts.shadowSrc)
    end
    return size
end

local function ApplyNameplateNameFontSize(parent, fs, text, rawName)
    if not fs or not fs.SetFont or not fs.GetFont then return end
    local font, baseSize, flags = CaptureNameplateNameFont(parent, fs)
    if not font then return end

    local autoscale = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleNames
    local scaleAmt = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleNamesScale
    local shrinkRatio = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleNamesRatio
    local shadowSrc = GetNameplateShadowSourceFont(parent, fs)
    ApplyAutoscaleFont(fs, font, flags, {
        baseSize = baseSize,
        defaultBase = NAME_BASE_DEFAULT,
        minFont = NAME_MIN_FONT,
        plainLen = NameplateDisplayPlainLength(rawName, text),
        fullLen = NAME_FULL_LEN,
        maxLen = NAME_MAX_LEN,
        maxWidth = NAME_MAX_WIDTH,
        shrinkStrength = AutoscaleShrinkStrength(shrinkRatio),
        autoscaleOn = autoscale,
        scaleAmount = scaleAmt,
        sizeMult = NameAutoscaleSizeMultiplier(scaleAmt),
        shadowSrc = shadowSrc,
    })
    ApplyPlayerNameplateSizeBoost(fs, parent, rawName)
    ApplyTargetNameplateSizeBoost(fs, parent, rawName)
    ApplyNameplateFontShadow(fs, shadowSrc)
end

local function ApplyNameplateNameText(fs, formatted, parent, rawName, unit)
    if not fs or not formatted then return end
    local tr, tg, tb, ta = 1, 1, 1, 1
    local colorSet = false
    if PlayerNameClassColorEnabled() and rawName and parent then
        local cr, cg, cb = GetNameplateNameTextRgb(rawName, parent)
        if cr then
            tr, tg, tb = cr, cg, cb
            colorSet = true
        end
    elseif not PlayerNameClassColorEnabled() then
        tr, tg, tb = GetNameplateBaseNameRgb()
        colorSet = true
    end
    if not colorSet and parent then
        local overlay = parent.nameplate
        if overlay and overlay.original and overlay.original.name and overlay.original.name.GetTextColor then
            tr, tg, tb, ta = overlay.original.name:GetTextColor()
        elseif fs.GetTextColor then
            tr, tg, tb, ta = fs:GetTextColor()
        end
    elseif not colorSet and fs.GetTextColor then
        tr, tg, tb, ta = fs:GetTextColor()
    end
    fs:SetText(formatted)
    if fs.SetTextColor then
        fs:SetTextColor(tr, tg, tb, ta or 1)
    end
    ApplyNameplateNameFontSize(parent, fs, formatted, rawName)
    -- Widen if capped; never SetWidth(0) — that hides text on 1.12 FontStrings.
    if fs.GetStringWidth and fs.SetWidth then
        local w = fs:GetStringWidth()
        if w and w > 0 then
            fs:SetWidth(w + 8)
        end
    end
end

-- Build the sender prefix for a translation line.
-- rawName is used in the |Hplayer: link target; displayName is shown in brackets.
local function BuildSenderPrefix(rawName, displayName, channel, unit)
    if not rawName or rawName == "" then return "" end
    if not WoWTranslateDB or not WoWTranslateDB.translatePlayerNames then return "" end
    displayName = MarkTranslatedDisplayName(rawName, displayName or rawName, unit)
    if channel then
        return "|Hplayer:" .. rawName .. "|h[" .. displayName .. "]|h|r: "
    else
        return displayName .. ": "
    end
end

-- Resolve the display name for a player (sync from cache, or async via API).
-- callback(displayName) is always invoked exactly once.
-- forWIM: translate for WIM window headers even when chat sender names are off.
local function ResolvePlayerDisplayName(rawName, callback, forWIM)
    if not callback then return end
    if not rawName or rawName == "" then
        callback(rawName)
        return
    end
    if not forWIM and (not WoWTranslateDB or not WoWTranslateDB.translatePlayerNames) then
        callback(rawName)
        return
    end
    if forWIM then
        if not WoWTranslateDB or not WoWTranslateDB.enabled then
            callback(rawName)
            return
        end
        if WoWTranslateDB.disableWhileAfk and playerIsAFK then
            callback(rawName)
            return
        end
    end
    if not ShouldTranslatePlayerName(rawName) then
        callback(rawName)
        return
    end

    local cacheKey = NameCacheKey(rawName)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then
        callback(cached)
        return
    end

    local nameLang = DetectSourceLanguage(rawName)
    if not nameLang then
        callback(rawName)
        return
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(rawName)
        return
    end

    local waiters = pendingNameTranslations[rawName]
    if waiters then
        table.insert(waiters.callbacks, callback)
        return
    end

    waiters = { callbacks = { callback }, started = GetTime() }
    pendingNameTranslations[rawName] = waiters

    local function finish(displayName)
        local w = pendingNameTranslations[rawName]
        pendingNameTranslations[rawName] = nil
        if w then
            for i = 1, table.getn(w.callbacks) do
                w.callbacks[i](displayName)
            end
        end
    end

    local ok = WoWTranslate_API.Translate(rawName, function(translation, err)
        if translation and translation ~= "" then
            DebugLog("Name translation:", rawName, "->", translation)
            WoWTranslate_CacheSave(cacheKey, translation)
            finish(translation)
        else
            DebugLog("Name translation error:", tostring(err))
            finish(rawName)
        end
    end, nameLang)

    if not ok then
        -- Queue full or duplicate in-flight at the API layer; poll cache briefly.
        pendingNameTranslations[rawName] = waiters
        local retries = 0
        if not wtNamePollFrame then
            wtNamePollFrame = CreateFrame("Frame", "WoWTranslateNamePollFrame", UIParent)
        end
        wtNamePollFrame.pollKey = rawName
        wtNamePollFrame.pollCacheKey = cacheKey
        wtNamePollFrame.pollRawName = rawName
        wtNamePollFrame.pollFinish = finish
        wtNamePollFrame.pollRetries = 0
        wtNamePollFrame.pollElapsed = 0
        wtNamePollFrame:SetScript("OnUpdate", function()
            local key = wtNamePollFrame.pollKey
            if not key then return end
            wtNamePollFrame.pollElapsed = wtNamePollFrame.pollElapsed + arg1
            if wtNamePollFrame.pollElapsed < 0.1 then return end
            wtNamePollFrame.pollElapsed = 0
            wtNamePollFrame.pollRetries = wtNamePollFrame.pollRetries + 1
            local c, hit = WoWTranslate_CacheGet(wtNamePollFrame.pollCacheKey)
            if hit then
                wtNamePollFrame:SetScript("OnUpdate", nil)
                wtNamePollFrame.pollFinish(c)
            elseif wtNamePollFrame.pollRetries >= 50 then
                wtNamePollFrame:SetScript("OnUpdate", nil)
                wtNamePollFrame.pollFinish(wtNamePollFrame.pollRawName)
            end
        end)
    end
end

local function CleanupPendingNameTranslations()
    local now = GetTime()
    for rawName, waiters in pairs(pendingNameTranslations) do
        if waiters.started and (now - waiters.started) > 45 then
            pendingNameTranslations[rawName] = nil
            if waiters.callbacks then
                for i = 1, table.getn(waiters.callbacks) do
                    waiters.callbacks[i](rawName)
                end
            end
        end
    end
end

-- Tooltip + guild footer (scoped do block: Lua 200 local limit per chunk).
local HookGameTooltip, HookItemRefTooltip
do
    local pendingGuildTranslations = {}
    local pendingGuildRankTranslations = {}
    local wtGuildPollFrame = nil
    local wtRankPollFrame = nil

    local GUILD_CACHE_PREFIX = "\1wt_guild:"
    local function GuildCacheKey(name)
        return GUILD_CACHE_PREFIX .. name
    end

    local GUILD_RANK_CACHE_PREFIX = "\1wt_guildrank:"
    local function GuildRankCacheKey(rank)
        return GUILD_RANK_CACHE_PREFIX .. rank
    end

    local function ShouldTranslateGuildName(name)
        if not WoWTranslateDB or not WoWTranslateDB.translateGuildNames then return false end
        return ShouldTranslatePlayerName(name)
    end

    local function ShouldTranslateGuildRank(rank)
        if not WoWTranslateDB or not WoWTranslateDB.translateGuildNames then return false end
        return ShouldTranslatePlayerName(rank)
    end

    function WoWTranslate_CleanupPendingTooltipTranslations()
        local now = GetTime()
        for rawGuild, waiters in pairs(pendingGuildTranslations) do
            if waiters.started and (now - waiters.started) > 45 then
                pendingGuildTranslations[rawGuild] = nil
                if waiters.callbacks then
                    for i = 1, table.getn(waiters.callbacks) do
                        waiters.callbacks[i](rawGuild)
                    end
                end
            end
        end
        for rawRank, waiters in pairs(pendingGuildRankTranslations) do
            if waiters.started and (now - waiters.started) > 45 then
                pendingGuildRankTranslations[rawRank] = nil
                if waiters.callbacks then
                    for i = 1, table.getn(waiters.callbacks) do
                        waiters.callbacks[i](rawRank)
                    end
                end
            end
        end
    end

    -- Resolve the display name for a guild (sync from cache, or async via API).
    local function ResolveGuildDisplayName(rawGuild, callback)
    if not callback then return end
    if not rawGuild or rawGuild == "" then
        callback(rawGuild)
        return
    end
    if not ShouldTranslateGuildName(rawGuild) then
        callback(rawGuild)
        return
    end

    local cacheKey = GuildCacheKey(rawGuild)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then
        callback(cached)
        return
    end

    local guildLang = DetectSourceLanguage(rawGuild)
    if not guildLang then
        callback(rawGuild)
        return
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(rawGuild)
        return
    end

    local waiters = pendingGuildTranslations[rawGuild]
    if waiters then
        table.insert(waiters.callbacks, callback)
        return
    end

    waiters = { callbacks = { callback }, started = GetTime() }
    pendingGuildTranslations[rawGuild] = waiters

    local function finish(displayGuild)
        local w = pendingGuildTranslations[rawGuild]
        pendingGuildTranslations[rawGuild] = nil
        if w then
            for i = 1, table.getn(w.callbacks) do
                w.callbacks[i](displayGuild)
            end
        end
    end

    local ok = WoWTranslate_API.Translate(rawGuild, function(translation, err)
        if translation and translation ~= "" then
            DebugLog("Guild translation:", rawGuild, "->", translation)
            WoWTranslate_CacheSave(cacheKey, translation)
            finish(translation)
        else
            DebugLog("Guild translation error:", tostring(err))
            finish(rawGuild)
        end
    end, guildLang)

    if not ok then
        pendingGuildTranslations[rawGuild] = waiters
        if not wtGuildPollFrame then
            wtGuildPollFrame = CreateFrame("Frame", "WoWTranslateGuildPollFrame", UIParent)
        end
        wtGuildPollFrame.pollCacheKey = cacheKey
        wtGuildPollFrame.pollRawGuild = rawGuild
        wtGuildPollFrame.pollFinish = finish
        wtGuildPollFrame.pollRetries = 0
        wtGuildPollFrame.pollElapsed = 0
        wtGuildPollFrame:SetScript("OnUpdate", function()
            wtGuildPollFrame.pollElapsed = wtGuildPollFrame.pollElapsed + arg1
            if wtGuildPollFrame.pollElapsed < 0.1 then return end
            wtGuildPollFrame.pollElapsed = 0
            wtGuildPollFrame.pollRetries = wtGuildPollFrame.pollRetries + 1
            local c, hit = WoWTranslate_CacheGet(wtGuildPollFrame.pollCacheKey)
            if hit then
                wtGuildPollFrame:SetScript("OnUpdate", nil)
                wtGuildPollFrame.pollFinish(c)
            elseif wtGuildPollFrame.pollRetries >= 50 then
                wtGuildPollFrame:SetScript("OnUpdate", nil)
                wtGuildPollFrame.pollFinish(wtGuildPollFrame.pollRawGuild)
            end
        end)
    end
end

-- Resolve the display text for a guild rank (sync from cache, or async via API).
local function ResolveGuildRankDisplayName(rawRank, callback)
    if not callback then return end
    if not rawRank or rawRank == "" then
        callback(rawRank)
        return
    end
    if not ShouldTranslateGuildRank(rawRank) then
        callback(rawRank)
        return
    end

    local cacheKey = GuildRankCacheKey(rawRank)
    local cached, found = WoWTranslate_CacheGet(cacheKey)
    if found then
        callback(cached)
        return
    end

    local rankLang = DetectSourceLanguage(rawRank)
    if not rankLang then
        callback(rawRank)
        return
    end

    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        callback(rawRank)
        return
    end

    local waiters = pendingGuildRankTranslations[rawRank]
    if waiters then
        table.insert(waiters.callbacks, callback)
        return
    end

    waiters = { callbacks = { callback }, started = GetTime() }
    pendingGuildRankTranslations[rawRank] = waiters

    local function finish(displayRank)
        local w = pendingGuildRankTranslations[rawRank]
        pendingGuildRankTranslations[rawRank] = nil
        if w then
            for i = 1, table.getn(w.callbacks) do
                w.callbacks[i](displayRank)
            end
        end
    end

    local ok = WoWTranslate_API.Translate(rawRank, function(translation, err)
        if translation and translation ~= "" then
            DebugLog("Guild rank translation:", rawRank, "->", translation)
            WoWTranslate_CacheSave(cacheKey, translation)
            finish(translation)
        else
            DebugLog("Guild rank translation error:", tostring(err))
            finish(rawRank)
        end
    end, rankLang)

    if not ok then
        pendingGuildRankTranslations[rawRank] = waiters
        if not wtRankPollFrame then
            wtRankPollFrame = CreateFrame("Frame", "WoWTranslateRankPollFrame", UIParent)
        end
        wtRankPollFrame.pollCacheKey = cacheKey
        wtRankPollFrame.pollRawRank = rawRank
        wtRankPollFrame.pollFinish = finish
        wtRankPollFrame.pollRetries = 0
        wtRankPollFrame.pollElapsed = 0
        wtRankPollFrame:SetScript("OnUpdate", function()
            wtRankPollFrame.pollElapsed = wtRankPollFrame.pollElapsed + arg1
            if wtRankPollFrame.pollElapsed < 0.1 then return end
            wtRankPollFrame.pollElapsed = 0
            wtRankPollFrame.pollRetries = wtRankPollFrame.pollRetries + 1
            local c, hit = WoWTranslate_CacheGet(wtRankPollFrame.pollCacheKey)
            if hit then
                wtRankPollFrame:SetScript("OnUpdate", nil)
                wtRankPollFrame.pollFinish(c)
            elseif wtRankPollFrame.pollRetries >= 50 then
                wtRankPollFrame:SetScript("OnUpdate", nil)
                wtRankPollFrame.pollFinish(wtRankPollFrame.pollRawRank)
            end
        end)
    end
end

WoWTranslate_ResolveGuildDisplayName = ResolveGuildDisplayName

-- ============================================================================
-- TOOLTIP PLAYER NAME TRANSLATION
-- ============================================================================
-- Uses the same patterns as ShaguTweaks tooltip-details and DPSMate:
--   - Hook GameTooltip.SetUnit on the frame table (not SetScript OnShow)
--   - Rebuild tooltip via ClearLines + AddLine (translation first) for correct layout/height
--   - Deferred update so other tooltip mods finish first

local wtTooltipFrame = nil
local TOOLTIP_MAX_LINES = 30

local function GetTooltipTextFont(tooltip, lineIndex)
    lineIndex = lineIndex or 1
    if tooltip == GameTooltip then
        return getglobal("GameTooltipTextLeft" .. lineIndex)
    end
    if ItemRefTooltip and tooltip == ItemRefTooltip then
        return getglobal("ItemRefTooltipTextLeft" .. lineIndex)
    end
    if tooltip and tooltip.GetName then
        return getglobal(tooltip:GetName() .. "TextLeft" .. lineIndex)
    end
end

local function GetTooltipLinePair(tooltip, lineIndex)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return nil, nil end
    return getglobal(tipName .. "TextLeft" .. lineIndex),
           getglobal(tipName .. "TextRight" .. lineIndex)
end

-- ShaguTweaks tooltip-details adds "<Guild> (rank)" after Show(). Do not replay snapshot guild rows.
local function TooltipLineLooksLikeGuild(text)
    if not text or text == "" then return false end
    local plain = StripColorCodes(text)
    if not plain or plain == "" then return false end
    plain = string.gsub(plain, "^%s+", "")
    return string.sub(plain, 1, 1) == "<" and string.find(plain, ">", 1, true) ~= nil
end

local function ParseGuildNameFromTooltipLine(text)
    if not text or text == "" then return nil end
    local plain = StripColorCodes(text)
    if not plain or plain == "" then return nil end
    plain = string.gsub(plain, "^%s+", "")
    local startBracket = string.find(plain, "<", 1, true)
    local endBracket = string.find(plain, ">", 1, true)
    if startBracket and endBracket and endBracket > startBracket + 1 then
        return string.sub(plain, startBracket + 1, endBracket - 1)
    end
    return nil
end

-- ShaguTweaks tooltip-details: gray (rank), yellow * for guild master (rankid == 0).
local function FormatGuildTooltipSuffix(rankstr, rankid)
    local rank, lead = "", ""
    if rankstr and rankstr ~= "" then
        rank = " |cffaaaaaa(" .. rankstr .. ")"
    end
    if rankid and rankid == 0 then
        lead = "|cffffcc00*|r"
    end
    return lead .. rank
end

local function FormatGuildBracketLine(guildName, rankstr, rankid)
    if not guildName or guildName == "" then return "" end
    return "<" .. guildName .. ">" .. FormatGuildTooltipSuffix(rankstr, rankid)
end

local function ParseGuildRankFromTooltipLine(text)
    if not text or text == "" then return nil, nil end
    local plain = StripColorCodes(text) or ""
    local rankid = nil
    if string.find(text, "ffffcc00", 1, true) or string.find(plain, "*", 1, true) then
        rankid = 0
    end
    local _, _, rankstr = string.find(plain, "%(([^%)]+)%)")
    return rankstr, rankid
end

local function ResolveTooltipGuildInfo(tooltip)
    if tooltip.wtGuildInfoResolved then
        return tooltip.wtGuildName, tooltip.wtGuildRank, tooltip.wtGuildRankId
    end
    tooltip.wtGuildInfoResolved = true
    tooltip.wtGuildName = nil
    tooltip.wtGuildRank = nil
    tooltip.wtGuildRankId = nil

    local unit = tooltip.wtUnit
    if unit and UnitExistsSafe(unit) and UnitIsPlayerSafe(unit) and GetGuildInfo then
        local ok, guild, rankstr, rankid = pcall(GetGuildInfo, unit)
        if ok and guild and guild ~= "" then
            tooltip.wtGuildName = guild
            tooltip.wtGuildRank = rankstr
            tooltip.wtGuildRankId = rankid
            return guild, rankstr, rankid
        end
    end

    local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    for i = 1, numLines do
        local fs = GetTooltipTextFont(tooltip, i)
        if fs and fs.GetText then
            local lineText = fs:GetText()
            if TooltipLineLooksLikeGuild(lineText) then
                local guild = ParseGuildNameFromTooltipLine(lineText)
                if guild and guild ~= "" then
                    local rankstr, rankid = ParseGuildRankFromTooltipLine(lineText)
                    tooltip.wtGuildName = guild
                    tooltip.wtGuildRank = rankstr
                    tooltip.wtGuildRankId = rankid
                    return guild, rankstr, rankid
                end
            end
        end
    end
    return nil, nil, nil
end

local function ResolveTooltipGuildName(tooltip)
    local guild = ResolveTooltipGuildInfo(tooltip)
    return guild
end

local function BuildMarkedGuildTooltipLine(tooltip, displayGuild, displayRank)
    ResolveTooltipGuildInfo(tooltip)
    local rawGuild = tooltip.wtGuildName
    local rawRank = tooltip.wtGuildRank
    if not rawGuild then return nil end

    displayGuild = displayGuild or rawGuild
    displayRank = displayRank or rawRank

    local guildChanged = displayGuild ~= rawGuild
    local rankChanged = rawRank and displayRank and displayRank ~= rawRank
    if not guildChanged and not rankChanged then return nil end

    local plainGuild = StripColorCodes(displayGuild) or rawGuild
    local body = FormatGuildBracketLine(plainGuild, displayRank, tooltip.wtGuildRankId)
    return body .. TRANSLATED_NAME_MARK
end

local function TooltipIsShown(tooltip)
    if not tooltip or not tooltip.IsShown then return false end
    local shown = tooltip:IsShown()
    return shown == 1 or shown == true
end

-- ClearLines() hides Blizzard's unit health bar (GameTooltipStatusBar). ShaguTweaks
-- tooltip-details anchors that bar above the tooltip; restore it after we relayout.
local function CaptureTooltipStatusBarState(tooltip)
    if tooltip ~= GameTooltip then return end
    local bar = GameTooltipStatusBar
    if not bar then return end
    local shown = bar:IsShown()
    tooltip.wtStatusBarWasVisible = (shown == 1 or shown == true)
end

local function RestoreTooltipStatusBar(tooltip)
    if tooltip ~= GameTooltip or not tooltip.wtStatusBarWasVisible then return end
    if not TooltipIsShown(tooltip) then return end

    local bar = GameTooltipStatusBar
    if not bar then return end

    local unit = tooltip.wtUnit
    if not unit or not UnitExistsSafe(unit) then
        unit = GetSafeMouseoverUnitToken()
    end
    if not unit or not UnitExistsSafe(unit) then return end

    local okMax, healthMax = pcall(UnitHealthMax, unit)
    if not okMax or not healthMax or healthMax <= 0 then return end

    bar:SetMinMaxValues(0, healthMax)
    local okHp, health = pcall(UnitHealth, unit)
    if okHp and health then
        bar:SetValue(health)
    end
    bar:Show()

    if bar.bg and bar.bg.Show then bar.bg:Show() end
    if bar.backdrop and bar.backdrop.Show then bar.backdrop:Show() end

    -- Optional hook for other tooltip satellite UIs (e.g. mod-specific overlays).
    if WoWTranslate_OnTooltipLayoutRefresh then
        WoWTranslate_OnTooltipLayoutRefresh(tooltip, unit)
    end
end

local function CaptureTooltipLine(left, right)
    local entry = { leftText = "", rightText = "", leftShown = false, rightShown = false }
    if left then
        entry.leftText = left:GetText() or ""
        entry.leftR, entry.leftG, entry.leftB = left:GetTextColor()
        entry.leftShown = entry.leftText ~= ""
    end
    if right then
        entry.rightText = right:GetText() or ""
        entry.rightR, entry.rightG, entry.rightB = right:GetTextColor()
        entry.rightShown = entry.rightText ~= ""
    end
    return entry
end

local function ClearTooltipLine(left, right)
    if left and left.Hide then
        left:SetText("")
        left:Hide()
    end
    if right and right.Hide then
        right:SetText("")
        right:Hide()
    end
end

local function SnapshotTooltipLines(tooltip)
    local numLines = 1
    if tooltip.NumLines then
        numLines = tooltip:NumLines()
        if numLines < 1 then numLines = 1 end
    end
    local snap = { numLines = numLines, lines = {} }
    for i = 1, numLines do
        local left, right = GetTooltipLinePair(tooltip, i)
        snap.lines[i] = CaptureTooltipLine(left, right)
    end
    return snap
end

-- Wipe every tooltip font string so nothing can linger after hide.
local function WipeTooltipTextLines(tooltip)
    local tipName = tooltip and tooltip.GetName and tooltip:GetName()
    if not tipName then return end
    for i = 1, TOOLTIP_MAX_LINES do
        ClearTooltipLine(
            getglobal(tipName .. "TextLeft" .. i),
            getglobal(tipName .. "TextRight" .. i)
        )
    end
end

-- Full cleanup when tooltip closes or we reset (never call Show() here).
local function ClearTooltipNameHeader(tooltip)
    if not tooltip then return end

    if wtTooltipFrame and wtTooltipFrame.watchTooltip == tooltip then
        wtTooltipFrame.watchTooltip = nil
        wtTooltipFrame:SetScript("OnUpdate", nil)
    end

    if tooltip.ClearLines then
        tooltip:ClearLines()
    end
    WipeTooltipTextLines(tooltip)

    tooltip.wtLineSnapshot = nil
    tooltip.wtLine1Text = nil
    tooltip.wtAddedNameLine = nil
    tooltip.wtNameResolvePending = nil
    tooltip.wtGuildName = nil
    tooltip.wtGuildRank = nil
    tooltip.wtGuildRankId = nil
    tooltip.wtGuildInfoResolved = nil
    tooltip.wtGuildResolvePending = nil
    tooltip.wtRankResolvePending = nil
    tooltip.wtStatusBarWasVisible = nil

    if tooltip.wtNameHeader then tooltip.wtNameHeader:Hide() end
    if tooltip.wtNameHeaderText then tooltip.wtNameHeaderText:SetText("") end
end

-- Replay one captured row through the native AddLine / AddDoubleLine APIs.
local function ReplayTooltipLine(tooltip, entry)
    if not entry then return end
    local hasLeft  = entry.leftShown and entry.leftText and entry.leftText ~= ""
    local hasRight = entry.rightShown and entry.rightText and entry.rightText ~= ""

    if hasRight and tooltip.AddDoubleLine then
        tooltip:AddDoubleLine(
            hasLeft and entry.leftText or "",
            entry.rightText,
            entry.leftR or 1, entry.leftG or 1, entry.leftB or 1,
            entry.rightR or 1, entry.rightG or 1, entry.rightB or 1
        )
    elseif hasLeft and tooltip.AddLine then
        tooltip:AddLine(entry.leftText, entry.leftR or 1, entry.leftG or 1, entry.leftB or 1)
    elseif hasRight and tooltip.AddLine then
        tooltip:AddLine(entry.rightText, entry.rightR or 1, entry.rightG or 1, entry.rightB or 1)
    end
end

-- Fallback: prepend to line 1 (no extra row; WoW expands the first line with |n).
local function InsertTooltipNamePrepend(tooltip, text)
    local left1 = GetTooltipTextFont(tooltip, 1)
    if not left1 then return end
    local orig = left1:GetText() or ""
    if tooltip.wtLine1Text then return end
    tooltip.wtLine1Text = orig
    CaptureTooltipStatusBarState(tooltip)
    left1:SetText(text .. "|n" .. orig)
    tooltip.wtAddedNameLine = true
    tooltip:Show()
    RestoreTooltipStatusBar(tooltip)
end

-- Shagu-style green line: <Guild>* (rank) using raw (untranslated) guild and rank.
local function AddOriginalGuildTooltipLine(tooltip, guildEntry)
    if not tooltip or not tooltip.wtGuildName or tooltip.wtGuildName == "" then return end
    if not tooltip.AddLine then return end

    local rankstr = tooltip.wtGuildRank
    local rankid = tooltip.wtGuildRankId
    if (not rankstr or rankstr == "") and guildEntry and guildEntry.leftText then
        local rs, ri = ParseGuildRankFromTooltipLine(guildEntry.leftText)
        rankstr = rs
        if ri then rankid = ri end
    end

    tooltip:AddLine(
        FormatGuildBracketLine(tooltip.wtGuildName, rankstr, rankid),
        0.3, 1, 0.5)
end

-- Rebuild tooltip: optional translated name on line 1, guild footer at bottom.
local function InsertTooltipNameInside(tooltip, nameText, guildText)
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not TooltipIsShown(tooltip) then return end

    local hasNameLine = nameText and nameText ~= ""
    local hasGuildLine = guildText and guildText ~= ""
    if not hasNameLine and not hasGuildLine then return end

    if not tooltip.ClearLines or not tooltip.AddLine then
        if hasNameLine then
            InsertTooltipNamePrepend(tooltip, nameText)
        end
        return
    end

    tooltip.wtLineSnapshot = SnapshotTooltipLines(tooltip)
    CaptureTooltipStatusBarState(tooltip)
    ResolveTooltipGuildInfo(tooltip)

    tooltip:ClearLines()
    if hasNameLine then
        tooltip:AddLine(nameText, 1, 1, 1)
    end

    local guildEntry = nil
    for i = 1, tooltip.wtLineSnapshot.numLines do
        local entry = tooltip.wtLineSnapshot.lines[i]
        if entry and entry.leftShown and entry.leftText
                and TooltipLineLooksLikeGuild(entry.leftText) then
            if not guildEntry then
                guildEntry = entry
                if not tooltip.wtGuildRank or tooltip.wtGuildRank == "" then
                    local rankstr, rankid = ParseGuildRankFromTooltipLine(entry.leftText)
                    tooltip.wtGuildRank = rankstr
                    if rankid then tooltip.wtGuildRankId = rankid end
                end
            end
        else
            ReplayTooltipLine(tooltip, entry)
        end
    end

    local numLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    for i = numLines + 1, TOOLTIP_MAX_LINES do
        local left, right = GetTooltipLinePair(tooltip, i)
        ClearTooltipLine(left, right)
    end

    -- Guild last: translated line + original <Guild> (rank); or single untranslated line.
    if guildText and guildText ~= "" then
        tooltip:AddLine(guildText, 1, 1, 1)
        AddOriginalGuildTooltipLine(tooltip, guildEntry)
    elseif guildEntry then
        ReplayTooltipLine(tooltip, guildEntry)
    else
        AddOriginalGuildTooltipLine(tooltip, guildEntry)
    end

    tooltip.wtAddedNameLine = true
    tooltip:Show()
    RestoreTooltipStatusBar(tooltip)
end

-- Debounced layout refresh when other mods add lines after our rebuild (pet, challenges).
local function ArmTooltipLayoutWatch(tooltip)
    if not wtTooltipFrame or not tooltip then return end
    wtTooltipFrame.watchTooltip = tooltip
    wtTooltipFrame.watchLines = (tooltip.NumLines and tooltip:NumLines()) or 0
    wtTooltipFrame.watchElapsed = 0
    wtTooltipFrame.layoutDelay = 0
    wtTooltipFrame.layoutPending = true
    wtTooltipFrame:SetScript("OnUpdate", function()
        local tip = wtTooltipFrame.watchTooltip
        if not tip or not TooltipIsShown(tip) or not tip.wtAddedNameLine then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
            return
        end
        wtTooltipFrame.watchElapsed = wtTooltipFrame.watchElapsed + arg1
        local n = (tip.NumLines and tip:NumLines()) or 0
        if n ~= wtTooltipFrame.watchLines then
            wtTooltipFrame.watchLines = n
            wtTooltipFrame.layoutDelay = 0
            wtTooltipFrame.layoutPending = true
        elseif wtTooltipFrame.layoutPending then
            wtTooltipFrame.layoutDelay = wtTooltipFrame.layoutDelay + arg1
            if wtTooltipFrame.layoutDelay >= 0.12 then
                -- Do not call Show() here; it drops lines ShaguTweaks added after our rebuild.
                RestoreTooltipStatusBar(tip)
                wtTooltipFrame.layoutPending = nil
                wtTooltipFrame.layoutDelay = 0
            end
        end
        if wtTooltipFrame.watchElapsed >= 1.0 then
            wtTooltipFrame.watchTooltip = nil
            wtTooltipFrame:SetScript("OnUpdate", nil)
        end
    end)
end

local function ParsePlayerHyperlink(link)
    if not link then return nil end
    if string.sub(link, 1, 7) ~= "player:" then return nil end
    local name = string.sub(link, 8)
    if name and name ~= "" then return name end
    return nil
end

-- Find which player unit the tooltip is showing (ShaguTweaks-style scan).
local function FindPlayerUnitFromTooltipText(tipText)
    if not tipText or tipText == "" then return nil end
    local plain = StripColorCodes(tipText)

    local function matchUnit(unit)
        if UnitIsPlayerSafe(unit) then
            local name = UnitNameSafe(unit)
            local pvp  = UnitPVPNameSafe(unit)
            if name and (string.find(plain, name, 1, true) or (pvp and string.find(plain, pvp, 1, true))) then
                return unit, name, pvp
            end
        end
    end

    local mouseUnit = GetSafeMouseoverUnitToken()
    if mouseUnit then
        local unit, name, pvp = matchUnit(mouseUnit)
        if unit then return unit, name, pvp end
    end
    local targetUnit = GetSafeTargetUnitToken()
    if targetUnit then
        local unit, name, pvp = matchUnit(targetUnit)
        if unit then return unit, name, pvp end
    end
    local unit, name, pvp = matchUnit("player")
    if unit then return unit, name, pvp end

    local numParty = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, numParty do
        unit, name, pvp = matchUnit("party" .. i)
        if unit then return unit, name, pvp end
    end
    local numRaid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    for i = 1, numRaid do
        unit, name, pvp = matchUnit("raid" .. i)
        if unit then return unit, name, pvp end
    end
    return nil
end

local function ResolveTooltipPlayerName(tooltip)
    if tooltip.wtPlayerName and tooltip.wtPlayerName ~= "" then
        local altName = nil
        if tooltip.wtUnit and UnitExistsSafe(tooltip.wtUnit) then
            altName = UnitPVPNameSafe(tooltip.wtUnit)
        end
        return tooltip.wtPlayerName, altName
    end

    if tooltip.wtUnit and UnitIsPlayerSafe(tooltip.wtUnit) then
        local name = UnitNameSafe(tooltip.wtUnit)
        local pvp  = UnitPVPNameSafe(tooltip.wtUnit)
        if name and name ~= "" then
            tooltip.wtPlayerName = name
            return name, pvp
        end
    end

    local fs = GetTooltipTextFont(tooltip, 1)
    if fs and fs.GetText then
        local tipText = fs:GetText()
        local unit, name, pvp = FindPlayerUnitFromTooltipText(tipText)
        if name then
            tooltip.wtUnit = unit
            tooltip.wtPlayerName = name
            return name, pvp
        end
        local plain = StripColorCodes(tipText)
        if plain and plain ~= "" and ShouldTranslatePlayerName(plain) then
            tooltip.wtPlayerName = plain
            return plain, nil
        end
    end
    return nil
end

local function ApplyTooltipPlayerNameColor(tooltip, rawName)
    if not PlayerNameClassColorEnabled() then return end
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not TooltipIsShown(tooltip) then return end
    local fs = GetTooltipTextFont(tooltip, 1)
    if not fs or not fs.GetText or not fs.SetText then return end
    local text = fs:GetText()
    if not text or text == "" then return end
    local colored = ColorizePlayerName(rawName, text, tooltip.wtUnit)
    if colored and colored ~= text then
        fs:SetText(colored)
    end
end

local function AddTooltipTranslationLine(tooltip, rawName, displayName, rawGuild, guildDisplayName, rankDisplayName)
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not displayName or displayName == rawName then return end
    if not TooltipIsShown(tooltip) then return end
    if tooltip.wtPlayerName ~= rawName then return end

    local markedName = MarkTranslatedDisplayName(rawName, displayName, tooltip.wtUnit)
    local markedGuild = BuildMarkedGuildTooltipLine(tooltip, guildDisplayName, rankDisplayName)
    InsertTooltipNameInside(tooltip, markedName, markedGuild)
end

-- Native player name but guild and/or rank need translation: rebuild footer only.
local function ApplyTooltipGuildFooterTranslation(tooltip, guildDisplayName, rankDisplayName)
    if not tooltip or tooltip.wtAddedNameLine then return end
    if not TooltipIsShown(tooltip) then return end

    local markedGuild = BuildMarkedGuildTooltipLine(tooltip, guildDisplayName, rankDisplayName)
    if not markedGuild then return end

    InsertTooltipNameInside(tooltip, nil, markedGuild)
    if tooltip.wtAddedNameLine then
        ArmTooltipLayoutWatch(tooltip)
    end
end

local function ResolveTooltipGuildFooter(tooltip, callback)
    if not callback then return end
    ResolveTooltipGuildInfo(tooltip)
    local rawGuild = tooltip.wtGuildName
    local rawRank = tooltip.wtGuildRank
    local wantGuild = rawGuild and ShouldTranslateGuildName(rawGuild)
    local wantRank = rawRank and rawRank ~= "" and ShouldTranslateGuildRank(rawRank)

    if not wantGuild and not wantRank then
        callback(nil, nil)
        return
    end

    local pending = 0
    local guildOut = rawGuild
    local rankOut = rawRank

    local function tryDone()
        pending = pending - 1
        if pending > 0 then return end
        tooltip.wtGuildResolvePending = nil
        tooltip.wtRankResolvePending = nil
        callback(guildOut, rankOut)
    end

    if wantGuild then
        local cached, found = WoWTranslate_CacheGet(GuildCacheKey(rawGuild))
        if found then
            guildOut = cached
        else
            pending = pending + 1
            tooltip.wtGuildResolvePending = rawGuild
            ResolveGuildDisplayName(rawGuild, function(displayGuild)
                guildOut = displayGuild
                tryDone()
            end)
        end
    end

    if wantRank then
        local cached, found = WoWTranslate_CacheGet(GuildRankCacheKey(rawRank))
        if found then
            rankOut = cached
        else
            pending = pending + 1
            tooltip.wtRankResolvePending = rawRank
            ResolveGuildRankDisplayName(rawRank, function(displayRank)
                rankOut = displayRank
                tryDone()
            end)
        end
    end

    if pending == 0 then
        callback(guildOut, rankOut)
    end
end

local function UpdateTooltipGuildOnly(tooltip, rawGuild)
    if not tooltip or not rawGuild or rawGuild == "" then return end
    if tooltip.wtAddedNameLine then return end
    if tooltip.wtGuildResolvePending or tooltip.wtRankResolvePending then return end

    ResolveTooltipGuildFooter(tooltip, function(guildDisplay, rankDisplay)
        if not TooltipIsShown(tooltip) then return end
        if tooltip.wtGuildName ~= rawGuild then return end
        ApplyTooltipGuildFooterTranslation(tooltip, guildDisplay, rankDisplay)
    end)
end

local function UpdateTooltipPlayerNames(tooltip)
    if not tooltip then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
    if not TooltipIsShown(tooltip) then return end
    if tooltip.wtAddedNameLine then return end

    local rawName = ResolveTooltipPlayerName(tooltip)
    if not rawName or rawName == "" then return end
    if not ShouldTranslatePlayerName(rawName) then
        ApplyTooltipPlayerNameColor(tooltip, rawName)
        local rawGuild = ResolveTooltipGuildName(tooltip)
        ResolveTooltipGuildInfo(tooltip)
        local wantGuild = rawGuild and ShouldTranslateGuildName(rawGuild)
        local wantRank = tooltip.wtGuildRank and tooltip.wtGuildRank ~= ""
            and ShouldTranslateGuildRank(tooltip.wtGuildRank)
        if rawGuild and (wantGuild or wantRank) then
            UpdateTooltipGuildOnly(tooltip, rawGuild)
        end
        return
    end

    if not WoWTranslateDB.translatePlayerNames then return end

    local rawGuild = ResolveTooltipGuildName(tooltip)
    ResolveTooltipGuildInfo(tooltip)
    local rawRank = tooltip.wtGuildRank
    local wantGuildTranslate = rawGuild and ShouldTranslateGuildName(rawGuild)
    local wantRankTranslate = rawRank and rawRank ~= "" and ShouldTranslateGuildRank(rawRank)
    local wantGuildFooter = wantGuildTranslate or wantRankTranslate

    local function applyDisplay(displayName, guildDisplayName, rankDisplayName)
        AddTooltipTranslationLine(tooltip, rawName, displayName, rawGuild,
            guildDisplayName, rankDisplayName)
        if tooltip.wtAddedNameLine then
            ArmTooltipLayoutWatch(tooltip)
        end
    end

    local function finishTooltipTranslations(displayName, guildDisplayName, rankDisplayName)
        if not TooltipIsShown(tooltip) then return end
        if tooltip.wtPlayerName ~= rawName then return end
        applyDisplay(displayName, guildDisplayName, rankDisplayName)
    end

    local function guildFooterArgs(guildResolved, rankResolved)
        local g = rawGuild
        local r = rawRank
        if wantGuildTranslate and guildResolved then g = guildResolved end
        if wantRankTranslate and rankResolved then r = rankResolved end
        return g, r
    end

    local nameCached, nameFound = WoWTranslate_CacheGet(NameCacheKey(rawName))
    local guildCached, guildFound = false, false
    local rankCached, rankFound = false, false
    if wantGuildTranslate then
        guildCached, guildFound = WoWTranslate_CacheGet(GuildCacheKey(rawGuild))
    end
    if wantRankTranslate then
        rankCached, rankFound = WoWTranslate_CacheGet(GuildRankCacheKey(rawRank))
    end

    if nameFound and (not wantGuildFooter or ((not wantGuildTranslate or guildFound)
            and (not wantRankTranslate or rankFound))) then
        local g, r = guildFooterArgs(
            wantGuildTranslate and guildCached or nil,
            wantRankTranslate and rankCached or nil)
        finishTooltipTranslations(nameCached, g, r)
        return
    end

    if tooltip.wtNameResolvePending == rawName then return end
    tooltip.wtNameResolvePending = rawName

    local pending = 0
    local resolvedName = rawName
    local resolvedGuild = rawGuild
    local resolvedRank = rawRank

    local function tryFinish()
        pending = pending - 1
        if pending > 0 then return end
        tooltip.wtNameResolvePending = nil
        tooltip.wtGuildResolvePending = nil
        tooltip.wtRankResolvePending = nil
        local g, r = guildFooterArgs(resolvedGuild, resolvedRank)
        finishTooltipTranslations(resolvedName, g, r)
    end

    if not nameFound then
        pending = pending + 1
        ResolvePlayerDisplayName(rawName, function(displayName)
            resolvedName = displayName
            tryFinish()
        end)
    else
        resolvedName = nameCached
    end

    if wantGuildTranslate and not guildFound then
        pending = pending + 1
        tooltip.wtGuildResolvePending = rawGuild
        ResolveGuildDisplayName(rawGuild, function(displayGuild)
            resolvedGuild = displayGuild
            tryFinish()
        end)
    elseif wantGuildTranslate then
        resolvedGuild = guildCached
    end

    if wantRankTranslate and not rankFound then
        pending = pending + 1
        tooltip.wtRankResolvePending = rawRank
        ResolveGuildRankDisplayName(rawRank, function(displayRank)
            resolvedRank = displayRank
            tryFinish()
        end)
    elseif wantRankTranslate then
        resolvedRank = rankCached
    end

    if pending == 0 then
        tooltip.wtNameResolvePending = nil
        tooltip.wtGuildResolvePending = nil
        tooltip.wtRankResolvePending = nil
        local g, r = guildFooterArgs(resolvedGuild, resolvedRank)
        finishTooltipTranslations(resolvedName, g, r)
    end
end

    local function hookGameTooltip()
    if not GameTooltip then return end

    -- Frame object persists across /reload; unwrap before re-installing wrappers.
    if GameTooltip.WoWTranslateOrigSetUnit then
        GameTooltip.SetUnit = GameTooltip.WoWTranslateOrigSetUnit
    end
    if GameTooltip.WoWTranslateOrigSetHyperlink then
        GameTooltip.SetHyperlink = GameTooltip.WoWTranslateOrigSetHyperlink
    end
    if GameTooltip.WoWTranslateOrigAddDoubleLine then
        GameTooltip.AddDoubleLine = GameTooltip.WoWTranslateOrigAddDoubleLine
        GameTooltip.WoWTranslateOrigAddDoubleLine = nil
    end

    if not GameTooltip.WoWTranslateOrigSetUnit then
        GameTooltip.WoWTranslateOrigSetUnit = GameTooltip.SetUnit
    end
    if GameTooltip.SetHyperlink and not GameTooltip.WoWTranslateOrigSetHyperlink then
        GameTooltip.WoWTranslateOrigSetHyperlink = GameTooltip.SetHyperlink
    end

    GameTooltip.WoWTranslateTooltipHooked = true
    local origSetUnit = GameTooltip.WoWTranslateOrigSetUnit
    function GameTooltip:SetUnit(unit)
        ClearTooltipNameHeader(GameTooltip)
        GameTooltip.wtUnit = unit
        GameTooltip.wtPlayerName = nil
        GameTooltip.wtNameResolvePending = nil
        GameTooltip.wtGuildName = nil
        GameTooltip.wtGuildRank = nil
        GameTooltip.wtGuildRankId = nil
        GameTooltip.wtGuildInfoResolved = nil
        GameTooltip.wtGuildResolvePending = nil
        GameTooltip.wtRankResolvePending = nil
        if unit and UnitIsPlayerSafe(unit) then
            GameTooltip.wtPlayerName = UnitNameSafe(unit)
        end
        if origSetUnit then
            return origSetUnit(self, unit)
        end
    end

    if GameTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = GameTooltip.WoWTranslateOrigSetHyperlink
        function GameTooltip:SetHyperlink(link)
            ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = ParsePlayerHyperlink(link)
            GameTooltip.wtNameResolvePending = nil
            if origSetHyperlink then
                return origSetHyperlink(self, link)
            end
        end
    end

    -- Child frame hooks (ShaguTweaks / pfItemClickHelpMessage pattern).
    if not wtTooltipFrame then
        wtTooltipFrame = getglobal("WoWTranslateTooltipFrame")
    end
    if not wtTooltipFrame then
        wtTooltipFrame = CreateFrame("Frame", "WoWTranslateTooltipFrame", GameTooltip)

        local function DeferUpdateGameTooltip()
            if not TooltipIsShown(GameTooltip) then return end
            if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending
                or GameTooltip.wtGuildResolvePending or GameTooltip.wtRankResolvePending then return end
            UpdateTooltipPlayerNames(GameTooltip)
        end

        local function ArmTooltipDefer()
            wtTooltipFrame.elapsed = 0
            wtTooltipFrame:SetScript("OnUpdate", function()
                if not TooltipIsShown(GameTooltip) then
                    wtTooltipFrame.elapsed = 0
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                if GameTooltip.wtAddedNameLine or GameTooltip.wtNameResolvePending
                    or GameTooltip.wtGuildResolvePending or GameTooltip.wtRankResolvePending then
                    wtTooltipFrame:SetScript("OnUpdate", nil)
                    return
                end
                wtTooltipFrame.elapsed = wtTooltipFrame.elapsed + arg1
                if wtTooltipFrame.elapsed < 0.4 then return end
                wtTooltipFrame:SetScript("OnUpdate", nil)
                DeferUpdateGameTooltip()
            end)
        end

        wtTooltipFrame:SetScript("OnShow", function()
            ArmTooltipDefer()
        end)
        if not GameTooltip.WoWTranslateOrigOnHide then
            GameTooltip.WoWTranslateOrigOnHide = GameTooltip:GetScript("OnHide")
        end
        local origOnHide = GameTooltip.WoWTranslateOrigOnHide
        GameTooltip:SetScript("OnHide", function()
            ClearTooltipNameHeader(GameTooltip)
            GameTooltip.wtUnit = nil
            GameTooltip.wtPlayerName = nil
            GameTooltip.wtNameResolvePending = nil
            if origOnHide then origOnHide() end
        end)
    end
end

    local function hookItemRefTooltip()
    if not ItemRefTooltip then return end

    if ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        ItemRefTooltip.SetHyperlink = ItemRefTooltip.WoWTranslateOrigSetHyperlink
    end
    if ItemRefTooltip.WoWTranslateOrigAddLine then
        ItemRefTooltip.AddLine = ItemRefTooltip.WoWTranslateOrigAddLine
        ItemRefTooltip.WoWTranslateOrigAddLine = nil
    end
    if ItemRefTooltip.WoWTranslateOrigAddDoubleLine then
        ItemRefTooltip.AddDoubleLine = ItemRefTooltip.WoWTranslateOrigAddDoubleLine
        ItemRefTooltip.WoWTranslateOrigAddDoubleLine = nil
    end
    if ItemRefTooltip.SetHyperlink and not ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        ItemRefTooltip.WoWTranslateOrigSetHyperlink = ItemRefTooltip.SetHyperlink
    end

    ItemRefTooltip.WoWTranslateTooltipHooked = true

    if ItemRefTooltip.WoWTranslateOrigSetHyperlink then
        local origSetHyperlink = ItemRefTooltip.WoWTranslateOrigSetHyperlink
        function ItemRefTooltip:SetHyperlink(link)
            ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtUnit = nil
            ItemRefTooltip.wtPlayerName = ParsePlayerHyperlink(link)
            ItemRefTooltip.wtNameResolvePending = nil
            if origSetHyperlink then
                return origSetHyperlink(self, link)
            end
        end
    end

    local refFrame = getglobal("WoWTranslateItemRefTooltipFrame")
    if not refFrame then
        refFrame = CreateFrame("Frame", "WoWTranslateItemRefTooltipFrame", ItemRefTooltip)
        refFrame:SetScript("OnShow", function()
            refFrame.elapsed = 0
            refFrame:SetScript("OnUpdate", function()
                if not TooltipIsShown(ItemRefTooltip) then
                    refFrame:SetScript("OnUpdate", nil)
                    return
                end
                if ItemRefTooltip.wtAddedNameLine or ItemRefTooltip.wtNameResolvePending
                    or ItemRefTooltip.wtGuildResolvePending or ItemRefTooltip.wtRankResolvePending then
                    refFrame:SetScript("OnUpdate", nil)
                    return
                end
                refFrame.elapsed = refFrame.elapsed + arg1
                if refFrame.elapsed < 0.25 then return end
                refFrame:SetScript("OnUpdate", nil)
                UpdateTooltipPlayerNames(ItemRefTooltip)
            end)
        end)
        if not ItemRefTooltip.WoWTranslateOrigOnHide then
            ItemRefTooltip.WoWTranslateOrigOnHide = ItemRefTooltip:GetScript("OnHide")
        end
        local refOrigOnHide = ItemRefTooltip.WoWTranslateOrigOnHide
        ItemRefTooltip:SetScript("OnHide", function()
            ClearTooltipNameHeader(ItemRefTooltip)
            ItemRefTooltip.wtPlayerName = nil
            ItemRefTooltip.wtNameResolvePending = nil
            if refOrigOnHide then refOrigOnHide() end
        end)
    end
    end

    HookGameTooltip = hookGameTooltip
    HookItemRefTooltip = hookItemRefTooltip
end

-- ============================================================================
-- NAMEPLATE (OVERHEAD) NAME TRANSLATION
-- ============================================================================
-- In WoW 1.12, floating names above units are drawn on nameplate FontStrings
-- (plate.name). True 3D overhead names without nameplates cannot be modified.
-- Uses ShaguTweaks.libnameplate when present; otherwise scans WorldFrame children.
-- Modded plates (ShaguPlates, etc.) use parent.nameplate.name for display; the Blizzard
-- region (nameplate.original.name) keeps the real unit name for the mod to read.

local HookNameplates, ResetNameplateScanner
do
local NAMEPLATE_OBJECTORDER = { "border", "glow", "name", "level", "levelicon", "raidicon" }
local wtNameplateShaguHooked = false
local wtShaguPlatesHooked = false
local wtNameplateRegistry = {}
local wtNameplateScanFrame = nil
local wtNameplateScanInitialized = 0
local NAMEPLATE_NAME_UPDATE_INTERVAL = 0.2

local function NameplateNameUpdateDue(plate)
    if not plate then return true end
    local now = GetTime()
    if plate.wtNextNameUpdate and now < plate.wtNextNameUpdate then
        return false
    end
    plate.wtNextNameUpdate = now + NAMEPLATE_NAME_UPDATE_INTERVAL
    return true
end

local function NameplateFrameVisible(plate)
    if not plate then return false end
    if plate.IsVisible then
        local v = plate:IsVisible()
        if v and v ~= 0 then return true end
    end
    if plate.IsShown then
        local s = plate:IsShown()
        if s and s ~= 0 then return true end
    end
    return false
end

local function PruneNameplateRegistry()
    for plate in pairs(wtNameplateRegistry) do
        if not NameplateFrameVisible(plate) then
            wtNameplateRegistry[plate] = nil
        end
    end
end

local function IsNamePlateFrame(frame)
    if not frame or not frame.GetObjectType then return false end
    local otype = frame:GetObjectType()
    if otype ~= "Button" and otype ~= "Frame" then return false end

    local regions = frame:GetRegions()
    if regions and regions.GetObjectType and regions.GetTexture then
        if regions:GetObjectType() == "Texture" then
            local tex = regions:GetTexture()
            if tex == "Interface\\Tooltips\\Nameplate-Border" then
                return true
            end
        end
    end

    -- Fallback: nameplate-like frame (healthbar child + name FontString).
    if frame.GetChildren then
        local child = frame:GetChildren()
        if child and frame.GetRegions then
            for i, object in pairs({ frame:GetRegions() }) do
                if object and object.GetObjectType and object:GetObjectType() == "FontString" then
                    local t = object:GetText()
                    if t and t ~= "" and not string.find(t, "^Level ") then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Match ShaguTweaks libnameplate: region index maps to NAMEPLATE_OBJECTORDER.
local function AssignNameplateRegions(plate)
    for i, object in pairs({ plate:GetRegions() }) do
        if NAMEPLATE_OBJECTORDER[i] then
            plate[NAMEPLATE_OBJECTORDER[i]] = object
        end
    end
end

-- ShaguPlates and similar: overlay frame hung off the Blizzard nameplate parent.
local function GetNameplateOverlay(parent)
    if not parent then return nil end
    local overlay = parent.nameplate
    if overlay and overlay.name and overlay.name.GetText and overlay.name.SetText then
        return overlay
    end
end

-- Vanilla: keep Blizzard plate.name as the raw label (ShaguTweaks classcolor reads GetText).
-- Draw translations on a sibling FontString so GetUnitData(name, true) is not queued forever.
local function EnsureVanillaTranslateNameFont(plate)
    if not plate or GetNameplateOverlay(plate) then return nil end
    if plate.wtTranslateName and plate.wtTranslateName.GetText then
        return plate.wtTranslateName
    end
    AssignNameplateRegions(plate)
    local src = plate.name
    if not src or not src.GetText then return nil end

    local fs = plate:CreateFontString("WoWTranslateNameplateName", "OVERLAY")
    if src.GetFont and fs.SetFont then
        local font, size, flags = src:GetFont()
        if font then fs:SetFont(font, size or 12, flags) end
    end
    ApplyNameplateFontShadow(fs, src)
    if src.GetJustifyH and fs.SetJustifyH then fs:SetJustifyH(src:GetJustifyH()) end
    if src.GetJustifyV and fs.SetJustifyV then fs:SetJustifyV(src:GetJustifyV()) end

    local point, relTo, relPoint, xOfs, yOfs = src:GetPoint()
    if point then
        fs:SetPoint(point, relTo or plate, relPoint or point, xOfs or 0, yOfs or 0)
    else
        fs:SetPoint("BOTTOM", plate, "TOP", 0, 0)
    end

    plate.wtTranslateName = fs
    if src.SetAlpha then src:SetAlpha(0) end
    fs:Show()
    return fs
end

local function SyncVanillaNameplateSourceText(plate, rawName)
    if not plate or not rawName or rawName == "" or GetNameplateOverlay(plate) then return end
    AssignNameplateRegions(plate)
    local src = plate.name
    if not src or not src.SetText then return end
    local current = src:GetText()
    if current ~= rawName then
        src:SetText(rawName)
    end
    if src.SetAlpha then src:SetAlpha(0) end
end

-- FontString the player actually sees (Shagu overlay, vanilla translate overlay, else Blizzard).
local function GetNameplateDisplayNameFont(parent)
    local overlay = GetNameplateOverlay(parent)
    if overlay then
        return overlay.name
    end

    local vanillaFs = EnsureVanillaTranslateNameFont(parent)
    if vanillaFs then return vanillaFs end

    AssignNameplateRegions(parent)
    if parent.name and parent.name.GetText then
        local t = parent.name:GetText()
        if t and t ~= "" then return parent.name end
    end
    for i, object in pairs({ parent:GetRegions() }) do
        if NAMEPLATE_OBJECTORDER[i] == "name" and object and object.GetText then
            return object
        end
    end
    for i, object in pairs({ parent:GetRegions() }) do
        if object and object.GetObjectType and object:GetObjectType() == "FontString" then
            local t = object:GetText()
            if t and t ~= "" and not string.find(t, "^Level ") then
                return object
            end
        end
    end
end

-- Untouched Blizzard name text (mods read this; never write translations here).
local function GetNameplateSourceNameFont(parent)
    local overlay = GetNameplateOverlay(parent)
    if overlay and overlay.original and overlay.original.name and overlay.original.name.GetText then
        return overlay.original.name
    end
    return GetNameplateDisplayNameFont(parent)
end

local function GetNameplateHealthbar(parent)
    if not parent then return nil end
    local overlay = GetNameplateOverlay(parent)
    if overlay and overlay.health and overlay.health.Hide then
        return overlay.health
    end
    if parent.wtHealthbar then return parent.wtHealthbar end
    if parent.healthbar and parent.healthbar.GetObjectType then
        parent.wtHealthbar = parent.healthbar
        return parent.wtHealthbar
    end
    if parent.GetChildren then
        local child = parent:GetChildren()
        if child then
            parent.wtHealthbar = child
            return child
        end
    end
end

-- Same thresholds as ShaguPlates nameplates.GetUnitType (original.healthbar colors).
local function GetShaguBarUnitType(r, g, b)
    if not r then return "ENEMY_NPC" end
    if r > .9 and g < .2 and b < .2 then
        return "ENEMY_NPC"
    elseif r > .9 and g > .9 and b < .2 then
        return "NEUTRAL_NPC"
    elseif r < .2 and g < .2 and b > .9 then
        return "FRIENDLY_PLAYER"
    elseif r < .2 and g > .9 and b < .2 then
        return "FRIENDLY_NPC"
    end
    return "ENEMY_NPC"
end

local function FactionRgbFromBarRgb(r, g, b)
    local ut = GetShaguBarUnitType(r, g, b)
    if ut == "NEUTRAL_NPC" then return 1, 1, 0 end
    if ut == "FRIENDLY_NPC" then return 0, 1, 0 end
    if ut == "FRIENDLY_PLAYER" then return nil end
    return 1, 0, 0
end

local function GetBlizzardNameplateNameRgb(plate)
    local overlay = GetNameplateOverlay(plate)
    if overlay and overlay.original and overlay.original.name and overlay.original.name.GetTextColor then
        local r, g, b = overlay.original.name:GetTextColor()
        if r then return r, g, b end
    end
    if plate and plate.name and plate.name.GetTextColor then
        local r, g, b = plate.name:GetTextColor()
        if r then return r, g, b end
    end
    return nil
end

IsNameplatePlayerForColor = function(plate, rawName)
    local overlay = GetNameplateOverlay(plate)
    if not overlay then return false end
    if overlay.cache and overlay.cache.player == "NPC" then return false end
    if overlay.cache and overlay.cache.player == "PLAYER" then return true end

    local bar = overlay.original and overlay.original.healthbar
    if not bar or not bar.GetStatusBarColor then return false end
    local r, g, b = bar:GetStatusBarColor()
    local ut = GetShaguBarUnitType(r, g, b)
    if ut == "FRIENDLY_NPC" or ut == "NEUTRAL_NPC" then return false end
    if ut == "FRIENDLY_PLAYER" then return true end
    if ut == "ENEMY_NPC" and rawName and rawName ~= "" then
        if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then return true end
        if ShaguTweaks_cache and ShaguTweaks_cache.players and ShaguTweaks_cache.players[rawName] then
            return true
        end
    end
    return false
end

local function GetNameplateFactionBar(plate)
    if not plate then return nil end
    local overlay = GetNameplateOverlay(plate)
    -- ShaguPlates: read Blizzard bar (same source as Shagu GetUnitType), not the styled overlay.health.
    if overlay and overlay.original and overlay.original.healthbar
        and overlay.original.healthbar.GetStatusBarColor then
        return overlay.original.healthbar
    end
    return GetNameplateHealthbar(plate)
end

-- Hostility for colored names. neutralOnly: non-attackable enemy players (UnitCanAttack / yellow Blizzard name).
IsHostilePlayer = function(rawName, unit, plate, neutralOnly)
    if not unit and rawName then
        unit = FindPlayerUnitByName(rawName, plate)
    end
    if unit and UnitIsPlayerSafe(unit) then
        if unit == "player" then return false end
        if UnitIsFriendSafe(unit) then return false end
        if neutralOnly then
            return not UnitCanAttackSafe(unit)
        end
        return UnitCanAttackSafe(unit)
    end

    if plate and rawName and rawName ~= "" and IsNameplatePlayerForColor(plate, rawName) then
        local nr, ng, nb = GetBlizzardNameplateNameRgb(plate)
        if nr then
            -- Blizzard tints attackable enemy players red; faction alone uses yellow/blue.
            local nameHostile = (nr > .9 and ng < .3 and nb < .3)
            local nameNeutral = (nr > .9 and ng > .9 and nb < .3)
            if neutralOnly then
                if nameHostile then return false end
                if nameNeutral then return true end
            else
                return nameHostile
            end
        end
        if neutralOnly then
            local bar = GetNameplateFactionBar(plate)
            if bar and bar.GetStatusBarColor then
                local r, g, b = bar:GetStatusBarColor()
                if GetShaguBarUnitType(r, g, b) == "NEUTRAL_NPC" then return true end
            end
        end
    end

    return false
end

-- Hostility tint from the nameplate health bar (same idea as ShaguPlates GetUnitType).
GetNameplateFactionRgb = function(plate)
    local bar = GetNameplateFactionBar(plate)
    if not bar or not bar.GetStatusBarColor then return 1, 0, 0 end
    local r, g, b = bar:GetStatusBarColor()
    local fr, fg, fb = FactionRgbFromBarRgb(r, g, b)
    if fr then return fr, fg, fb end
    return 1, 0, 0
end

local function GetNameplateColorStateKey(plate)
    if not plate then return "" end
    local overlay = GetNameplateOverlay(plate)
    if overlay and overlay.original and overlay.original.healthbar then
        local r, g, b = overlay.original.healthbar:GetStatusBarColor()
        local cp = (overlay.cache and overlay.cache.player) or ""
        local nc = (overlay.cache and overlay.cache.namecolor) or 0
        local nr, ng, nb = 0, 0, 0
        if overlay.original.name and overlay.original.name.GetTextColor then
            nr, ng, nb = overlay.original.name:GetTextColor()
        end
        return (plate.wtRawName or "") .. ":" .. cp .. ":" .. nc .. ":"
            .. string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", r or 0, g or 0, b or 0, nr or 0, ng or 0, nb or 0)
    end
    local bar = GetNameplateFactionBar(plate)
    if bar and bar.GetStatusBarColor then
        local r, g, b = bar:GetStatusBarColor()
        return (plate.wtRawName or "") .. ":bar:" .. string.format("%.3f,%.3f,%.3f", r or 0, g or 0, b or 0)
    end
    return plate.wtRawName or ""
end

-- Class color for friendly players; hostile players and NPCs use faction tint.
GetNameplateNameTextRgb = function(rawName, plate)
    if not plate or not PlayerNameClassColorEnabled() then return nil end
    local overlay = GetNameplateOverlay(plate)

    if overlay then
        if not IsNameplatePlayerForColor(plate, rawName) then
            return GetNameplateFactionRgb(plate)
        end

        local unit = FindPlayerUnitByName(rawName, plate)
        if IsHostilePlayer(rawName, unit, plate) then
            return 1, 0, 0
        end
        if IsHostilePlayer(rawName, unit, plate, true) then
            return 1, 1, 0
        end

        local class = GetPlayerClassFromName(rawName)
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            return c.r, c.g, c.b
        end
        local br, bg, bb = GetBlizzardNameplateNameRgb(plate)
        if br then return br, bg, bb end
        return nil
    end

    local unit = FindPlayerUnitByName(rawName, plate)
    local isPlayer = (rawName and rawName ~= "" and (
        IsNameplatePlayerForColor(plate, rawName)
        or (unit and UnitIsPlayerSafe(unit))
        or GetPlayerClassFromName(rawName)
    ))
    if isPlayer then
        if IsHostilePlayer(rawName, unit, plate) then
            return 1, 0, 0
        end
        if IsHostilePlayer(rawName, unit, plate, true) then
            return 1, 1, 0
        end
        local class = GetPlayerClassFromName(rawName)
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            return c.r, c.g, c.b
        end
        local br, bg, bb = GetBlizzardNameplateNameRgb(plate)
        if br then return br, bg, bb end
    end
    local bar = GetNameplateFactionBar(plate)
    if bar and bar.GetStatusBarColor then
        local r, g, b = bar:GetStatusBarColor()
        return FactionRgbFromBarRgb(r, g, b)
    end
    return GetNameplateFactionRgb(plate)
end

-- ShaguPlates OnUpdate resets overlay.name to white when Blizzard name is white; re-apply tint.
local function RefreshNameplateNameColor(plate)
    if not plate then return end
    local fs = GetNameplateDisplayNameFont(plate)
    if not fs or not fs.SetTextColor then return end
    local rawName = plate.wtRawName
    if not rawName or rawName == "" then
        local overlay = GetNameplateOverlay(plate)
        if overlay and overlay.cache and overlay.cache.name then
            rawName = NormalizeTruncatedNameplateName(overlay.cache.name)
        end
    end
    local r, g, b
    if PlayerNameClassColorEnabled() and rawName and rawName ~= "" then
        r, g, b = GetNameplateNameTextRgb(rawName, plate)
        if not r then return end
    else
        r, g, b = GetNameplateBaseNameRgb()
    end
    local ta = 1
    if fs.GetTextColor then
        local _, _, _, a = fs:GetTextColor()
        if a then ta = a end
    end
    fs:SetTextColor(r, g, b, ta)
    plate.wtLastNameColorKey = GetNameplateColorStateKey(plate)
end

local function ColorizeNameplateDisplayText(rawName, text, plate)
    if not text or text == "" then return text end
    if not PlayerNameClassColorEnabled() then
        return StripColorCodes(text)
    end
    local plain = ApplyNameCapitalization(StripColorCodes(text))
    local r, g, b = GetNameplateNameTextRgb(rawName, plate)
    if r then
        return RgbHex(r, g, b) .. plain .. "|r"
    end
    return plain
end

local function FormatNameplateVanillaText(rawName, displayName, plate)
    displayName = displayName or rawName
    if not rawName or displayName == rawName then
        return ColorizeNameplateDisplayText(rawName, rawName, plate)
    end
    local colored = ColorizeNameplateDisplayText(rawName, displayName, plate)
    if WoWTranslateDB and WoWTranslateDB.nameplateShortNames then
        return colored .. TRANSLATED_NAME_MARK
    end
    return rawName .. " (" .. colored .. TRANSLATED_NAME_MARK .. ")"
end

local function GetNameplateLevelFont(parent)
    if not parent then return nil end
    local overlay = GetNameplateOverlay(parent)
    if overlay and overlay.level and overlay.level.Hide then
        return overlay.level
    end
    AssignNameplateRegions(parent)
    if parent.level and parent.level.Hide then
        return parent.level
    end
    for i, object in pairs({ parent:GetRegions() }) do
        if NAMEPLATE_OBJECTORDER[i] == "level" and object and object.Hide then
            return object
        end
    end
end

-- Health bar, its backdrop, and level text — hidden together out of combat.
local function CollectNameplateClutterFrames(parent)
    local frames = {}
    local function add(f)
        if f and f.Hide and f.Show then
            table.insert(frames, f)
        end
    end

    local overlay = GetNameplateOverlay(parent)
    if overlay then
        local bar = GetNameplateHealthbar(parent)
        add(bar)
        if bar and bar.backdrop then
            add(bar.backdrop)
        end
        add(GetNameplateLevelFont(parent))
    else
        -- Vanilla: border texture is the visible frame under the name; health is a child bar.
        AssignNameplateRegions(parent)
        add(parent.border)
        add(parent.glow)
        add(GetNameplateHealthbar(parent))
        add(GetNameplateLevelFont(parent))
        if parent.levelicon then
            add(parent.levelicon)
        end
    end

    return frames
end

-- Vanilla nameplates: player combat only (no target/mouseover/raid unit probes).
local function IsNameplateUnitInCombat(plate)
    if not UnitAffectingCombat then return true end
    local ok, c = pcall(UnitAffectingCombat, "player")
    return ok and c
end

-- ShaguPlates parents overlay.name to overlay.health; hiding health hides the name too.
local function EnsureOverlayNameDetached(parent)
    local overlay = GetNameplateOverlay(parent)
    if not overlay or not overlay.name then return end

    local hideOOC = WoWTranslateDB and WoWTranslateDB.nameplateHideHealthOOC
    if not hideOOC or IsNameplateUnitInCombat(parent) then
        parent.wtNameDetachedForOOC = nil
        return
    end

    if overlay.name:GetParent() ~= overlay then
        overlay.name:SetParent(overlay)
    end
    overlay.name:ClearAllPoints()
    overlay.name:SetPoint("TOP", overlay, "TOP", 0, 0)
    overlay.name:Show()
    parent.wtNameDetachedForOOC = true
end

local function SetNameplateClutterVisible(plate, visible)
    if not plate.wtClutterFrames then
        plate.wtClutterFrames = CollectNameplateClutterFrames(plate)
    end
    local frames = plate.wtClutterFrames
    for i = 1, table.getn(frames) do
        local f = frames[i]
        if visible then
            f:Show()
        else
            f:Hide()
        end
    end
    if visible then
        plate.wtOOCClutterHidden = nil
    else
        plate.wtOOCClutterHidden = true
    end
end

local wtNameplateGuildByPlayer = {}

local function NameplateGuildOOCEnabled()
    return WoWTranslateDB and WoWTranslateDB.enabled and WoWTranslateDB.nameplateGuildOOC
end

local function IsPlayerNameplate(plate, rawName)
    if not plate or not rawName or rawName == "" then return false end
    if IsNameplatePlayerForColor(plate, rawName) then return true end
    local overlay = GetNameplateOverlay(plate)
    if overlay and overlay.cache and overlay.cache.player == "PLAYER" then return true end
    local bar = GetNameplateFactionBar(plate)
    if bar and bar.GetStatusBarColor then
        local r, g, b = bar:GetStatusBarColor()
        if GetShaguBarUnitType(r, g, b) == "FRIENDLY_PLAYER" then return true end
    end
    if GetPlayerClassFromName(rawName) then return true end
    return false
end

local function LookupRawGuildForNameplate(rawName, plate)
    if not rawName or rawName == "" then return nil end
    if wtNameplateGuildByPlayer[rawName] then return wtNameplateGuildByPlayer[rawName] end

    if ShaguPlates_playerDB and ShaguPlates_playerDB[rawName] then
        local g = ShaguPlates_playerDB[rawName].guild
        if g and g ~= "" then
            wtNameplateGuildByPlayer[rawName] = g
            return g
        end
    end

    -- active=false: never queue Shagu libunitscan TargetByName (causes "Unknown unit." spam).
    if GetUnitData then
        local _, _, _, player, guild = GetUnitData(rawName, false)
        if player and guild and guild ~= "" then
            wtNameplateGuildByPlayer[rawName] = guild
            return guild
        end
    end
    return nil
end

local function FormatNameplateGuildLine(rawGuild, displayGuild)
    displayGuild = displayGuild or rawGuild
    if not displayGuild or displayGuild == "" then return nil end
    local plain = StripColorCodes(displayGuild) or displayGuild
    local line = "<" .. plain .. ">"
    if rawGuild and displayGuild ~= rawGuild then
        line = line .. "*"
    end
    return line
end

-- Shrink long guild tags so they stay within the nameplate width.
local GUILD_NAME_FULL_LEN = 50
local GUILD_NAME_MAX_LEN = 100
local GUILD_NAME_MIN_FONT = 5
local GUILD_NAME_MAX_WIDTH = 430

-- Inner guild tag text from formatted line "<Display*>" (post-translation).
local function GuildLinePlainLength(line)
    if not line then return 0 end
    local plain = StripColorCodes(line) or line
    plain = string.gsub(plain, "^%s*<%s*", "")
    plain = string.gsub(plain, "%s*>%s*$", "")
    plain = string.gsub(plain, "%*$", "")
    return string.len(plain)
end

local GUILD_BASE_DEFAULT = 10
local GUILD_BASE_MAX = 12

local function CaptureNameplateGuildFont(plate, guildFs, nameFs)
    if not plate then
        if guildFs and guildFs.GetFont then
            return guildFs:GetFont()
        end
        return nil, GUILD_BASE_DEFAULT, nil
    end
    if not plate.wtGuildBaseCaptured then
        local font, size, flags
        local overlay = plate.nameplate
        local src = overlay and overlay.original and overlay.original.name
        if src and src.GetFont then
            font, size, flags = src:GetFont()
            if size and size > 8 then
                size = size - 2
            end
        elseif overlay then
            font, size, flags = "Fonts\\FRIZQT__.TTF", GUILD_BASE_DEFAULT, ""
        elseif guildFs and guildFs.GetFont then
            font, size, flags = guildFs:GetFont()
        else
            font, size, flags = "Fonts\\FRIZQT__.TTF", GUILD_BASE_DEFAULT, ""
        end
        plate.wtGuildFontPath = font
        plate.wtGuildFontFlags = flags
        plate.wtGuildBaseFontSize = ClampOversizeBaseFont(size, GUILD_BASE_DEFAULT, GUILD_BASE_MAX)
        plate.wtGuildBaseCaptured = true
    end
    return plate.wtGuildFontPath, plate.wtGuildBaseFontSize, plate.wtGuildFontFlags
end

local function ApplyNameplateGuildFontSize(plate, guildFs, line, nameFs)
    if not guildFs or not guildFs.SetFont or not guildFs.GetFont then return end
    local font, baseSize, flags = CaptureNameplateGuildFont(plate, guildFs, nameFs)
    if not font then return end

    guildFs:SetText(line)
    local autoscaleGuild = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleGuild
    local scaleAmt = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleGuildScale
    local shrinkRatio = WoWTranslateDB and WoWTranslateDB.nameplateAutoscaleGuildRatio
    local shadowSrc = GetNameplateShadowSourceFont(plate, nameFs)
    ApplyAutoscaleFont(guildFs, font, flags, {
        baseSize = baseSize,
        defaultBase = GUILD_BASE_DEFAULT,
        minFont = GUILD_NAME_MIN_FONT,
        plainLen = GuildLinePlainLength(line),
        fullLen = GUILD_NAME_FULL_LEN,
        maxLen = GUILD_NAME_MAX_LEN,
        maxWidth = GUILD_NAME_MAX_WIDTH,
        shrinkStrength = AutoscaleShrinkStrength(shrinkRatio),
        autoscaleOn = autoscaleGuild,
        scaleAmount = scaleAmt,
        shadowSrc = shadowSrc,
    })
    ApplyNameplateFontShadow(guildFs, shadowSrc)

    if guildFs.GetStringWidth and guildFs.SetWidth then
        local w = guildFs:GetStringWidth()
        if w and w > 0 then
            guildFs:SetWidth(w + 6)
        end
    end
end

-- Own FontString only — ShaguPlates hides overlay.guild every refresh when its
-- "show guild" option is off, which made our line flash then vanish.
local function EnsureNameplateGuildFont(plate, nameFs)
    if plate.wtGuildLine and plate.wtGuildLine.SetText then
        return plate.wtGuildLine
    end
    local overlay = GetNameplateOverlay(plate)
    local parent = plate
    local anchor = nameFs
    if overlay then
        parent = overlay
        anchor = (overlay.name and overlay.name.GetText and overlay.name) or nameFs
    end
    if not anchor then return nil end
    local fs = parent:CreateFontString("WoWTranslateNameplateGuild", "OVERLAY")
    if anchor.GetFont and fs.SetFont then
        local font, size, flags = anchor:GetFont()
        local small = (size and size > 8) and (size - 2) or 10
        if font then
            fs:SetFont(font, small, flags)
        end
    end
    ApplyNameplateFontShadow(fs, anchor)
    ApplyNameplateGuildTextColor(fs)
    fs:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    plate.wtGuildLine = fs
    return fs
end

local function HideNameplateGuildLine(plate)
    if not plate then return end
    if plate.wtGuildLine and plate.wtGuildLine.Hide then
        plate.wtGuildLine:Hide()
    end
    plate.wtLastGuildDisplay = nil
    plate.wtGuildResolvePending = nil
    plate.wtPendingRawGuild = nil
    plate.wtGuildFontPath = nil
    plate.wtGuildBaseFontSize = nil
    plate.wtGuildFontFlags = nil
    plate.wtGuildBaseCaptured = nil
end

local function ApplyNameplateGuildLine(plate, guildFs, line, nameFs)
    if not guildFs or not line or line == "" then
        HideNameplateGuildLine(plate)
        return
    end
    ApplyNameplateGuildFontSize(plate, guildFs, line, nameFs)
    ApplyNameplateGuildTextColor(guildFs)
    guildFs:Show()
    plate.wtLastGuildDisplay = line
end

local function NameplateGuildFontNeedsShow(plate, guildFs, line)
    if not guildFs or not line or line == "" then return false end
    if plate.wtLastGuildDisplay ~= line then return true end
    if not guildFs.IsShown then return true end
    local shown = guildFs:IsShown()
    return not (shown == 1 or shown == true)
end

local function GetNameplateRawNameQuick(plate)
    if plate.wtRawName and plate.wtRawName ~= "" then return plate.wtRawName end
    local overlay = GetNameplateOverlay(plate)
    if overlay then
        if overlay.cache and overlay.cache.name and overlay.cache.name ~= "" then
            return NormalizeTruncatedNameplateName(overlay.cache.name)
        end
        if overlay.original and overlay.original.name and overlay.original.name.GetText then
            local t = overlay.original.name:GetText()
            if t and t ~= "" then
                return NormalizeTruncatedNameplateName(StripOverheadDisplaySuffix(t))
            end
        end
    end
    return nil
end

local function UpdateNameplateGuildOOC(plate)
    if not plate then return end
    if not NameplateGuildOOCEnabled() then
        HideNameplateGuildLine(plate)
        return
    end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then
        HideNameplateGuildLine(plate)
        return
    end
    if IsNameplateUnitInCombat(plate) then
        HideNameplateGuildLine(plate)
        return
    end

    -- ShaguPlates parents overlay.name to overlay.health while the bar layout is active.
    local suppressGuildForHealthLayout = false
    if not plate.wtOOCClutterHidden then
        local ov = GetNameplateOverlay(plate)
        if ov and ov.name and ov.name.GetParent and ov.health then
            if ov.name:GetParent() == ov.health then
                suppressGuildForHealthLayout = true
            end
        end
    end
    if suppressGuildForHealthLayout then
        HideNameplateGuildLine(plate)
        return
    end

    local rawName = GetNameplateRawNameQuick(plate)
    if not rawName or rawName == "" or not IsPlayerNameplate(plate, rawName) then
        HideNameplateGuildLine(plate)
        return
    end
    plate.wtRawName = rawName

    local nameFs = GetNameplateDisplayNameFont(plate)
    if not nameFs then return end

    local overlay = GetNameplateOverlay(plate)
    if overlay then
        EnsureOverlayNameDetached(plate)
    end

    local guildFs = EnsureNameplateGuildFont(plate, nameFs)
    if not guildFs then return end
    local guildAnchor = nameFs
    if overlay and overlay.name then guildAnchor = overlay.name end
    guildFs:ClearAllPoints()
    guildFs:SetPoint("TOP", guildAnchor, "BOTTOM", 0, -2)

    local function showLine(rawGuild, displayGuild)
        if (plate.wtRawName or "") ~= rawName then return end
        if not plate.wtOOCClutterHidden then
            local ov = GetNameplateOverlay(plate)
            if ov and ov.name and ov.name.GetParent and ov.health
                and ov.name:GetParent() == ov.health then
                HideNameplateGuildLine(plate)
                return
            end
        end
        local line = FormatNameplateGuildLine(rawGuild, displayGuild)
        if not line then
            HideNameplateGuildLine(plate)
            return
        end
        if not NameplateGuildFontNeedsShow(plate, guildFs, line) then return end
        ApplyNameplateGuildLine(plate, guildFs, line, nameFs)
    end

    local rawGuild = LookupRawGuildForNameplate(rawName, plate)
    if not rawGuild or rawGuild == "" then
        HideNameplateGuildLine(plate)
        return
    end
    plate.wtPendingRawGuild = rawGuild

    if WoWTranslateDB.translateGuildNames and WoWTranslate_ResolveGuildDisplayName then
        local cacheKey = "\1wt_guild:" .. rawGuild
        local cached, found = WoWTranslate_CacheGet(cacheKey)
        if found then
            showLine(rawGuild, cached)
            return
        end
        if plate.wtGuildResolvePending == rawName then
            local allowGuild = plate.wtOOCClutterHidden
            if not allowGuild then
                local ov = GetNameplateOverlay(plate)
                allowGuild = not (ov and ov.name and ov.name.GetParent and ov.health
                    and ov.name:GetParent() == ov.health)
            end
            if allowGuild and plate.wtLastGuildDisplay
                and NameplateGuildFontNeedsShow(plate, guildFs, plate.wtLastGuildDisplay) then
                ApplyNameplateGuildLine(plate, guildFs, plate.wtLastGuildDisplay, nameFs)
            end
            return
        end
        plate.wtGuildResolvePending = rawName
        WoWTranslate_ResolveGuildDisplayName(rawGuild, function(displayGuild)
            plate.wtGuildResolvePending = nil
            showLine(rawGuild, displayGuild)
        end)
        return
    end

    showLine(rawGuild, rawGuild)
end

local function UpdateNameplateHealthbarVisibility(plate)
    if not plate then return end

    if GetNameplateOverlay(plate) then
        EnsureOverlayNameDetached(plate)
    end

    if not plate.wtClutterFrames or table.getn(plate.wtClutterFrames) == 0 then
        plate.wtClutterFrames = CollectNameplateClutterFrames(plate)
    end
    if table.getn(plate.wtClutterFrames) > 0 then
        if not WoWTranslateDB or not WoWTranslateDB.nameplateHideHealthOOC then
            if plate.wtOOCClutterHidden then
                SetNameplateClutterVisible(plate, true)
            end
        elseif IsNameplateUnitInCombat(plate) then
            if plate.wtOOCClutterHidden then
                SetNameplateClutterVisible(plate, true)
            end
        else
            -- Re-apply each tick; nameplate mods show health/level again after we hide.
            SetNameplateClutterVisible(plate, false)
        end
    end
    UpdateNameplateGuildOOC(plate)
end

function WoWTranslate_RefreshAllNameplateHealthbars()
    for plate in pairs(wtNameplateRegistry) do
        if NameplateFrameVisible(plate) then
            UpdateNameplateHealthbarVisibility(plate)
        end
    end
end

-- Plain overlay label (no |c codes — mod uses SetTextColor for class tint).
local function FormatNameplateOverlayText(rawName, displayName)
    displayName = displayName or rawName
    local isTranslated = rawName and displayName ~= rawName
    local plain = ApplyNameCapitalization(StripColorCodes(isTranslated and displayName or rawName))
    if not isTranslated then
        return plain
    end
    if WoWTranslateDB and WoWTranslateDB.nameplateShortNames then
        return plain .. "*"
    end
    return rawName .. " (" .. plain .. "*)"
end

-- Capture Blizzard name from the FontString before we overwrite it (vanilla has no original.name).
local function CaptureVanillaNameplateSource(plate)
    if not plate then return nil end
    if plate.wtSourceName and plate.wtSourceName ~= "" then
        return plate.wtSourceName
    end
    AssignNameplateRegions(plate)
    local fs = plate.name
    if not fs or not fs.GetText then
        fs = GetNameplateDisplayNameFont(plate)
    end
    if fs and fs.GetText then
        local t = fs:GetText()
        if t and t ~= "" then
            if plate.wtLastDisplay and t == plate.wtLastDisplay then
                return plate.wtSourceName
            end
            local plain = NormalizeTruncatedNameplateName(StripOverheadDisplaySuffix(t))
            if plain and plain ~= "" then
                plate.wtSourceName = plain
                return plain
            end
        end
    end
    return nil
end

-- Read the real name from text only (Shagu: cache.name / original.name — never unit APIs).
local function ResolveNameplateRawName(plate)
    if not plate then return nil end
    local overlay = GetNameplateOverlay(plate)
    if overlay then
        if overlay.cache and overlay.cache.name and overlay.cache.name ~= "" then
            return NormalizeTruncatedNameplateName(overlay.cache.name)
        end
        if overlay.original and overlay.original.name and overlay.original.name.GetText then
            local t = overlay.original.name:GetText()
            if t and t ~= "" then
                return NormalizeTruncatedNameplateName(StripOverheadDisplaySuffix(t))
            end
        end
    end
    return CaptureVanillaNameplateSource(plate) or plate.wtRawName
end

local function UpdateNameplateFromPlate(plate, skipClutterUpdate)
    if not plate then return end
    if not skipClutterUpdate then
        UpdateNameplateHealthbarVisibility(plate)
    end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
    if not WoWTranslateDB.translateNameplates then return end

    local overlay = GetNameplateOverlay(plate)
    local fs = GetNameplateDisplayNameFont(plate)
    if not fs or not fs.GetText then return end

    local current = fs:GetText()
    if not current or current == "" then return end

    local rawName = ResolveNameplateRawName(plate)
    if not rawName or rawName == "" then return end
    plate.wtRawName = rawName

    local colorKey = GetNameplateColorStateKey(plate)
    if plate.wtLastDisplay and current == plate.wtLastDisplay then
        if plate.wtLastNameColorKey == colorKey then return end
        ApplyNameplateNameText(fs, plate.wtLastDisplay, plate, rawName, nil)
        plate.wtLastNameColorKey = colorKey
        return
    end

    if not overlay then
        plate.wtSourceName = rawName
        SyncVanillaNameplateSourceText(plate, rawName)
        fs = GetNameplateDisplayNameFont(plate)
        if not fs or not fs.GetText then return end
    end

    -- Shagu abbreviated overlay.name back to a short label — re-apply translation.
    if overlay and plate.wtLastDisplay then
        local plain = NormalizeTruncatedNameplateName(current)
        if plain == rawName or OverheadDisplayMatchesRawName(current, rawName) then
            plate.wtLastDisplay = nil
        end
    end

    local function applyDisplay(displayName)
        if plate.wtRawName ~= rawName then return end
        local formatted
        if overlay then
            formatted = FormatNameplateOverlayText(rawName, displayName)
        else
            formatted = FormatNameplateVanillaText(rawName, displayName, plate)
        end
        if plate.wtLastDisplay ~= formatted then
            ApplyNameplateNameText(fs, formatted, plate, rawName, nil)
            plate.wtLastDisplay = formatted
            plate.wtLastNameColorKey = GetNameplateColorStateKey(plate)
            if overlay and overlay.name and overlay.name.Show then
                overlay.name:Show()
            end
        end
    end

    if not ShouldTranslatePlayerName(rawName) then
        applyDisplay(rawName)
        return
    end

    local cached, found = WoWTranslate_CacheGet(NameCacheKey(rawName))
    if found then
        applyDisplay(cached)
        return
    end

    if plate.wtResolvePending then return end
    plate.wtResolvePending = true
    ResolvePlayerDisplayName(rawName, function(displayName)
        plate.wtResolvePending = nil
        applyDisplay(displayName)
    end)
end

-- Reapply autoscale / player / target font boosts to whatever text is on screen now.
local function ReapplyNameplateDisplayFont(plate)
    if not plate then return end
    local fs = GetNameplateDisplayNameFont(plate)
    if not fs or not fs.GetText or not fs.GetFont then return end
    local text = fs:GetText()
    if not text or text == "" then return end
    local rawName = plate.wtRawName
    if not rawName or rawName == "" then
        rawName = ResolveNameplateRawName(plate)
    end
    if not rawName or rawName == "" then return end
    plate.wtRawName = rawName
    ApplyNameplateNameFontSize(plate, fs, text, rawName)
end

-- Must be declared before WoWTranslate_RefreshNameplateColors (Lua 5.0 forward refs).
local function RunNameplateNameUpdate(plate, skipClutter)
    if not plate then return end
    UpdateNameplateHealthbarVisibility(plate)
    if NameplateNameUpdateDue(plate) then
        if GetNameplateOverlay(plate) then
            UpdateNameplateFromPlate(plate, true)
        else
            UpdateNameplateFromPlate(plate, skipClutter)
        end
    end
    if NameplateGuildOOCEnabled() then
        UpdateNameplateGuildOOC(plate)
    end
    RefreshNameplateNameColor(plate)
    ReapplyNameplateDisplayFont(plate)
end

function WoWTranslate_RefreshNameplateColors()
    for plate in pairs(wtNameplateRegistry) do
        if NameplateFrameVisible(plate) then
            plate.wtNameBaseCaptured = nil
            plate.wtNameBaseFontSize = nil
            plate.wtNameFontPath = nil
            plate.wtNameFontFlags = nil
            plate.wtGuildBaseCaptured = nil
            plate.wtGuildFontPath = nil
            plate.wtGuildBaseFontSize = nil
            plate.wtGuildFontFlags = nil
            plate.wtLastDisplay = nil
            plate.wtLastNameColorKey = nil
            plate.wtNextNameUpdate = nil
            RunNameplateNameUpdate(plate, true)
        end
    end
end

local wtTargetRefreshFrame = nil

function WoWTranslate_OnTargetChanged()
    local hadTarget = wtHadTargetUnit
    wtCachedTargetUnit = nil
    wtCachedTargetCheckTime = 0
    local hasTarget = (GetSafeTargetUnitToken() ~= nil)
    wtHadTargetUnit = hasTarget
    if WoWTranslate_RefreshNameplateColors then
        WoWTranslate_RefreshNameplateColors()
    end
    if not wtTargetRefreshFrame then
        wtTargetRefreshFrame = CreateFrame("Frame")
    end
    -- Shagu updates istarget on the next nameplate OnUpdate; extra ticks when target cleared.
    local ticks = 2
    if hadTarget and not hasTarget then
        ticks = 4
    end
    wtTargetRefreshFrame.wtRefreshTicks = ticks
    wtTargetRefreshFrame:SetScript("OnUpdate", function()
        if not this.wtRefreshTicks or this.wtRefreshTicks <= 0 then
            this:SetScript("OnUpdate", nil)
            return
        end
        this.wtRefreshTicks = this.wtRefreshTicks - 1
        wtCachedTargetUnit = nil
        wtCachedTargetCheckTime = 0
        if WoWTranslate_RefreshNameplateColors then
            WoWTranslate_RefreshNameplateColors()
        end
    end)
end

local function ResetNameplatePlateState(plate)
    if not plate then return end
    plate.wtSourceName = nil
    plate.wtRawName = nil
    plate.wtLastDisplay = nil
    plate.wtLastNameColorKey = nil
    plate.wtResolvePending = nil
    plate.wtNextNameUpdate = nil
    plate.wtOOCClutterHidden = nil
    plate.wtClutterFrames = nil
    plate.wtNameDetachedForOOC = nil
    plate.wtHealthbar = nil
    plate.wtNameBaseCaptured = nil
    plate.wtNameBaseFontSize = nil
    plate.wtNameFontPath = nil
    plate.wtNameFontFlags = nil
    HideNameplateGuildLine(plate)
    if plate.name and plate.name.SetAlpha then
        plate.name:SetAlpha(1)
    end
end

local function RegisterStandaloneNameplate(plate)
    if not plate then return end
    wtNameplateRegistry[plate] = true
    AssignNameplateRegions(plate)
    if plate.wtWoWTranslateShowHooked then return end
    local oldShow = plate:GetScript("OnShow")
    plate:SetScript("OnShow", function()
        if oldShow then oldShow() end
        ResetNameplatePlateState(plate)
        AssignNameplateRegions(plate)
        -- Grab Blizzard name while the frame is fresh (before we SetText).
        if plate.name and plate.name.GetText then
            local t = plate.name:GetText()
            if t and t ~= "" then
                plate.wtSourceName = NormalizeTruncatedNameplateName(StripOverheadDisplaySuffix(t))
                SyncVanillaNameplateSourceText(plate, plate.wtSourceName)
                EnsureVanillaTranslateNameFont(plate)
            end
        end
    end)
    plate.wtWoWTranslateShowHooked = true
end

local function ScanWorldFrameNameplates()
    local parentcount = WorldFrame:GetNumChildren()
    if wtNameplateScanInitialized < parentcount then
        local childs = { WorldFrame:GetChildren() }
        for i = wtNameplateScanInitialized + 1, parentcount do
            local plate = childs[i]
            if plate and IsNamePlateFrame(plate) then
                RegisterStandaloneNameplate(plate)
            end
        end
        wtNameplateScanInitialized = parentcount
    end

    PruneNameplateRegistry()

    for plate in pairs(wtNameplateRegistry) do
        if NameplateFrameVisible(plate) and not GetNameplateOverlay(plate) then
            RunNameplateNameUpdate(plate, false)
        end
    end
end

function WoWTranslate_OnNameplateUpdate(plate)
    plate = plate or this
    if not plate then return end
    -- Vanilla Blizzard plates: WoWTranslateNameplateScanner only (lib OnUpdate stays for ShaguPlates).
    if not GetNameplateOverlay(plate) and not (ShaguPlates and ShaguPlates.nameplates) then
        return
    end
    if GetNameplateOverlay(plate) then
        RunNameplateNameUpdate(plate, true)
    else
        RunNameplateNameUpdate(plate, false)
    end
end

function WoWTranslate_OnNameplateShow(plate)
    plate = plate or this
    if not plate then return end
    ResetNameplatePlateState(plate)
end

local function HookShaguNameplates()
    local lib = ShaguTweaks and ShaguTweaks.libnameplate
    if not lib then return false end

    -- Wrapper calls global so /reload picks up the new function body.
    if not lib.wtWoWTranslateHooked then
        -- Vanilla Blizzard plates: scanner only (avoids per-frame lib OnUpdate churn).
        if ShaguPlates and ShaguPlates.nameplates then
            table.insert(lib.OnUpdate, function(plate)
                WoWTranslate_OnNameplateUpdate(plate)
            end)
        end
        table.insert(lib.OnShow, function(plate)
            WoWTranslate_OnNameplateShow(plate)
        end)
        lib.wtWoWTranslateHooked = true
    end
    wtNameplateShaguHooked = true
    return true
end

-- Run after ShaguPlates OnDataChanged sets overlay.name (abbreviated) each refresh.
local function HookShaguPlatesNameplates()
    if not ShaguPlates or not ShaguPlates.nameplates then return false end

    local np = ShaguPlates.nameplates
    if np.wtWoWTranslateWrapped then
        wtShaguPlatesHooked = true
        return true
    end

    local base = np.wtWoWTranslateBase or np.OnDataChanged
    if not base then return false end
    if not np.wtWoWTranslateBase then
        np.wtWoWTranslateBase = base
    end

    np.OnDataChanged = function(self, overlay)
        np.wtWoWTranslateBase(self, overlay)
        local parent = overlay and overlay.parent
        if not parent then return end
        if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
        if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
        -- Translate after Shagu sets text; reparent name before hiding health (OOC).
        parent.wtNextNameUpdate = nil
        if WoWTranslateDB.translateNameplates then
            UpdateNameplateFromPlate(parent, true)
        end
        UpdateNameplateHealthbarVisibility(parent)
        RefreshNameplateNameColor(parent)
        ReapplyNameplateDisplayFont(parent)
    end
    np.wtWoWTranslateWrapped = true
    wtShaguPlatesHooked = true
    return true
end

local wtNameplateScanElapsed = 0
local NAMEPLATE_SCAN_INTERVAL = 0.25

local function StartStandaloneNameplateScanner()
    if wtNameplateScanFrame then return end
    wtNameplateScanFrame = CreateFrame("Frame", "WoWTranslateNameplateScanner", UIParent)
    wtNameplateScanFrame:SetScript("OnUpdate", function()
        wtNameplateScanElapsed = wtNameplateScanElapsed + arg1
        if wtNameplateScanElapsed < NAMEPLATE_SCAN_INTERVAL then return end
        wtNameplateScanElapsed = 0
        ScanWorldFrameNameplates()
    end)
end

    local function hookNameplates()
        HookShaguNameplates()
        HookShaguPlatesNameplates()
        StartStandaloneNameplateScanner()
    end

    local function resetNameplateScanner()
        wtNameplateScanInitialized = 0
        wtNameplateRegistry = {}
    end

    HookNameplates = hookNameplates
    ResetNameplateScanner = resetNameplateScanner
end

local function HookTooltips()
    HookGameTooltip()
    HookItemRefTooltip()
    HookNameplates()
end

-- ============================================================================
-- WIM INTEGRATION
-- ============================================================================

local WoWTranslate_UpdateWIMHeader
local InstallWIMHook

local function WoWTranslate_IsWIMActive()
    return type(WIM_Data) == "table" and WIM_Data.enableWIM ~= false
        and type(WIM_PostMessage) == "function"
end

local function WoWTranslate_IsWIMWhisperSuppressed()
    return WoWTranslate_IsWIMActive() and WIM_Data.supressWisps ~= false
end

local function CleanupWIMState()
    local now = GetTime()
    for user, pending in pairs(wimOutgoingPending) do
        if now - pending.time > 30 then
            wimOutgoingPending[user] = nil
        end
    end
    for msg, t in pairs(wimPostedMessages) do
        if now - t > 60 then
            wimPostedMessages[msg] = nil
        end
    end
end

local function BuildWIMOriginalReminderLine(originalText)
    return "|cFF00FFFF[WT-Original]|r " .. originalText
end

local function BuildWIMEnglishReminderLine(englishText)
    return "|cFF00FFFF[WT-English]|r " .. englishText
end

local function StripOutgoingPrefix(msg)
    if not msg or msg == "" then return msg end
    if WoWTranslateDB and WoWTranslateDB.outgoingPrefixEnabled == false then
        return msg
    end
    local userPrefix = (WoWTranslateDB and WoWTranslateDB.outgoingPrefix) or DEFAULT_PREFIX
    local prefixes = {}
    if userPrefix == DEFAULT_PREFIX then
        for _, p in pairs(TRANSLATED_PREFIXES) do
            table.insert(prefixes, p)
        end
    else
        table.insert(prefixes, userPrefix)
    end
    for i = 1, table.getn(prefixes) do
        local lead = prefixes[i] .. " "
        if string.sub(msg, 1, string.len(lead)) == lead then
            return string.sub(msg, string.len(lead) + 1)
        end
    end
    return msg
end

local function WIMOutgoingRawMsgMatches(pending, raw_msg)
    if not pending or not raw_msg then return false end
    if raw_msg == pending.translated or raw_msg == pending.original then
        return true
    end
    local normRaw = StripOutgoingPrefix(raw_msg)
    local normSent = StripOutgoingPrefix(pending.translated)
    if normRaw == normSent then
        return true
    end
    if pending.translated and string.len(pending.translated) >= 252 then
        local head = string.sub(pending.translated, 1, 200)
        if string.find(raw_msg, head, 1, true) then
            return true
        end
    end
    return false
end

local function PostWIMReminderLine(user, line)
    if not line or line == "" or not user then return end
    if not WoWTranslate_IsWIMActive() then return end
    if InstallWIMHook then InstallWIMHook() end

    if wimOrigPost then
        wimOrigPost(user, line, 3, UnitName("player"), line)
        return
    end

    if type(WIM_PostMessage) == "function" then
        WIM_PostMessage(user, line, 3, UnitName("player"), line)
        return
    end

    -- Last resort: write directly to the whisper scroll frame.
    if WIM_Windows and WIM_Windows[user] then
        local chatBox = getglobal(WIM_Windows[user].frame .. "ScrollingMessageFrame")
        if chatBox and chatBox.AddMessage then
            local r, g, b = 1, 1, 1
            if WIM_Data and WIM_Data.displayColors and WIM_Data.displayColors.sysMsg then
                r = WIM_Data.displayColors.sysMsg.r
                g = WIM_Data.displayColors.sysMsg.g
                b = WIM_Data.displayColors.sysMsg.b
            end
            chatBox:AddMessage(line, r, g, b)
        end
    end
end

local function RequestWhisperBackTranslation(sentMsg, typedOriginal, onEnglish)
    if not onEnglish then return end
    local body = StripOutgoingPrefix(sentMsg or "")
    if body == "" then
        onEnglish(typedOriginal)
        return
    end
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        onEnglish(typedOriginal)
        return
    end
    local segments = SplitIntoSegments(body)
    local plain = BuildTranslatableText(segments)
    if not plain or plain == "" or not HasTranslatableContent(segments) then
        onEnglish(typedOriginal)
        return
    end
    local ok = WoWTranslate_API.TranslateBack(plain, function(translation, err)
        if translation and translation ~= "" then
            onEnglish(translation)
        else
            onEnglish(typedOriginal)
        end
    end)
    if not ok then
        onEnglish(typedOriginal)
    end
end

local function DisplayWIMOutgoingWhisper(user, typedOriginal, sentMsg)
    if not WoWTranslate_IsWIMActive() or not user or not sentMsg then return end
    if InstallWIMHook then InstallWIMHook() end

    local pending = wimOutgoingPending[user]
    if pending and pending.displayed then return end
    if pending then
        pending.displayed = true
    end

    local playerName = UnitName("player")
    local alias = playerName
    if type(WIM_GetAlias) == "function" then
        alias = WIM_GetAlias(playerName, true)
    end
    local sentLine = "[|Hplayer:" .. playerName .. "|h" .. alias .. "|h]: " .. sentMsg
    if wimOrigPost then
        wimOrigPost(user, sentLine, 2, playerName, sentMsg)
    elseif type(WIM_PostMessage) == "function" then
        WIM_PostMessage(user, sentLine, 2, playerName, sentMsg)
    end
    WoWTranslate_UpdateWIMHeader(user)

    RequestWhisperBackTranslation(sentMsg, typedOriginal, function(englishLine)
        if englishLine and englishLine ~= "" then
            PostWIMReminderLine(user, BuildWIMEnglishReminderLine(englishLine))
        end
    end)
end

local wtClassLocalToToken = nil

local function GetClassTokenFromLocalized(classLocal)
    if not classLocal or classLocal == "" then return nil end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[classLocal] then
        return classLocal
    end
    if type(L) == "table" and L["class"] and L["class"][classLocal] then
        return L["class"][classLocal]
    end
    if not wtClassLocalToToken then
        wtClassLocalToToken = {}
        if RAID_CLASS_COLORS then
            for token, _ in pairs(RAID_CLASS_COLORS) do
                if LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] then
                    wtClassLocalToToken[LOCALIZED_CLASS_NAMES_MALE[token]] = token
                end
                if LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[token] then
                    wtClassLocalToToken[LOCALIZED_CLASS_NAMES_FEMALE[token]] = token
                end
            end
        end
    end
    return wtClassLocalToToken[classLocal]
end

local function GetSocialPlayerClassColorHex(rawName, classLocal)
    if classLocal then
        local token = GetClassTokenFromLocalized(classLocal)
        if token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token] then
            local c = RAID_CLASS_COLORS[token]
            return string.format("%02X%02X%02X",
                math.floor(c.r * 255 + 0.5),
                math.floor(c.g * 255 + 0.5),
                math.floor(c.b * 255 + 0.5))
        end
    end
    if rawName and WIM_PlayerCache and WIM_PlayerCache[rawName] and WIM_PlayerCache[rawName].class then
        local classKey = WIM_PlayerCache[rawName].class
        if WIM_ClassColors and WIM_ClassColors[classKey] then
            return WIM_ClassColors[classKey]
        end
    end
    local unit = FindPlayerUnitByName(rawName)
    local class = ResolvePlayerClass(rawName, unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return string.format("%02X%02X%02X",
            math.floor(c.r * 255 + 0.5),
            math.floor(c.g * 255 + 0.5),
            math.floor(c.b * 255 + 0.5))
    end
    return nil
end

local function ColorSocialPlayerText(text, rawName, classLocal)
    if not text or text == "" then return text end
    local hex = GetSocialPlayerClassColorHex(rawName, classLocal)
    if not hex then return text end
    if string.sub(hex, 1, 2) == "|c" then
        return hex .. text .. "|r"
    end
    return "|cff" .. hex .. text .. "|r"
end

local function ColorWIMHeaderText(text, theUser)
    local classLocal = nil
    if WIM_PlayerCache and WIM_PlayerCache[theUser] then
        classLocal = WIM_PlayerCache[theUser].class
    end
    return ColorSocialPlayerText(text, theUser, classLocal)
end

local function GetWIMHeaderDisplayName(theUser)
    if type(WIM_UserWithClassColor) == "function"
        and WIM_Data and WIM_Data.characterInfo and WIM_Data.characterInfo.classColor
        and WIM_PlayerCache and WIM_PlayerCache[theUser]
        and WIM_PlayerCache[theUser].class and WIM_PlayerCache[theUser].class ~= "" then
        return WIM_UserWithClassColor(theUser)
    end
    if type(WIM_GetAlias) == "function" then
        return ColorWIMHeaderText(WIM_GetAlias(theUser), theUser)
    end
    return ColorWIMHeaderText(theUser, theUser)
end

local function GetOrCreateWIMTranslationFont(theUser)
    if not WIM_Windows or not WIM_Windows[theUser] then return nil end
    local frameName = WIM_Windows[theUser].frame
    local transName = frameName .. "WTTranslation"
    local fs = getglobal(transName)
    if fs then return fs end
    local parent = getglobal(frameName)
    local fromFs = getglobal(frameName .. "From")
    if not parent or not fromFs then return nil end
    fs = parent:CreateFontString(transName, "OVERLAY", "GameFontNormalSmall")
    if not fs then return nil end
    fs:SetPoint("LEFT", fromFs, "RIGHT", 3, -3)
    return fs
end

local function HideWIMTranslationFont(theUser)
    if not WIM_Windows or not WIM_Windows[theUser] then return end
    local fs = getglobal(WIM_Windows[theUser].frame .. "WTTranslation")
    if fs and fs.Hide then
        fs:Hide()
        fs:SetText("")
    end
end

WoWTranslate_UpdateWIMHeader = function(theUser)
    if not theUser or theUser == "" then return end
    if not WoWTranslate_IsWIMActive() then return end
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
    if not ShouldTranslatePlayerName(theUser) then
        HideWIMTranslationFont(theUser)
        return
    end
    if WIM_PlayerCache and WIM_PlayerCache[theUser] and WIM_PlayerCache[theUser].isGM then
        HideWIMTranslationFont(theUser)
        return
    end
    if not WIM_Windows or not WIM_Windows[theUser] then return end

    ResolvePlayerDisplayName(theUser, function(translated)
        if not WIM_Windows or not WIM_Windows[theUser] then return end
        local fromFs = getglobal(WIM_Windows[theUser].frame .. "From")
        if not fromFs or not fromFs.SetText then return end

        if not translated or translated == "" or translated == theUser then
            HideWIMTranslationFont(theUser)
            fromFs:SetText(GetWIMHeaderDisplayName(theUser))
            return
        end

        local transFs = GetOrCreateWIMTranslationFont(theUser)
        if not transFs then return end

        fromFs:SetText(GetWIMHeaderDisplayName(theUser))
        transFs:SetText(" " .. ColorWIMHeaderText("(" .. translated .. ")", theUser))
        transFs:Show()
    end, true)
end

local function InstallWIMSetWhoInfoHook()
    if wimWhoInfoHookInstalled or type(WIM_SetWhoInfo) ~= "function" then
        return
    end
    local origSetWhoInfo = WIM_SetWhoInfo
    WIM_SetWhoInfo = function(theUser)
        origSetWhoInfo(theUser)
        WoWTranslate_UpdateWIMHeader(theUser)
    end
    wimWhoInfoHookInstalled = true
    DebugLog("WIM_SetWhoInfo hook installed")
end

InstallWIMHook = function()
    if not WoWTranslate_IsWIMActive() then
        return
    end
    if not wimHookInstalled and type(WIM_PostMessage) == "function" then
        wimOrigPost = WIM_PostMessage
        WIM_PostMessage = function(user, msg, ttype, from, raw_msg, hotkeyFix)
            -- Replace WIM's default outgoing line with sent Chinese + async [WT-English].
            if ttype == 2 and user and wimOutgoingPending[user] then
                local pending = wimOutgoingPending[user]
                local age = GetTime() - pending.time
                if age < 15 and WIMOutgoingRawMsgMatches(pending, raw_msg or msg) then
                    if not pending.displayed then
                        DisplayWIMOutgoingWhisper(user, pending.original, pending.translated)
                    end
                    return
                end
                if age >= 15 then
                    wimOutgoingPending[user] = nil
                end
            end
            wimOrigPost(user, msg, ttype, from, raw_msg, hotkeyFix)
            if user and user ~= "" and (ttype == 1 or ttype == 2 or ttype == 5) then
                WoWTranslate_UpdateWIMHeader(user)
            end
        end
        wimHookInstalled = true
        DebugLog("WIM_PostMessage hook installed")
    end
    InstallWIMSetWhoInfoHook()
end

local function QueueWIMOutgoingDisplay(recipient, originalMsg, translatedMsg)
    if not recipient or not originalMsg or not translatedMsg then return end
    if not WoWTranslate_IsWIMActive() then return end
    InstallWIMHook()
    wimOutgoingPending[recipient] = {
        original = originalMsg,
        translated = translatedMsg,
        time = GetTime(),
        displayed = false,
    }
end

-- ============================================================================
-- FRIENDS LIST NAME TRANSLATION
-- ============================================================================

local WT_FRIENDS_NAME_FS = "ButtonTextNameLocation"
local WT_FRIEND_LIST_FONT_SIZE = 10

local function HideFriendTranslationFont(i)
    local fs = getglobal("FriendsFrameFriendButton" .. i .. "WTTranslation")
    if fs and fs.Hide then
        fs:Hide()
        fs:SetText("")
    end
end

local function ApplyFriendListSmallFont(fs)
    if not fs or not fs.SetFont then return end
    local fontPath, size, flags = "Fonts\\FRIZQT__.TTF", WT_FRIEND_LIST_FONT_SIZE, ""
    if GameFontNormalSmall and GameFontNormalSmall.GetFont then
        local f, s, fl = GameFontNormalSmall:GetFont()
        if f then fontPath = f end
        if fl then flags = fl end
        if s and tonumber(s) and tonumber(s) > 0 then
            size = tonumber(s)
        end
    end
    fs:SetFont(fontPath, size, flags)
end

local function QueueFriendNameTranslation(name)
    if not name or name == "" then return end
    if wtFriendTransCache[name] ~= nil or wtFriendTransPending[name] then return end

    local cached, found = WoWTranslate_CacheGet(NameCacheKey(name))
    if found then
        if cached and cached ~= "" and cached ~= name then
            wtFriendTransCache[name] = cached
        else
            wtFriendTransCache[name] = false
        end
        return
    end

    wtFriendTransPending[name] = true
    ResolvePlayerDisplayName(name, function(translated)
        wtFriendTransPending[name] = nil
        if translated and translated ~= "" and translated ~= name then
            wtFriendTransCache[name] = translated
        else
            wtFriendTransCache[name] = false
        end
        if FriendsFrame and FriendsFrame.IsVisible and FriendsFrame:IsVisible()
            and FriendsList_Update then
            FriendsList_Update()
        end
    end, true)
end

local function WoWTranslate_UpdateFriendsList()
    if not WoWTranslateDB or not WoWTranslateDB.enabled then return end
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then return end
    if not FriendsFrame or not FriendsFrame.IsVisible or not FriendsFrame:IsVisible() then return end
    if not GetNumFriends or GetNumFriends() == 0 then return end
    if not FRIENDS_TO_DISPLAY or not FriendsFrameFriendsScrollFrame then return end
    if not FauxScrollFrame_GetOffset or not GetFriendInfo then return end

    local off = FauxScrollFrame_GetOffset(FriendsFrameFriendsScrollFrame)
    local playerzone = GetRealZoneText and GetRealZoneText() or ""

    for i = 1, FRIENDS_TO_DISPLAY do
        local name, level, class, zone, connected, status = GetFriendInfo(off + i)
        if not name or name == "" or (UNKNOWN and name == UNKNOWN) then
            HideFriendTranslationFont(i)
        elseif not ShouldTranslatePlayerName(name) then
            HideFriendTranslationFont(i)
        else
            QueueFriendNameTranslation(name)
            local translated = wtFriendTransCache[name]
            local friendName = getglobal("FriendsFrameFriendButton" .. i .. "ButtonTextName")
            local friendLoc = getglobal("FriendsFrameFriendButton" .. i .. WT_FRIENDS_NAME_FS)

            if not translated or translated == false then
                HideFriendTranslationFont(i)
            else
                HideFriendTranslationFont(i)
                local cname = ColorSocialPlayerText(name, name, class)
                local nameWithTrans = cname .. " " .. ColorSocialPlayerText("(" .. translated .. ")", name, class)
                if friendName then
                    ApplyFriendListSmallFont(friendName)
                    friendName:SetText(nameWithTrans)
                elseif friendLoc then
                    ApplyFriendListSmallFont(friendLoc)
                    if connected then
                        local zstr = zone or ""
                        if playerzone ~= "" and zone == playerzone then
                            zstr = "|cffffffff" .. zstr .. "|r"
                        else
                            zstr = "|cffcccccc" .. zstr .. "|r"
                        end
                        local listTmpl = FRIENDS_LIST_TEMPLATE
                        if TEXT and listTmpl then listTmpl = TEXT(listTmpl) end
                        if listTmpl then
                            friendLoc:SetText(format(listTmpl, nameWithTrans, zstr, status or ""))
                        else
                            friendLoc:SetText(nameWithTrans)
                        end
                    else
                        local offTmpl = FRIENDS_LIST_OFFLINE_TEMPLATE
                        if TEXT and offTmpl then offTmpl = TEXT(offTmpl) end
                        if offTmpl then
                            friendLoc:SetText(format(offTmpl, nameWithTrans))
                        else
                            friendLoc:SetText(nameWithTrans)
                        end
                    end
                end
            end
        end
    end
end

local function InstallFriendsListHook()
    if wtFriendsListHookInstalled or not FriendsList_Update then return end
    local hookFn = hooksecurefunc
        or (ShaguTweaks and ShaguTweaks.hooksecurefunc)
    if hookFn then
        hookFn("FriendsList_Update", WoWTranslate_UpdateFriendsList)
    else
        local orig = FriendsList_Update
        FriendsList_Update = function()
            orig()
            WoWTranslate_UpdateFriendsList()
        end
    end
    wtFriendsListHookInstalled = true
    DebugLog("FriendsList_Update hook installed")
end

-- ============================================================================
-- CHAT FRAME HOOKING
-- ============================================================================

-- Maps event to ChatTypeInfo key so we can read the native channel color.
-- CHAT_MSG_CHANNEL requires special handling (channel slot number determines the key).
local EVENT_TO_CHATTYPE = {
    CHAT_MSG_SAY                 = "SAY",
    CHAT_MSG_YELL                = "YELL",
    CHAT_MSG_WHISPER             = "WHISPER",
    CHAT_MSG_WHISPER_INFORM      = "WHISPER",
    CHAT_MSG_PARTY               = "PARTY",
    CHAT_MSG_GUILD               = "GUILD",
    CHAT_MSG_OFFICER             = "OFFICER",
    CHAT_MSG_RAID                = "RAID",
    CHAT_MSG_RAID_LEADER         = "RAID",
    CHAT_MSG_RAID_WARNING        = "RAID",
    CHAT_MSG_BATTLEGROUND        = "BATTLEGROUND",
    CHAT_MSG_BATTLEGROUND_LEADER = "BATTLEGROUND",
    CHAT_MSG_HARDCORE            = "HARDCORE",
}

-- Returns a 6-char uppercase hex string from ChatTypeInfo, or nil if not found.
local function GetChatTypeColorHex(event, channelStr)
    local chatType = EVENT_TO_CHATTYPE[event]
    if not chatType and event == "CHAT_MSG_CHANNEL" then
        local _, _, cap = string.find(channelStr or "", "^(%d+)%.")
        local num = cap and tonumber(cap)
        chatType = num and ("CHANNEL" .. num) or "CHANNEL"
    end
    if chatType and ChatTypeInfo and ChatTypeInfo[chatType] then
        local info = ChatTypeInfo[chatType]
        local r = info.r or 1
        local g = info.g or 1
        local b = info.b or 1
        return string.format("%02X%02X%02X",
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5))
    end
    return nil
end

-- Per-event display tags for the [WT-X] prefix shown with each translation.
-- CHAT_MSG_CHANNEL is handled dynamically from arg4 (channel name string).
local EVENT_CHANNEL_TAGS = {
    CHAT_MSG_SAY                  = "WT-Say",
    CHAT_MSG_YELL                 = "WT-Yell",
    CHAT_MSG_WHISPER              = "WT-Whisper",
    CHAT_MSG_WHISPER_INFORM       = "WT-Whisper",
    CHAT_MSG_PARTY                = "WT-Party",
    CHAT_MSG_GUILD                = "WT-Guild",
    CHAT_MSG_OFFICER              = "WT-Officer",
    CHAT_MSG_RAID                 = "WT-Raid",
    CHAT_MSG_RAID_LEADER          = "WT-Raid",
    CHAT_MSG_RAID_WARNING         = "WT-Raid",
    CHAT_MSG_BATTLEGROUND         = "WT-BG",
    CHAT_MSG_BATTLEGROUND_LEADER  = "WT-BG",
    CHAT_MSG_HARDCORE             = "WT-Hardcore",
}

-- Returns the [WT-X] tag string for a given event.
-- For CHAT_MSG_CHANNEL, channelStr is arg4 (e.g. "2. Trade" or "World").
local function GetChannelTag(event, channelStr)
    local tag = EVENT_CHANNEL_TAGS[event]
    if tag then return tag end
    if event == "CHAT_MSG_CHANNEL" then
        if channelStr and channelStr ~= "" then
            -- Strip leading "N. " number prefix that WoW prepends to channel names
            local name = string.gsub(channelStr, "^%d+%.%s*", "")
            if name and name ~= "" then return "WT-" .. name end
        end
        return "WT-Channel"
    end
    return "WT"
end

-- force=true clears WoWTranslateHooked so all frames are re-hooked (used by /wt reset).
-- origScript is saved on the frame so re-hooking always wraps the real WoW handler,
-- never a previously-installed WoWTranslate wrapper (no double-wrapping).
local function HookChatFrames(force)
    if not originalAddMessage and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        originalAddMessage = DEFAULT_CHAT_FRAME.AddMessage
    end

    for i = 1, NUM_CHAT_WINDOWS do
        local frameName = "ChatFrame" .. i
        local frame = getglobal(frameName)

        if frame then
            if force then frame.WoWTranslateHooked = false end

            if not frame.WoWTranslateHooked then
                -- On re-hook use the saved original so we never wrap our own wrapper
                local origScript = frame.WoWTranslate_OrigScript or frame:GetScript("OnEvent")
                if not origScript then
                    DebugLog("No OnEvent script on", frameName)
                else
                    frame.WoWTranslate_OrigScript = origScript  -- persist for safe re-hook
                    frame.WoWTranslateHooked = true

                    frame:SetScript("OnEvent", function()
                        hookCallCount = hookCallCount + 1

                        -- Capture event globals before origScript may clobber them
                        local capturedEvent = event
                        local capturedArg1  = arg1
                        local capturedArg2  = arg2
                        local capturedArg4  = arg4  -- channel name string for CHAT_MSG_CHANNEL
                        local capturedThis  = this

                        -- Wrap in pcall: an unhandled Lua error in a SetScript handler
                        -- silently disables it in WoW 1.12. Capture the error for debug.
                        local _ok, _err = pcall(function()
                            -- Let WoW's own filter decide: if origScript didn't add a message
                            -- to this frame (filtered out), don't add a translation either.
							-- Primary: shadow AddMessage on the frame instance to detect the call
							-- directly — this works even when the ring-buffer is full (128 msgs),
							-- where GetNumMessages() alone cannot distinguish "shown" from "filtered".
							-- Fallback: if the shadow was never triggered (e.g. WoW build ignores
 							-- instance-table shadows for built-in methods), use GetNumMessages with
							-- the pre-fix < 128 heuristic so we degrade gracefully.
                            local msgsBefore = capturedThis:GetNumMessages()
                            local messageShownInFrame = false
                            local origFrameAddMsg = capturedThis.AddMessage
                            -- replaceMode: args from the intercepted AddMessage call; nil = not captured.
                            local pendingArgs = nil

                            capturedThis.AddMessage = function(f, a, b, c, d, e, g)
                                messageShownInFrame = true
                                -- Restore to the previous hook (ShaguTweaks etc.) rather than nil.
                                -- Setting nil would expose the raw WoW metatable method, silently
                                -- breaking any AddMessage chains installed by other addons.
                                capturedThis.AddMessage = origFrameAddMsg
                                if WoWTranslateDB and WoWTranslateDB.replaceMode then
                                    -- Suppress the original; hold args so we can show the original
                                    -- on early-exit paths or show the translation on success.
                                    pendingArgs = {f=f, a=a, b=b, c=c, d=d, e=e, g=g}
                                else
                                    origFrameAddMsg(f, a, b, c, d, e, g)
                                end
                            end

                            -- Shows the original message if it was suppressed and translation
                            -- was not produced (early exit, DLL error, etc.).
                            local function FlushOriginal()
                                if pendingArgs then
                                    origFrameAddMsg(pendingArgs.f, pendingArgs.a, pendingArgs.b,
                                                    pendingArgs.c, pendingArgs.d, pendingArgs.e,
                                                    pendingArgs.g)
                                    pendingArgs = nil
                                end
                            end

                            local origOk, origErr = pcall(origScript)
							
                            -- Always restore; never leave our wrapper or a nil in place.
                            capturedThis.AddMessage = origFrameAddMsg

                            if not origOk then
                                DebugLog("origScript error:", tostring(origErr))
                                FlushOriginal(); return
                            end

                            if not messageShownInFrame then
                                -- Shadow either worked (message filtered) or wasn't triggered.
                                -- Use GetNumMessages as fallback — ambiguous only at 128.
                                local msgsAfter = capturedThis:GetNumMessages()
                                if msgsAfter < msgsBefore
                                    or (msgsAfter == msgsBefore and msgsBefore < 128) then
                                    -- WIM suppresses whispers from chat frames by default.
                                    -- Keep going so we can post the translation to the WIM window.
                                    if not (capturedEvent == "CHAT_MSG_WHISPER"
                                        and WoWTranslate_IsWIMWhisperSuppressed()
                                        and capturedArg2 and capturedArg2 ~= "") then
                                        FlushOriginal(); return
                                    end
                                end
                            end

                            if not WoWTranslateDB or not WoWTranslateDB.enabled then FlushOriginal(); return end
                            if WoWTranslateDB.disableWhileAfk and playerIsAFK then FlushOriginal(); return end

                            local channel  = EVENT_TO_CHANNEL[capturedEvent]
                            local isSystem = SYSTEM_EVENTS[capturedEvent]
                            if not channel and not isSystem then FlushOriginal(); return end
                            if isSystem and not WoWTranslateDB.translateSystemMessages then FlushOriginal(); return end

                            if channel then
                                local inChannels = WoWTranslateDB.incomingChannels
                                local effectiveChannel = channel
                                if channel == "CHANNEL" and capturedArg4 then
                                    local chanName = string.gsub(capturedArg4, "^%d+%.%s*", "")
                                    if string.find(string.lower(chanName), "^english") then
                                        effectiveChannel = "ENGLISH"
                                    end
                                end
                                if inChannels and not inChannels[effectiveChannel] then FlushOriginal(); return end
                            end

                            if not capturedArg1 or capturedArg1 == "" then FlushOriginal(); return end
                            if string.sub(capturedArg1, 1, 8) == "Meeting:" then FlushOriginal(); return end
                            if string.sub(capturedArg1, 1, 1) == "#" then FlushOriginal(); return end
                            -- Strip any WoWTranslate prefix that another addon user prepended.
                            -- All prefix variants are [... WoWTranslate ...] — strip up to the
                            -- closing ] so the body is still translated normally.
                            do
                                local p = string.find(capturedArg1, "WoWTranslate", 1, true)
                                if p and p <= 50 then
                                    local closeBracket = string.find(capturedArg1, "]", p, true)
                                    if closeBracket then
                                        local stripped = string.gsub(string.sub(capturedArg1, closeBracket + 1), "^%s+", "")
                                        if stripped ~= "" then capturedArg1 = stripped end
                                    end
                                end
                            end

                            local detectedLang = DetectSourceLanguage(capturedArg1)
                            DebugLog("Event:", capturedEvent, "lang=", tostring(detectedLang), "msg=", string.sub(capturedArg1, 1, 30))
                            if not detectedLang then FlushOriginal(); return end
                            -- Skip no-op translations (e.g. zh→zh when Chinese player sets target=zh).
                            -- Without this, the ZH→EN glossary fires on Chinese text, inserts English,
                            -- and the result is shown in English or sent to the DLL as zh→zh garbage.
                            local incomingTargetLang = (WoWTranslateDB and WoWTranslateDB.incomingToLang) or "en"
                            if detectedLang == incomingTargetLang then FlushOriginal(); return end

                            local displayPlayerName = capturedArg2

                            local channelTag   = GetChannelTag(capturedEvent, capturedArg4)
                            local msgColor     = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
                            local chanColorHex = GetChatTypeColorHex(capturedEvent, capturedArg4)
                            -- Channel name part of the tag (everything after "WT-"), or nil for bare "WT".
                            local chanNamePart = string.sub(channelTag, 1, 3) == "WT-" and string.sub(channelTag, 4) or nil

                            -- WIM: when WIM suppresses a whisper from chat frames, we post
                            -- the translation directly to the WIM window instead.
                            local wimWhisperUser = nil

                            local function BuildWTMsg(body)
                                -- Prefix: [WT- in cyan, channel name in the native channel color.
                                local prefix
                                if chanColorHex and chanNamePart then
                                    prefix = "|cFF00FFFF[WT-|r|cFF" .. chanColorHex .. chanNamePart .. "]|r"
                                else
                                    prefix = "|cFF00FFFF[" .. channelTag .. "]|r"
                                end
                                -- Body: use channel color when "follow" is on, else custom or default.
                                local bodyHex = msgColor
                                if WoWTranslateDB and WoWTranslateDB.translationColorFollow then
                                    bodyHex = chanColorHex or ""
                                end
                                local displayBody = bodyHex ~= "" and ("|cFF" .. bodyHex .. body .. "|r") or body
                                if wimWhisperUser then
                                    return prefix .. " " .. displayBody
                                end
                                local senderUnit = FindPlayerUnitByName(capturedArg2)
                                local sender = BuildSenderPrefix(capturedArg2, displayPlayerName, channel, senderUnit)
                                if sender ~= "" then
                                    return prefix .. " " .. sender .. displayBody
                                end
                                return prefix .. " " .. displayBody
                            end

                            local function PostWTMsg(wtMsg)
                                if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                    WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                else
                                    capturedThis:AddMessage(wtMsg)
                                end
                            end
                            local function PostTranslatedBody(body)
                                if WoWTranslateDB.translatePlayerNames and capturedArg2 then
                                    ResolvePlayerDisplayName(capturedArg2, function(resolvedName)
                                        displayPlayerName = resolvedName
                                        PostWTMsg(BuildWTMsg(body))
                                    end)
                                else
                                    PostWTMsg(BuildWTMsg(body))
                                end
                            end

                            -- Post a pre-built WT line to every frame that showed the original.
                            local function PostWTMsgToAllTargets(wtMsg)
                                if wimWhisperUser and type(WIM_PostMessage) == "function" then
                                    WIM_PostMessage(wimWhisperUser, wtMsg, 3)
                                else
                                    local targets = frameTranslationTargets[capturedArg1]
                                    frameTranslationTargets[capturedArg1] = nil
                                    if targets then
                                        for targetFrame in pairs(targets) do
                                            targetFrame:AddMessage(wtMsg)
                                        end
                                    else
                                        DEFAULT_CHAT_FRAME:AddMessage(wtMsg)
                                    end
                                end
                            end

                            local function PostTranslatedBodyToAllTargets(body)
                                ResolvePlayerDisplayName(capturedArg2, function(resolvedName)
                                    displayPlayerName = resolvedName
                                    PostWTMsgToAllTargets(BuildWTMsg(body))
                                end)
                            end

                            -- Split into text and hyperlink segments.
                            -- Chinese bytes in link display names (e.g. [剑]) are NOT
                            -- translatable plain text — HasTranslatableContent checks only
                            -- text segments. Pure-link messages are skipped here, which
                            -- also prevents the raw | pipe codes from breaking DLL parsing.
                            local segments = SplitIntoSegments(capturedArg1)
                            if not HasTranslatableContent(segments) then FlushOriginal(); return end

                            -- Build text with hyperlinks as URL placeholders so the DLL
                            -- never sees WoW pipe-codes in the text it sends to Google.
                            local plainText = BuildTranslatableText(segments)

                            -- Register this frame as a recipient for the translation of
                            -- this message.  WoW fires each chat frame's OnEvent in turn
                            -- for the same message, so capturedThis differs per iteration.
                            -- Dedup lets only the first frame reach the DLL; we collect all
                            -- frames here so the async callback posts to every relevant tab.
                            -- Only register when the AddMessage interception confirmed the
                            -- original message actually appeared in this frame.  Frames that
                            -- filtered the message (channel disabled, tab not showing it)
                            -- must not receive the translation either.
                            if not messageShownInFrame then
                                if capturedEvent == "CHAT_MSG_WHISPER"
                                    and WoWTranslate_IsWIMWhisperSuppressed()
                                    and capturedArg2 and capturedArg2 ~= "" then
                                    wimWhisperUser = capturedArg2
                                else
                                    FlushOriginal(); return
                                end
                            end
                            if wimWhisperUser then
                                InstallWIMHook()
                                if wimPostedMessages[capturedArg1] then
                                    FlushOriginal(); return
                                end
                                wimPostedMessages[capturedArg1] = GetTime()
                            else
                                if not frameTranslationTargets[capturedArg1] then
                                    frameTranslationTargets[capturedArg1] = {}
                                end
                                frameTranslationTargets[capturedArg1][capturedThis] = true
                            end

                            local cached, found = WoWTranslate_CacheGet(capturedArg1)
                            if found then
                                DebugLog("Cache hit")
                                local reconstructed = ReconstructMessage(segments, cached)
                                -- Sync path: each frame handles itself; clear shared table entry.
                                frameTranslationTargets[capturedArg1] = nil
                                PostTranslatedBody(reconstructed)
                                return
                            end

                            local textToTranslate = plainText
                            if detectedLang == "en" then
                                -- English source: apply EN→ZH outgoing glossary
                                if WoWTranslate_CheckOutGlossaryExact then
                                    local r = WoWTranslate_CheckOutGlossaryExact(plainText)
                                    if r then
                                        DebugLog("Outgoing glossary exact (incoming EN):", r)
                                        WoWTranslate_CacheSave(capturedArg1, r)
                                        frameTranslationTargets[capturedArg1] = nil
                                        PostTranslatedBody(ReconstructMessage(segments, r))
                                        return
                                    end
                                end
                                if WoWTranslate_CheckOutGlossaryPartial then
                                    local r = WoWTranslate_CheckOutGlossaryPartial(plainText)
                                    if r then
                                        DebugLog("Outgoing glossary partial (incoming EN):", r)
                                        textToTranslate = r
                                    end
                                end
                            else
                                -- Preprocess: currency (XG = gold, XY = silver), 88 = bye, 110 = patrol
                                plainText = PreprocessIncoming(plainText)
                                textToTranslate = plainText
                                -- CJK/Russian source: apply ZH→EN incoming glossary
                                local glossaryResult = WoWTranslate_CheckGlossaryExact(plainText)
                                if glossaryResult then
                                    DebugLog("Glossary exact:", glossaryResult)
                                    WoWTranslate_CacheSave(capturedArg1, glossaryResult)
                                    local reconstructed = ReconstructMessage(segments, glossaryResult)
                                    frameTranslationTargets[capturedArg1] = nil
                                    PostTranslatedBody(reconstructed)
                                    return
                                end
                                local partialResult = WoWTranslate_CheckGlossaryPartial(plainText)
                                if partialResult then
                                    if not DetectSourceLanguage(partialResult) then
                                        DebugLog("Glossary full partial:", partialResult)
                                        WoWTranslate_CacheSave(capturedArg1, partialResult)
                                        local reconstructed = ReconstructMessage(segments, partialResult)
                                        frameTranslationTargets[capturedArg1] = nil
                                        PostTranslatedBody(reconstructed)
                                        return
                                    end
                                    textToTranslate = partialResult
                                    DebugLog("Glossary pre-processed, sending to API")
                                end
                            end

                            if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
                                if not dllWarnShown then
                                    dllWarnShown = true
                                    capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] DLL not connected - run /wt status|r")
                                end
                                FlushOriginal(); return
                            end

                            -- replaceMode: transfer captured args to pendingMessages so the
                            -- 30s safety net can restore the original if the DLL never responds.
                            local replacePendingKey = nil
                            if pendingArgs then
                                replacePendingKey = "r|" .. tostring(capturedThis) .. "|" .. capturedArg1
                                pendingMessages[replacePendingKey] = {
                                    originalAddMessage = origFrameAddMsg,
                                    frame              = pendingArgs.f,
                                    originalText       = pendingArgs.a,
                                    r = pendingArgs.b, g = pendingArgs.c, b = pendingArgs.d,
                                    id = pendingArgs.e, holdTime = pendingArgs.g,
                                    timestamp = GetTime()
                                }
                                pendingArgs = nil
                            end

                            -- Prime name translation in parallel with the message body.
                            if WoWTranslateDB.translatePlayerNames
                                and capturedArg2 and ShouldTranslatePlayerName(capturedArg2) then
                                ResolvePlayerDisplayName(capturedArg2, function() end)
                            end

                            WoWTranslate_API.Translate(textToTranslate, function(translation, err)
                                if translation and translation ~= "" then
                                    DebugLog("Translation:", string.sub(translation, 1, 50))
                                    translationErrWarnShown = false
                                    WoWTranslate_CacheSave(capturedArg1, translation)
                                    local reconstructed = ReconstructMessage(segments, translation)
                                    -- replaceMode: original was suppressed; clear safety net entry.
                                    if replacePendingKey then
                                        pendingMessages[replacePendingKey] = nil
                                    end
                                    PostTranslatedBodyToAllTargets(reconstructed)
                                else
                                    DebugLog("Translation error:", tostring(err))
                                    frameTranslationTargets[capturedArg1] = nil
                                    -- replaceMode: translation failed — show original immediately.
                                    if replacePendingKey then
                                        local rp = pendingMessages[replacePendingKey]
                                        if rp then
                                            pendingMessages[replacePendingKey] = nil
                                            rp.originalAddMessage(rp.frame, rp.originalText,
                                                rp.r, rp.g, rp.b, rp.id, rp.holdTime)
                                        end
                                    end
                                    if not translationErrWarnShown then
                                        translationErrWarnShown = true
                                        capturedThis:AddMessage("|cFFFFFF00[WoWTranslate] Translation failing (" .. tostring(err) .. ") - try /wt reset|r")
                                    end
                                end
                            end, detectedLang)
                        end)  -- end pcall
                        if not _ok then DebugLog("OnEvent hook error:", tostring(_err)) end
                    end)

                    DebugLog("Hooked", frameName, "via SetScript")
                end
            end
        end
    end
end

local function CleanupPendingMessages()
    local now = GetTime()
    for msgId, pending in pairs(pendingMessages) do
        if now - pending.timestamp > 30 then
            DebugLog("Message timed out:", msgId)
            pending.originalAddMessage(pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
            pendingMessages[msgId] = nil
        end
    end
end

-- ============================================================================
-- OUTGOING TRANSLATION (English -> Chinese)
-- ============================================================================

-- Clean up queued outgoing messages after timeout
local function CleanupOutgoingQueue()
    local now = GetTime()
    for queueId, item in pairs(outgoingQueue) do
        if now - item.timestamp > 30 then
            DebugLog("Outgoing message timed out:", queueId)
            if originalAddMessage then
                originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] Translation timed out, sending original|r")
            end
            originalSendChatMessage(item.originalMsg, item.chatType, item.language, item.channel)
            outgoingQueue[queueId] = nil
        end
    end
end

-- Hooked SendChatMessage for outgoing translation
local function HookedSendChatMessage(msg, chatType, language, channel)
    -- Handle nil chatType (WoW 1.12 compatibility)
    if not chatType then
        DebugLog("chatType is nil, sending original")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if outgoing disabled
    if not WoWTranslateDB or not WoWTranslateDB.outgoingEnabled then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip translation while AFK
    if WoWTranslateDB.disableWhileAfk and playerIsAFK then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if channel not enabled
    if not WoWTranslateDB.outgoingChannels then
        DebugLog("Channel not enabled for outgoing:", chatType)
        return originalSendChatMessage(msg, chatType, language, channel)
    end
    local effectiveOutChannel = chatType
    if chatType == "CHANNEL" and channel then
        -- GetChannelName(number) does not reliably return the name in WoW 1.12;
        -- iterate GetChannelList() instead (returns id, name, id, name, ...).
        local list = {GetChannelList()}
        for i = 1, table.getn(list), 2 do
            if list[i] == channel then
                if string.find(string.lower(list[i+1] or ""), "^english") then
                    effectiveOutChannel = "ENGLISH"
                end
                break
            end
        end
    end
    if not WoWTranslateDB.outgoingChannels[effectiveOutChannel] then
        DebugLog("Channel not enabled for outgoing:", effectiveOutChannel)
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip empty messages
    if not msg or msg == "" then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip macro directives (#showtooltip, #show, etc.)
    if string.sub(msg, 1, 1) == "#" then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip dot-commands sent by addons (e.g. .server info from PizzaWorldBuffs)
    if string.sub(msg, 1, 1) == "." then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip Meeting addon protocol on LFT / channel traffic
    if string.sub(msg, 1, 8) == "Meeting:" then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip addon inter-communication messages (PizzaWorldBuffs, Atlas-CFM, etc.)
    -- These follow the format: ADDONNAME:VERSION:DATA
    if string.find(msg, "^[A-Za-z][A-Za-z0-9_]*:%d+:") then
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if already contains target language (don't double-translate)
    if ContainsOutgoingTargetLanguage(msg) then
        DebugLog("Message already contains target language, skipping outgoing translation")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Skip if DLL not available
    if not WoWTranslate_API or not WoWTranslate_API.IsAvailable() then
        DebugLog("DLL not available for outgoing translation")
        return originalSendChatMessage(msg, chatType, language, channel)
    end

    -- Split message into segments (text and hyperlinks) to preserve links
    local segments = SplitIntoSegments(msg)
    DebugLog("Outgoing segments:", table.getn(segments))

    -- Build text to translate (hyperlinks replaced with URL placeholders)
    local textToTranslate = BuildTranslatableText(segments)
    DebugLog("Outgoing to translate:", textToTranslate)

    -- Apply the glossary that matches the outgoing source language direction.
    local outFromLang = WoWTranslateDB.outgoingFromLang or "en"
    if outFromLang == "en" then
        -- Convert EN currency notation to CN before glossary/API (Xg→XG, Xs→XY)
        textToTranslate = PreprocessOutgoing(textToTranslate)
        -- EN→ZH: apply EN→ZH outgoing glossary
        if WoWTranslate_CheckOutGlossaryExact then
            local glossaryResult = WoWTranslate_CheckOutGlossaryExact(textToTranslate)
            if not glossaryResult and WoWTranslate_CheckOutGlossaryPartial then
                glossaryResult = WoWTranslate_CheckOutGlossaryPartial(textToTranslate)
            end
            if glossaryResult then
                DebugLog("Outgoing glossary (EN→ZH) applied:", glossaryResult)
                textToTranslate = glossaryResult
            end
        end
    else
        -- ZH→EN (or other non-English source): apply ZH→EN incoming glossary
        if WoWTranslate_CheckGlossaryExact then
            local glossaryResult = WoWTranslate_CheckGlossaryExact(textToTranslate)
            if not glossaryResult and WoWTranslate_CheckGlossaryPartial then
                glossaryResult = WoWTranslate_CheckGlossaryPartial(textToTranslate)
            end
            if glossaryResult then
                DebugLog("Outgoing glossary (ZH→EN) applied:", glossaryResult)
                textToTranslate = glossaryResult
            end
        end
    end

    -- Queue for translation
    outgoingCounter = outgoingCounter + 1
    local queueId = tostring(outgoingCounter)

    outgoingQueue[queueId] = {
        originalMsg = msg,
        segments = segments,  -- Store segments for reconstruction
        chatType = chatType,
        language = language,
        channel = channel,
        timestamp = GetTime()
    }

    -- Show local feedback
    if originalAddMessage then
        originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFFFF00[WoWTranslate] Translating...|r")
    end

    DebugLog("Outgoing queued:", queueId, msg)

    -- Request translation (send only the text portions, not hyperlinks)
    WoWTranslate_API.TranslateOutgoing(textToTranslate, function(translation, err)
        local queued = outgoingQueue[queueId]
        if not queued then
            DebugLog("Outgoing callback but queue item gone:", queueId)
            return
        end
        outgoingQueue[queueId] = nil

        if translation then
            DebugLog("Outgoing translation received:", translation)

            -- Reconstruct message with original hyperlinks
            local reconstructed = ReconstructMessage(queued.segments, translation)
            DebugLog("Outgoing reconstructed:", reconstructed)

            -- Build message, optionally prepending the prefix
            local finalMsg
            if WoWTranslateDB.outgoingPrefixEnabled then
                local userPrefix = WoWTranslateDB.outgoingPrefix or DEFAULT_PREFIX
                local prefix
                if userPrefix == DEFAULT_PREFIX then
                    local targetLang = WoWTranslateDB.outgoingToLang or "zh"
                    prefix = TRANSLATED_PREFIXES[targetLang] or userPrefix
                else
                    prefix = userPrefix
                end
                finalMsg = prefix .. " " .. reconstructed
            else
                finalMsg = reconstructed
            end

            -- Truncate if over 255 bytes (WoW chat limit)
            if string.len(finalMsg) > 255 then
                finalMsg = string.sub(finalMsg, 1, 252) .. "..."
            end

            if queued.chatType == "WHISPER" and queued.channel then
                QueueWIMOutgoingDisplay(queued.channel, queued.originalMsg, finalMsg)
            end

            originalSendChatMessage(finalMsg, queued.chatType, queued.language, queued.channel)

            -- Fallback if WHISPER_INFORM hook misses (prefix/truncation mismatch).
            if queued.chatType == "WHISPER" and queued.channel and WoWTranslate_IsWIMActive() then
                local wimUser = queued.channel
                local wimTyped = queued.originalMsg
                local wimSent = finalMsg
                if InstallWIMHook then InstallWIMHook() end
                local deferFrame = CreateFrame("Frame")
                deferFrame:SetScript("OnUpdate", function()
                    this:SetScript("OnUpdate", nil)
                    local pending = wimOutgoingPending[wimUser]
                    if pending and not pending.displayed then
                        DisplayWIMOutgoingWhisper(wimUser, wimTyped, wimSent)
                    end
                end)
            end

            if originalAddMessage then
                originalAddMessage(DEFAULT_CHAT_FRAME, "|cFF00FF00[WoWTranslate] Sent:|r " .. finalMsg)
                -- Back-translation is requested once from DisplayWIMOutgoingWhisper (WIM path).
                -- A second RequestWhisperBackTranslation here loses the DLL slot and only chat got [WT-English].
                if queued.chatType == "WHISPER"
                    and not (queued.channel and WoWTranslate_IsWIMActive()) then
                    RequestWhisperBackTranslation(finalMsg, queued.originalMsg, function(englishLine)
                        if englishLine and englishLine ~= "" and originalAddMessage then
                            originalAddMessage(DEFAULT_CHAT_FRAME, BuildWIMEnglishReminderLine(englishLine))
                        end
                    end)
                end
            end
        else
            -- Translation failed - send original
            DebugLog("Outgoing translation failed:", err)
            if originalAddMessage then
                originalAddMessage(DEFAULT_CHAT_FRAME, "|cFFFF0000[WoWTranslate] Translation failed, sending original|r")
            end
            originalSendChatMessage(queued.originalMsg, queued.chatType, queued.language, queued.channel)
        end
    end)
end

-- Track if hook is installed (for diagnostics)
local outgoingHookInstalled = false

-- Install the outgoing message hook
local function InstallOutgoingHook()
    if SendChatMessage ~= HookedSendChatMessage then
        DebugLog("Installing outgoing SendChatMessage hook")
        SendChatMessage = HookedSendChatMessage
        outgoingHookInstalled = true
    end
end

-- Remove the outgoing message hook
local function RemoveOutgoingHook()
    if SendChatMessage == HookedSendChatMessage then
        DebugLog("Removing outgoing SendChatMessage hook")
        SendChatMessage = originalSendChatMessage
        outgoingHookInstalled = false
    end
end

-- Check if hook is active (for diagnostics)
local function IsOutgoingHookActive()
    return outgoingHookInstalled and SendChatMessage == HookedSendChatMessage
end

function WoWTranslate_SyncOutgoingConfigUI(enabled)
    if configFrame and configFrame.elements and configFrame.elements.outEnabled then
        configFrame.elements.outEnabled:SetChecked(enabled)
    end
    if WoWTranslate_TempConfig then
        WoWTranslate_TempConfig.outgoingEnabled = enabled
    end
end

function WoWTranslate_ToggleOutgoingEnabled(notify)
    local nowEnabled = not (WoWTranslateDB and WoWTranslateDB.outgoingEnabled)
    WoWTranslate_SetOutgoingEnabled(nowEnabled)
    if notify then
        local status = nowEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate]|r Outgoing: " .. status)
    end
    return nowEnabled
end

-- ============================================================================
-- OUTGOING TOGGLE BUTTON
-- ============================================================================
local outgoingButton = nil

local function UpdateOutgoingButton()
    if not outgoingButton then return end
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        outgoingButton:SetText("|cFF00FF00OUT:ON|r")
    else
        outgoingButton:SetText("|cFFFF4444OUT:OFF|r")
    end
end

local function CreateOutgoingButton()
    if outgoingButton then return end
    local f = CreateFrame("Button", "WoWTranslateOutgoingButton", UIParent)
    outgoingButton = f
    f:SetWidth(48)
    f:SetHeight(15)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "",
        tile = true, tileSize = 8, edgeSize = 0,
        insets = { left=0, right=0, top=0, bottom=0 },
    })
    f:SetBackdropColor(0, 0, 0, 0.7)

    local pos = WoWTranslateDB and WoWTranslateDB.outgoingButtonPos or { x=100, y=100 }
    f:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)

    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetAllPoints(f)
    f.label = label

    f:SetScript("OnMouseUp", function()
        if arg1 == "LeftButton" then
            WoWTranslate_ToggleOutgoingEnabled(false)
        end
    end)
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local x = f:GetLeft()
        local y = f:GetBottom()
        if WoWTranslateDB then
            WoWTranslateDB.outgoingButtonPos = { x = x, y = y }
        end
    end)

    function f:SetText(text) self.label:SetText(text) end

    UpdateOutgoingButton()
end

-- ============================================================================
-- GLOBAL FUNCTIONS FOR CONFIG UI
-- ============================================================================

function WoWTranslate_SetTranslateNameplates(val)
    if WoWTranslateDB then WoWTranslateDB.translateNameplates = val end
    if WoWTranslate_RefreshNameplateColors then
        WoWTranslate_RefreshNameplateColors()
    end
end

function WoWTranslate_SetTranslatePlayerNames(val)
    if WoWTranslateDB then WoWTranslateDB.translatePlayerNames = val end
end

function WoWTranslate_SetTranslateGuildNames(val)
    if WoWTranslateDB then WoWTranslateDB.translateGuildNames = val end
end

-- Toggle outgoing translation (called from config UI)
function WoWTranslate_SetOutgoingEnabled(enabled)
    if enabled then
        WoWTranslateDB.outgoingEnabled = true
        InstallOutgoingHook()
    else
        WoWTranslateDB.outgoingEnabled = false
        RemoveOutgoingHook()
    end
    UpdateOutgoingButton()
    WoWTranslate_SyncOutgoingConfigUI(enabled)
end

-- Toggle incoming translation (called from config UI)
function WoWTranslate_SetIncomingEnabled(enabled)
    WoWTranslateDB.enabled = enabled
end

-- Set outgoing channel enabled state (called from config UI)
function WoWTranslate_SetChannelEnabled(channel, enabled)
    if not WoWTranslateDB.outgoingChannels then
        WoWTranslateDB.outgoingChannels = {}
    end
    WoWTranslateDB.outgoingChannels[channel] = enabled
end

-- Set incoming channel enabled state (called from config UI)
function WoWTranslate_SetIncomingChannelEnabled(channel, enabled)
    if not WoWTranslateDB.incomingChannels then
        WoWTranslateDB.incomingChannels = {}
    end
    WoWTranslateDB.incomingChannels[channel] = enabled
end

-- ============================================================================
-- SLASH COMMANDS
-- ============================================================================
SLASH_WOWTRANSLATE1 = "/wt"
SLASH_WOWTRANSLATE2 = "/wowtranslate"

SlashCmdList["WOWTRANSLATE"] = function(msg)
    if not WoWTranslateDB then
        WoWTranslateDB = {}
        InitializeSettings()
    end

    local cmd, arg = strsplit(" ", msg, 2)
    cmd = string.lower(cmd or "")

    if cmd == "on" or cmd == "enable" then
        WoWTranslateDB.enabled = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Enabled|r")

    elseif cmd == "off" or cmd == "disable" then
        WoWTranslateDB.enabled = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Disabled|r")

    elseif cmd == "status" then
        local dllStatus = WoWTranslate_API.IsAvailable()
            and "|cFF00FF00Connected|r"
            or "|cFFFF0000Not loaded|r"

        local cacheStats = WoWTranslate_CacheStats()
        local glossaryCount = WoWTranslate_GetGlossaryCount()
        local pendingCount = WoWTranslate_API.GetPendingCount()

        local queuedCount = 0
        for _ in pairs(pendingMessages) do
            queuedCount = queuedCount + 1
        end

        local outgoingQueuedCount = 0
        for _ in pairs(outgoingQueue) do
            outgoingQueuedCount = outgoingQueuedCount + 1
        end

        local outgoingStatus = WoWTranslateDB.outgoingEnabled
            and "|cFF00FF00ON|r"
            or "|cFFFF0000OFF|r"

        local hookStatus = IsOutgoingHookActive()
            and "|cFF00FF00ACTIVE|r"
            or "|cFFFF0000INACTIVE|r"

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Status:")
        DEFAULT_CHAT_FRAME:AddMessage("  DLL: " .. dllStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  Incoming (CN->EN): " .. (WoWTranslateDB.enabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))
        DEFAULT_CHAT_FRAME:AddMessage("  Outgoing (EN->CN): " .. outgoingStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  Outgoing Hook: " .. hookStatus)
        DEFAULT_CHAT_FRAME:AddMessage("  Glossary entries: " .. glossaryCount)
        DEFAULT_CHAT_FRAME:AddMessage("  Cached translations: " .. cacheStats.entries)
        DEFAULT_CHAT_FRAME:AddMessage("  Cache hit rate: " .. string.format("%.1f%%", cacheStats.hitRate))
        DEFAULT_CHAT_FRAME:AddMessage("  Pending API requests: " .. pendingCount)
        DEFAULT_CHAT_FRAME:AddMessage("  Queued incoming: " .. queuedCount)
        DEFAULT_CHAT_FRAME:AddMessage("  Queued outgoing: " .. outgoingQueuedCount)
        local cbErr = WoWTranslate_API.GetLastCallbackError and WoWTranslate_API.GetLastCallbackError()
        if cbErr then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444Last callback error:|r " .. cbErr)
        end
        local rlActive, rlRemaining = WoWTranslate_API.GetRateLimitInfo()
        if rlActive then
            DEFAULT_CHAT_FRAME:AddMessage("  |cFFFF4444API backoff active:|r " .. rlRemaining .. "s remaining (use /wt reset to clear)")
        end

    elseif cmd == "test" then
        local testText = arg or "\228\189\160\229\165\189"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing: " .. testText)

        local cached, found = WoWTranslate_CacheGet(testText)
        if found then
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Cache hit: " .. cached)
            return
        end

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] DLL not available|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Requesting from API...")
        WoWTranslate_API.Translate(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] API result: " .. result)
                WoWTranslate_CacheSave(testText, result)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] API error: " .. (err or "unknown") .. "|r")
            end
        end)

    elseif cmd == "clearcache" then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] Cache cleared|r")

    elseif cmd == "debug" then
        DEBUG_MODE = not DEBUG_MODE
        WoWTranslateDB.debugMode = DEBUG_MODE
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Debug mode: " .. (DEBUG_MODE and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"))

    elseif cmd == "log" then
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Recent log entries:")
        local logs = WoWTranslateDebugLog or {}
        local start = math.max(1, table.getn(logs) - 19)
        for i = start, table.getn(logs) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. logs[i])
        end

    elseif cmd == "clearlog" then
        WoWTranslateDebugLog = {}
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Debug log cleared")

    elseif cmd == "testlink" then
        -- Test hyperlink parsing and localization
        local testMsg = "|cffffffff|Hplayer:TestName|h[TestName]|h|r says hello"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing hyperlink parse:")
        DEFAULT_CHAT_FRAME:AddMessage("  Input: " .. testMsg)
        local segs = SplitIntoSegments(testMsg)
        for idx, seg in ipairs(segs) do
            DEFAULT_CHAT_FRAME:AddMessage("  Seg " .. idx .. " [" .. seg.type .. "]: " .. seg.content)
        end

    elseif cmd == "testitem" then
        -- Test item localization with a known item
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing item localization...")
        local itemId = 2589  -- Default: Linen Cloth (common item)
        if arg and arg ~= "" then
            itemId = tonumber(arg) or 19716
        end
        DEFAULT_CHAT_FRAME:AddMessage("  Item ID: " .. tostring(itemId))
        local itemName = GetItemInfo(itemId)
        if itemName then
            DEFAULT_CHAT_FRAME:AddMessage("  GetItemInfo returned: " .. itemName)
            -- Create a fake Chinese link to test localization
            local testLink = "|cffa335ee|Hitem:" .. itemId .. ":0:0:0|h[测试物品]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  Test link: " .. testLink)
            local localized = LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  Localized: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("  GetItemInfo returned nil - item not in client cache")
            DEFAULT_CHAT_FRAME:AddMessage("  Try: /wt testitem with an item ID you've seen (hover over an item link first)")
        end

    elseif cmd == "testquest" then
        -- Test quest localization using pfQuest database
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing quest localization...")
        local questId = 913  -- Default: Stranglethorn Fever (common quest)
        if arg and arg ~= "" then
            questId = tonumber(arg) or 913
        end
        DEFAULT_CHAT_FRAME:AddMessage("  Quest ID: " .. tostring(questId))

        -- Check if pfQuest database is available
        if not pfDB or not pfDB["quests"] then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  pfQuest database not found!|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Quest localization requires pfQuest addon to be installed")
            return
        end

        local questName = GetEnglishQuestName(questId)
        if questName then
            DEFAULT_CHAT_FRAME:AddMessage("  GetEnglishQuestName returned: " .. questName)
            -- Create a fake Chinese link to test localization
            local testLink = "|cffffff00|Hquest:" .. questId .. ":60|h[测试任务]|h|r"
            DEFAULT_CHAT_FRAME:AddMessage("  Test link: " .. testLink)
            local localized = LocalizeHyperlink(testLink)
            DEFAULT_CHAT_FRAME:AddMessage("  Localized: " .. localized)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000  Quest not found in pfQuest database|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Try: /wt testquest <questId> with a known quest ID")
        end

    -- =====================================================================
    -- OUTGOING TRANSLATION COMMANDS
    -- =====================================================================
    elseif cmd == "outgoing" then
        if arg == "on" or arg == "enable" then
            WoWTranslateDB.outgoingEnabled = true
            InstallOutgoingHook()
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Outgoing translation enabled|r")
            DEFAULT_CHAT_FRAME:AddMessage("  Your English messages will be translated to Chinese")
        elseif arg == "off" or arg == "disable" then
            WoWTranslateDB.outgoingEnabled = false
            RemoveOutgoingHook()
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Outgoing translation disabled|r")
        else
            local status = WoWTranslateDB.outgoingEnabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing translation: " .. status)
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt outgoing on|off")
        end

    elseif cmd == "outchannel" then
        if not WoWTranslateDB.outgoingChannels then
            WoWTranslateDB.outgoingChannels = defaults.outgoingChannels
        end

        if arg and arg ~= "" then
            local channelType = string.upper(arg)
            if WoWTranslateDB.outgoingChannels[channelType] ~= nil then
                WoWTranslateDB.outgoingChannels[channelType] = not WoWTranslateDB.outgoingChannels[channelType]
                local newStatus = WoWTranslateDB.outgoingChannels[channelType] and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
                DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing " .. channelType .. ": " .. newStatus)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Unknown channel: " .. channelType .. "|r")
                DEFAULT_CHAT_FRAME:AddMessage("  Valid channels: WHISPER, PARTY, GUILD, RAID, SAY, YELL, BATTLEGROUND, CHANNEL")
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing channel settings:")
            for channelType, enabled in pairs(WoWTranslateDB.outgoingChannels) do
                local status = enabled and "|cFF00FF00ON|r" or "|cFFFF0000OFF|r"
                DEFAULT_CHAT_FRAME:AddMessage("  " .. channelType .. ": " .. status)
            end
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt outchannel <WHISPER|PARTY|GUILD|RAID|SAY|YELL|BATTLEGROUND|CHANNEL>")
        end

    elseif cmd == "prefix" then
        if arg and arg ~= "" then
            WoWTranslateDB.outgoingPrefix = arg
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Outgoing prefix set to: " .. arg)
        else
            DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Current prefix: " .. (WoWTranslateDB.outgoingPrefix or "[Translated]"))
            DEFAULT_CHAT_FRAME:AddMessage("  Usage: /wt prefix <text>")
        end

    elseif cmd == "testout" then
        local testText = arg or "Hello, how are you?"
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Testing outgoing translation (EN->CN):")
        DEFAULT_CHAT_FRAME:AddMessage("  Input: " .. testText)

        if not WoWTranslate_API.IsAvailable() then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] DLL not available|r")
            return
        end

        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Requesting from API...")
        WoWTranslate_API.TranslateOutgoing(testText, function(result, err)
            if result then
                DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Translation:|r " .. result)
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Error: " .. (err or "unknown") .. "|r")
            end
        end)

    -- =====================================================================
    -- CONFIGURATION UI COMMANDS
    -- =====================================================================
    elseif cmd == "reset" then
        -- Full recovery: re-hook frames (fixes disabled handlers), clear stale API state
        local cleared = WoWTranslate_API.GetPendingCount()
        WoWTranslate_API.ClearPending()
        WoWTranslate_API.ResetBackoff()
        dllWarnShown = false
        translationErrWarnShown = false
        HookChatFrames(true)  -- force re-install all chat frame hooks
        local ok = WoWTranslate_API.CheckDLL()
        if ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Reset OK — hooks reinstalled, DLL responding, cleared " .. cleared .. " stale request(s)|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Reset: hooks reinstalled but DLL not responding — try /reload|r")
        end

    elseif cmd == "hooktest" then
        -- Check whether SetScript("OnEvent") hooks are installed on each chat frame
        local hookedCount = 0
        local totalFrames = 0
        for i = 1, NUM_CHAT_WINDOWS do
            local f = getglobal("ChatFrame" .. i)
            if f then
                totalFrames = totalFrames + 1
                if f.WoWTranslateHooked then
                    hookedCount = hookedCount + 1
                end
            end
        end

        if hookedCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF4444[WT hooktest] NO frames hooked (0/" .. totalFrames .. ")|r")
        elseif hookedCount < totalFrames then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8800[WT hooktest] Partially hooked: " .. hookedCount .. "/" .. totalFrames .. " frames|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WT hooktest] All " .. hookedCount .. "/" .. totalFrames .. " frames hooked via SetScript(OnEvent)|r")
        end
        DEFAULT_CHAT_FRAME:AddMessage("[WT hooktest] Hook call count: " .. tostring(hookCallCount))
        if hookCallCount == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8800[WT hooktest] Count=0: hook installed but no events fired yet (or all events filtered)|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WT hooktest] Hook is firing correctly|r")
        end

    elseif cmd == "show" or cmd == "config" or cmd == "options" then
        if WoWTranslate_ShowConfig then
            WoWTranslate_ShowConfig()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[WoWTranslate] Config UI failed to load — check for Lua errors in WoWTranslate_Config.lua|r")
        end

    elseif cmd == "hide" then
        WoWTranslate_HideConfig()

    else
        DEFAULT_CHAT_FRAME:AddMessage("[WoWTranslate] Commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt show - Open configuration panel")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt hide - Close configuration panel")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt on|off - Enable/disable incoming translation")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt status - Show status")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt reset - Recover if translations stop after alt-tab")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt clearcache - Clear cache")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt debug - Toggle debug mode")
        DEFAULT_CHAT_FRAME:AddMessage("  -- Outgoing --")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt outgoing on|off - Toggle outgoing translation")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt outchannel [type] - Show/toggle channel settings")
        DEFAULT_CHAT_FRAME:AddMessage("  /wt prefix <text> - Set message prefix")
    end
end

-- ============================================================================
-- ADDON INITIALIZATION
-- ============================================================================
local function InitializeSettings()
    if not WoWTranslateDB then WoWTranslateDB = {} end
    if not WoWTranslateDebugLog then WoWTranslateDebugLog = {} end
    if type(WoWTranslateCache) ~= "table" then WoWTranslateCache = {} end

    for key, value in pairs(defaults) do
        if WoWTranslateDB[key] == nil then
            WoWTranslateDB[key] = value
        end
    end

    -- Migration: fix old short prefix to new full prefix
    if WoWTranslateDB.outgoingPrefix == "[Translated]" then
        WoWTranslateDB.outgoingPrefix = "[Translated by WoWTranslate]"
    end

    -- Migration: add BATTLEGROUND/CHANNEL/HARDCORE to existing outgoingChannels
    if WoWTranslateDB.outgoingChannels then
        if WoWTranslateDB.outgoingChannels.BATTLEGROUND == nil then
            WoWTranslateDB.outgoingChannels.BATTLEGROUND = true
        end
        if WoWTranslateDB.outgoingChannels.CHANNEL == nil then
            WoWTranslateDB.outgoingChannels.CHANNEL = true
        end
        if WoWTranslateDB.outgoingChannels.HARDCORE == nil then
            WoWTranslateDB.outgoingChannels.HARDCORE = false
        end
        if WoWTranslateDB.outgoingChannels.ENGLISH == nil then
            WoWTranslateDB.outgoingChannels.ENGLISH = false
        end
    end

    -- Migration: create incomingChannels if it doesn't exist
    if not WoWTranslateDB.incomingChannels then
        WoWTranslateDB.incomingChannels = {}
        for k, v in pairs(defaults.incomingChannels) do
            WoWTranslateDB.incomingChannels[k] = v
        end
    end
    if WoWTranslateDB.incomingChannels.HARDCORE == nil then
        WoWTranslateDB.incomingChannels.HARDCORE = false
    end
    if WoWTranslateDB.incomingChannels.ENGLISH == nil then
        WoWTranslateDB.incomingChannels.ENGLISH = false
    end

    if WoWTranslateDB.translationColorFollow == nil then
        WoWTranslateDB.translationColorFollow = false
    end

    DEBUG_MODE = WoWTranslateDB.debugMode or false

    -- Migrate: remove old apiKey and incomingFromLang fields
    WoWTranslateDB.apiKey = nil
    WoWTranslateDB.incomingFromLang = nil

    -- Migrate: add enabledSourceLangs if missing
    if WoWTranslateDB.enabledSourceLangs == nil then
        WoWTranslateDB.enabledSourceLangs = { zh=true, ja=true, ko=true, ru=true }
    end
    if WoWTranslateDB.enabledSourceLangs.en == nil then
        WoWTranslateDB.enabledSourceLangs.en = false
    end

    if WoWTranslateDB.nameplateShortNames == nil then
        WoWTranslateDB.nameplateShortNames = false
    end
    if WoWTranslateDB.nameplateHideHealthOOC == nil then
        WoWTranslateDB.nameplateHideHealthOOC = false
    end
    if WoWTranslateDB.nameplateGuildOOC == nil then
        WoWTranslateDB.nameplateGuildOOC = false
    end
    if WoWTranslateDB.nameplateAutoscaleNames == nil then
        WoWTranslateDB.nameplateAutoscaleNames = false
    end
    if WoWTranslateDB.nameplateAutoscaleNamesRatio == nil then
        WoWTranslateDB.nameplateAutoscaleNamesRatio = 0.5
    end
    if WoWTranslateDB.nameplateAutoscaleGuild == nil then
        WoWTranslateDB.nameplateAutoscaleGuild = false
    end
    if WoWTranslateDB.nameplateAutoscaleGuildRatio == nil then
        WoWTranslateDB.nameplateAutoscaleGuildRatio = 0.5
    end
    if WoWTranslateDB.nameplateAutoscaleNamesScale == nil then
        WoWTranslateDB.nameplateAutoscaleNamesScale = 1
    else
        local ns = tonumber(WoWTranslateDB.nameplateAutoscaleNamesScale)
        if ns and (ns < 0.33 or ns > 1.5) then
            if ns >= -1 and ns <= 1 then
                ns = AutoscaleSizeMultiplier(ns)
            else
                ns = 1
            end
            if ns < 0.33 then ns = 0.33 elseif ns > 1.5 then ns = 1.5 end
            WoWTranslateDB.nameplateAutoscaleNamesScale = math.floor(ns * 100 + 0.5) / 100
        end
    end
    if WoWTranslateDB.nameplatePlayerNameScale == nil then
        WoWTranslateDB.nameplatePlayerNameScale = 1
    end
    if WoWTranslateDB.nameplateTargetNameScale == nil then
        WoWTranslateDB.nameplateTargetNameScale = 1
    end
    if WoWTranslateDB.nameplateAutoscaleGuildScale == nil then
        WoWTranslateDB.nameplateAutoscaleGuildScale = 1
    end
    if WoWTranslateDB.nameplateNameColor == nil then
        WoWTranslateDB.nameplateNameColor = ""
    end
    if WoWTranslateDB.nameplateGuildColor == nil then
        WoWTranslateDB.nameplateGuildColor = ""
    end
    if WoWTranslateDB.playerNameClassColor == nil then
        WoWTranslateDB.playerNameClassColor = true
    end

    if WoWTranslateDB.translatePlayerNames == nil then
        WoWTranslateDB.translatePlayerNames = false
    end
    if WoWTranslateDB.translateGuildNames == nil then
        WoWTranslateDB.translateGuildNames = false
    end
    if WoWTranslateDB.translateNameplates == nil then
        WoWTranslateDB.translateNameplates = false
    end
    if WoWTranslateDB.outgoingButtonPos == nil then
        WoWTranslateDB.outgoingButtonPos = { x = 100, y = 100 }
    end
end

local function OnAddonLoaded()
    if addonLoaded then return end
    addonLoaded = true

    InitializeSettings()
    -- Chat hooks must run before nameplate hooks (nameplate init must not wrap AddMessage).
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        HookChatFrames()
    end
    HookTooltips()
    CreateOutgoingButton()

    if WoWTranslate_MinimapButton_Init then
        pcall(WoWTranslate_MinimapButton_Init)
    end

    local dllOk = WoWTranslate_API.CheckDLL()

    local glossaryCount = WoWTranslate_GetGlossaryCount()
    local cacheCount = WoWTranslate_CacheStats().entries
    local dllStatus = dllOk and "|cFF00FF00DLL OK|r" or "|cFFFFFF00DLL not loaded|r"

    DEFAULT_CHAT_FRAME:AddMessage("|cFF00CCFFWoWTranslate|r v1.3 - " .. dllStatus .. " | /wt show")
end

-- ============================================================================
-- PLAYER NAME TRANSLATION (Shift+RightClick on a chat name)
-- ============================================================================
-- Wraps ChatFrame_OnHyperlinkShow.  When the user Shift+RightClicks a player
-- link we translate the name and print "[WT]: Name = Translation".
-- If Translate() can't queue (rate limited / DLL busy) we fall through so the
-- normal right-click context menu still opens — no silent failures.
local function HookHyperlinkShow()
    local origHyperlink = ChatFrame_OnHyperlinkShow
    if not origHyperlink then return end

    ChatFrame_OnHyperlinkShow = function(link, text, button)
        local capturedFrame = this
        if button == "RightButton" and IsShiftKeyDown() then
            -- link format is "player:CharacterName"
            local _, _, playerName = string.find(link, "^player:(.+)")
            if playerName and playerName ~= ""
               and WoWTranslate_API and WoWTranslate_API.IsAvailable() then
                local sent = WoWTranslate_API.Translate(playerName,
                    function(translation, err)
                        local frame = capturedFrame or DEFAULT_CHAT_FRAME
                        if translation and translation ~= "" and translation ~= playerName then
                            frame:AddMessage("|cFF00CCFF[WT]|r: " .. playerName .. " = " .. translation)
                        elseif err then
                            frame:AddMessage("|cFFFFFF00[WT]: name lookup failed: " .. tostring(err) .. "|r")
                        end
                        -- translation == playerName means no change (already target language)
                    end, "auto")
                if sent then return end
                -- Translate() returned false: rate limited or queue full — fall through
            end
        end
        origHyperlink(link, text, button)
    end
end

local function OnPlayerLogin()
    HookChatFrames()
    HookTooltips()
    HookHyperlinkShow()
    InstallWIMHook()
    InstallFriendsListHook()

    if not WoWTranslate_API.IsAvailable() then
        WoWTranslate_API.CheckDLL()
    end

    -- Install outgoing hook if enabled
    if WoWTranslateDB and WoWTranslateDB.outgoingEnabled then
        InstallOutgoingHook()
    end

end

-- ============================================================================
-- EVENT FRAME
-- ============================================================================
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

local function ClearTargetUnitCache()
    wtCachedTargetUnit = nil
    wtCachedTargetCheckTime = 0
end

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "WoWTranslate" then
        OnAddonLoaded()
    elseif event == "PLAYER_LOGIN" then
        OnPlayerLogin()
    elseif event == "ADDON_LOADED" and arg1 == "WIM" then
        InstallWIMHook()
    elseif event == "ADDON_LOADED" and arg1 == "ShaguTweaks" then
        if HookNameplates then
            HookNameplates()
        end
        InstallFriendsListHook()
    elseif event == "ADDON_LOADED" and arg1 == "ShaguPlates" then
        if HookNameplates then
            HookNameplates()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Re-check DLL after any loading screen (zone in, /reload, etc.)
        if not WoWTranslate_API.IsAvailable() then
            WoWTranslate_API.CheckDLL()
        end
        wtCachedTargetUnit = nil
        wtCachedTargetCheckTime = 0
        wtHadTargetUnit = (GetSafeTargetUnitToken() ~= nil)
        ResetNameplateScanner()
        HookNameplates()
    elseif event == "PLAYER_FLAGS_CHANGED" and arg1 == "player" then
        if UnitIsAFK then
            playerIsAFK = (UnitIsAFK("player") == 1) or (UnitIsAFK("player") == true)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        if arg1 and string.find(arg1, "You are now AFK") then
            playerIsAFK = true
        elseif arg1 and string.find(arg1, "You are no longer AFK") then
            playerIsAFK = false
        end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        if WoWTranslate_RefreshAllNameplateHealthbars then
            WoWTranslate_RefreshAllNameplateHealthbars()
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        ClearTargetUnitCache()
        if WoWTranslate_OnTargetChanged then
            WoWTranslate_OnTargetChanged()
        end
    end
end)

local cleanupFrame = CreateFrame("Frame")
local cleanupElapsed = 0
cleanupFrame:SetScript("OnUpdate", function()
    cleanupElapsed = cleanupElapsed + arg1
    if cleanupElapsed >= 5 then
        cleanupElapsed = 0
        CleanupPendingMessages()
        CleanupOutgoingQueue()
        CleanupWIMState()
        CleanupPendingNameTranslations()
        if WoWTranslate_CleanupPendingTooltipTranslations then
            WoWTranslate_CleanupPendingTooltipTranslations()
        end
    end
end)

-- Watchdog: WoW 1.12 replaces SetScript("OnEvent") handlers on chat frames when
-- certain events fire (channel join, zone change, UPDATE_CHAT_WINDOWS, etc.).
-- Re-install our wrappers every 60s so hooks stay active after such events.
-- pcall prevents a HookChatFrames error from silently killing this OnUpdate.
local hookWatchdogElapsed = 0
local hookWatchdogFrame = CreateFrame("Frame")
hookWatchdogFrame:SetScript("OnUpdate", function()
    hookWatchdogElapsed = hookWatchdogElapsed + arg1
    if hookWatchdogElapsed >= 60 then
        hookWatchdogElapsed = 0
        pcall(HookChatFrames, true)
    end
end)

-- ============================================================================
-- ITEM CACHE POLLING
-- ============================================================================
-- Process messages waiting for item cache data

local function ProcessItemCacheMessage(queued)
    local text = queued.text
    local detectedLang = DetectSourceLanguage(text) or "zh"

    -- Split header from body (same approach as the main hook)
    local headerText, msgBody = SplitHeaderAndMessage(text)

    -- Segment only the message body
    local segments = SplitIntoSegments(msgBody)

    DebugLog("Processing cached item message, segments:", table.getn(segments))

    if not HasTranslatableContent(segments) then
        -- Body has no translatable content; show with localized hyperlinks
        local result = headerText
        for _, seg in ipairs(segments) do
            result = result .. seg.content
        end
        queued.originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    local textToTranslate = BuildTranslatableText(segments)

    local cached, found = WoWTranslate_CacheGet(msgBody)
    if found then
        DebugLog("Cache hit for item message")
        local finalText = headerText .. ReconstructMessage(segments, cached)
        queued.originalAddMessage(queued.frame, finalText, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
        return
    end

    if WoWTranslate_API and WoWTranslate_API.IsAvailable() then
        DebugLog("Requesting translation for item message")
        messageCounter = messageCounter + 1
        local msgId = tostring(messageCounter)
        pendingMessages[msgId] = {
            frame = queued.frame,
            originalAddMessage = queued.originalAddMessage,
            originalText = text,
            headerText = headerText,
            msgBody = msgBody,
            segments = segments,
            r = queued.r, g = queued.g, b = queued.b,
            id = queued.id, holdTime = queued.holdTime,
            timestamp = GetTime()
        }
        WoWTranslate_API.Translate(textToTranslate, function(translation, err)
            local pending = pendingMessages[msgId]
            if pending then
                pendingMessages[msgId] = nil
                if translation and translation ~= "" then
                    DebugLog("API returned for item msg:", string.sub(translation, 1, 50))
                    local finalText = pending.headerText .. ReconstructMessage(pending.segments, translation)
                    WoWTranslate_CacheSave(pending.msgBody, translation)
                    pcall(pending.originalAddMessage, pending.frame, finalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                else
                    DebugLog("API error for item msg:", tostring(err))
                    pcall(pending.originalAddMessage, pending.frame, pending.originalText, pending.r, pending.g, pending.b, pending.id, pending.holdTime)
                end
            end
        end, detectedLang)
    else
        local result = headerText
        for _, seg in ipairs(segments) do result = result .. seg.content end
        queued.originalAddMessage(queued.frame, result, queued.r, queued.g, queued.b, queued.id, queued.holdTime)
    end
end

local itemCacheFrame = CreateFrame("Frame")
local itemCacheElapsed = 0
local ITEM_CACHE_POLL_INTERVAL = 0.05  -- Poll every 50ms
local ITEM_CACHE_MAX_WAIT = 3.0        -- Max wait 3 seconds
local ITEM_CACHE_RETRY_INTERVAL = 0.5  -- Retry triggering cache every 500ms

itemCacheFrame:SetScript("OnUpdate", function()
    itemCacheElapsed = itemCacheElapsed + arg1
    if itemCacheElapsed < ITEM_CACHE_POLL_INTERVAL then
        return
    end
    itemCacheElapsed = 0

    for cacheId, queued in pairs(itemCacheQueue) do
        local allCached = CheckItemCache(queued.itemIds, false)  -- Just check, don't trigger
        local elapsed = GetTime() - queued.timestamp

        if allCached then
            DebugLog("Items cached, processing message:", cacheId)
            itemCacheQueue[cacheId] = nil
            ProcessItemCacheMessage(queued)
        elseif elapsed > ITEM_CACHE_MAX_WAIT then
            -- Timeout - process anyway with whatever we have
            local _, stillUncached = CheckItemCache(queued.itemIds, false)
            DebugLog("Item cache timeout after", elapsed, "sec, uncached:", table.getn(stillUncached))
            for _, uid in ipairs(stillUncached) do
                DebugLog("  Still uncached item ID:", uid)
            end
            itemCacheQueue[cacheId] = nil
            ProcessItemCacheMessage(queued)
        else
            -- Retry triggering cache periodically for stubborn items
            if not queued.lastRetry or (GetTime() - queued.lastRetry) > ITEM_CACHE_RETRY_INTERVAL then
                queued.lastRetry = GetTime()
                queued.retries = (queued.retries or 0) + 1
                if queued.retries <= 5 then  -- Max 5 retries
                    local _, stillUncached = CheckItemCache(queued.itemIds, true)  -- Trigger cache again
                    if table.getn(stillUncached) > 0 then
                        DebugLog("Retry", queued.retries, "- triggering cache for", table.getn(stillUncached), "items")
                    end
                end
            end
        end
    end
end)
