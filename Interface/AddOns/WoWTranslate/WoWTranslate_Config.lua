-- WoWTranslate_Config.lua
-- Configuration UI panel for WoWTranslate
-- v0.13: Removed API key/credits UI; added source language checkboxes

-- ============================================================================
-- LANGUAGES
-- ============================================================================
local LANGUAGES = {
    { code = "zh", name = "Chinese" },
    { code = "en", name = "English" },
    { code = "ko", name = "Korean" },
    { code = "ja", name = "Japanese" },
    { code = "ru", name = "Russian" },
    { code = "de", name = "German" },
    { code = "fr", name = "French" },
    { code = "es", name = "Spanish" },
    { code = "pt", name = "Portuguese" },
}

local function GetLanguageIndex(code)
    for i = 1, table.getn(LANGUAGES) do
        if LANGUAGES[i].code == code then
            return i
        end
    end
    return 1
end

local function GetLanguageName(code)
    for i = 1, table.getn(LANGUAGES) do
        if LANGUAGES[i].code == code then
            return LANGUAGES[i].name
        end
    end
    return code
end

-- ============================================================================
-- TEMP CONFIG
-- ============================================================================
WoWTranslate_TempConfig = {}

local function ConfigKeyAffectsNameplates(key)
    if not key then return false end
    if string.find(key, "^nameplate") then return true end
    if key == "playerNameClassColor" or key == "translateNameplates" or key == "disableWhileAfk" then
        return true
    end
    return false
end

local function RefreshNameplatesNow(configKey)
    if configKey and not ConfigKeyAffectsNameplates(configKey) then return end
    if WoWTranslate_RefreshNameplateColors then
        WoWTranslate_RefreshNameplateColors()
    end
end

local function LoadTempConfig()
    WoWTranslate_TempConfig = {}
    if not WoWTranslateDB then return end
    for k, v in pairs(WoWTranslateDB) do
        if type(v) == "table" then
            WoWTranslate_TempConfig[k] = {}
            for k2, v2 in pairs(v) do
                WoWTranslate_TempConfig[k][k2] = v2
            end
        else
            WoWTranslate_TempConfig[k] = v
        end
    end
end

local function SaveTempConfig()
    if not WoWTranslate_TempConfig then return end
    for k, v in pairs(WoWTranslate_TempConfig) do
        if type(v) == "table" then
            if not WoWTranslateDB[k] then
                WoWTranslateDB[k] = {}
            end
            for k2, v2 in pairs(v) do
                WoWTranslateDB[k][k2] = v2
            end
        else
            WoWTranslateDB[k] = v
        end
    end
end

-- ============================================================================
-- CREATE MAIN FRAME
-- ============================================================================
local PANEL_W = 408
local PANEL_GAP = 14
local FRAME_W = 24 + PANEL_W + PANEL_GAP + PANEL_W + 24
local FRAME_H = 672

local configFrame = CreateFrame("Frame", "WoWTranslateConfigFrame", UIParent)
configFrame:Hide()
configFrame:SetWidth(FRAME_W)
configFrame:SetHeight(FRAME_H)
configFrame:SetPoint("CENTER", 0, 0)
configFrame:SetMovable(true)
configFrame:EnableMouse(true)
configFrame:SetClampedToScreen(true)
configFrame:SetFrameStrata("DIALOG")

configFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true,
    tileSize = 32,
    edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
configFrame:SetBackdropColor(0, 0, 0, 1)

configFrame:SetScript("OnMouseDown", function()
    this:StartMoving()
end)

configFrame:SetScript("OnMouseUp", function()
    this:StopMovingOrSizing()
end)

-- Title
local title = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOP", configFrame, "TOP", 0, -20)
title:SetText("WoWTranslate Configuration")

-- Close button
local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", configFrame, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
    configFrame:Hide()
end)

-- ESC to close
tinsert(UISpecialFrames, "WoWTranslateConfigFrame")

-- ============================================================================
-- UI ELEMENTS STORAGE
-- ============================================================================
configFrame.elements = {}

local leftPanel = CreateFrame("Frame", nil, configFrame)
leftPanel:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 20, -46)
leftPanel:SetWidth(PANEL_W)
leftPanel:SetHeight(FRAME_H - 110)

local rightPanel = CreateFrame("Frame", nil, configFrame)
rightPanel:SetPoint("TOPLEFT", leftPanel, "TOPRIGHT", PANEL_GAP, 0)
rightPanel:SetWidth(PANEL_W)
rightPanel:SetHeight(FRAME_H - 110)

local panelDivider = configFrame:CreateTexture(nil, "ARTWORK")
panelDivider:SetTexture(1, 1, 1, 0.12)
panelDivider:SetWidth(1)
panelDivider:SetPoint("TOP", leftPanel, "TOPRIGHT", PANEL_GAP / 2, 4)
panelDivider:SetPoint("BOTTOM", leftPanel, "BOTTOMRIGHT", PANEL_GAP / 2, -4)

-- ============================================================================
-- HELPER: Create Section Header
-- ============================================================================
local function CreateHeader(parent, text, yPos)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yPos)
    header:SetText(text)
    header:SetTextColor(1, 0.82, 0)
    return header
end

local function CreateRedHeader(parent, text, yPos)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yPos)
    header:SetText(text)
    header:SetTextColor(1, 0, 0)
    return header
end

-- ============================================================================
-- HELPER: Create Checkbox at specific position
-- ============================================================================
local function CreateCheckbox(parent, label, xPos, yPos, configKey, subKey, labelR, labelG, labelB)
    local wrapper = CreateFrame("Frame", nil, parent)
    wrapper:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, yPos)
    wrapper:SetWidth(195)
    wrapper:SetHeight(22)

    -- Store config on wrapper (same pattern as language selector)
    wrapper.configKey = configKey
    wrapper.subKey = subKey

    local cb = CreateFrame("CheckButton", nil, wrapper, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", 0, 0)

    local fontObj = (labelR and labelG and labelB) and "GameFontNormalLarge" or "GameFontNormal"
    local text = wrapper:CreateFontString(nil, "ARTWORK", fontObj)
    text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    text:SetText(label)
    if labelR and labelG and labelB then
        text:SetTextColor(labelR, labelG, labelB)
    end

    cb:SetScript("OnClick", function()
        -- Use GetParent() like language selector does
        local parent = this:GetParent()
        local key = parent.configKey
        local sub = parent.subKey

        -- GetChecked() returns 1 or nil in WoW 1.12
        local isChecked = this:GetChecked()
        local enabled = (isChecked and true) or false

        -- Use the global toggle functions for immediate effect
        if key == "outgoingEnabled" then
            WoWTranslate_SetOutgoingEnabled(enabled)
            WoWTranslate_TempConfig.outgoingEnabled = enabled
        elseif key == "enabled" then
            WoWTranslate_SetIncomingEnabled(enabled)
            WoWTranslate_TempConfig.enabled = enabled
        elseif key == "translateNameplates" then
            WoWTranslate_SetTranslateNameplates(enabled)
            WoWTranslate_TempConfig.translateNameplates = enabled
        elseif key == "translatePlayerNames" then
            WoWTranslate_SetTranslatePlayerNames(enabled)
            WoWTranslate_TempConfig.translatePlayerNames = enabled
        elseif key == "translateGuildNames" then
            WoWTranslate_SetTranslateGuildNames(enabled)
            WoWTranslate_TempConfig.translateGuildNames = enabled
        elseif key == "playerNameClassColor" then
            WoWTranslate_TempConfig.playerNameClassColor = enabled
            if WoWTranslateDB then
                WoWTranslateDB.playerNameClassColor = enabled
            end
        elseif key == "outgoingChannels" and sub then
            WoWTranslate_SetChannelEnabled(sub, enabled)
            if not WoWTranslate_TempConfig.outgoingChannels then
                WoWTranslate_TempConfig.outgoingChannels = {}
            end
            WoWTranslate_TempConfig.outgoingChannels[sub] = enabled
        elseif key == "incomingChannels" and sub then
            WoWTranslate_SetIncomingChannelEnabled(sub, enabled)
            if not WoWTranslate_TempConfig.incomingChannels then
                WoWTranslate_TempConfig.incomingChannels = {}
            end
            WoWTranslate_TempConfig.incomingChannels[sub] = enabled
        else
            -- Fallback for any other settings
            if sub then
                if not WoWTranslate_TempConfig[key] then
                    WoWTranslate_TempConfig[key] = {}
                end
                WoWTranslate_TempConfig[key][sub] = enabled
                if not WoWTranslateDB[key] then
                    WoWTranslateDB[key] = {}
                end
                WoWTranslateDB[key][sub] = enabled
            else
                WoWTranslate_TempConfig[key] = enabled
                WoWTranslateDB[key] = enabled
            end
        end
        RefreshNameplatesNow(key)
    end)

    -- Return the checkbox (not wrapper) so SetChecked works
    cb.wrapper = wrapper
    return cb
end

-- ============================================================================
-- HELPER: Create autoscale amount slider (-2 .. 2x)
-- ============================================================================
local function CreateScaleSlider(parent, label, xPos, yPos, configKey, minV, maxV, directDisplay, valueStep, ratioDisplay)
    minV = minV or -1
    maxV = maxV or 1
    valueStep = valueStep or 0.1
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, yPos)
    frame:SetWidth(390)
    frame:SetHeight(36)

    local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)

    local sliderName = "WoWTranslateScale_" .. configKey
    local slider = CreateFrame("Slider", sliderName, frame, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, -14)
    slider:SetWidth(250)
    slider:SetHeight(16)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(valueStep)
    slider:EnableMouseWheel(true)

    local lowText = getglobal(sliderName .. "Low")
    local highText = getglobal(sliderName .. "High")
    local titleText = getglobal(sliderName .. "Text")
    if lowText and lowText.Hide then lowText:Hide() end
    if highText and highText.Hide then highText:Hide() end
    if titleText and titleText.Hide then titleText:Hide() end

    local valueText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    valueText:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    valueText:SetWidth(48)
    valueText:SetJustifyH("RIGHT")

    local function ApplyScaleValue(val)
        val = tonumber(val) or 1
        if val < minV then val = minV elseif val > maxV then val = maxV end
        val = math.floor(val * 100 + 0.5) / 100
        local displayMult = val
        if ratioDisplay then
            displayMult = val
        elseif directDisplay then
            if configKey == "nameplateAutoscaleNamesScale" and WoWTranslate_GetNameAutoscaleSizeMultiplier then
                displayMult = WoWTranslate_GetNameAutoscaleSizeMultiplier(val)
            elseif configKey == "nameplateTargetNameScale" and WoWTranslate_GetTargetNameplateScale then
                displayMult = WoWTranslate_GetTargetNameplateScale(val)
            elseif WoWTranslate_GetPlayerNameplateScale then
                displayMult = WoWTranslate_GetPlayerNameplateScale(val)
            end
        elseif WoWTranslate_GetAutoscaleSizeMultiplier then
            displayMult = WoWTranslate_GetAutoscaleSizeMultiplier(val)
        end
        if ratioDisplay then
            valueText:SetText(string.format("%.2f", displayMult))
        else
            valueText:SetText(string.format("%.2fx", displayMult))
        end
        WoWTranslate_TempConfig[configKey] = val
        if WoWTranslateDB then
            WoWTranslateDB[configKey] = val
        end
        RefreshNameplatesNow(configKey)
        return val
    end

    slider:SetScript("OnValueChanged", function()
        ApplyScaleValue(this:GetValue())
    end)

    slider:SetScript("OnMouseWheel", function()
        local step = valueStep
        local v = this:GetValue()
        if arg1 and arg1 > 0 then
            v = math.min(maxV, v + step)
        else
            v = math.max(minV, v - step)
        end
        this:SetValue(ApplyScaleValue(v))
    end)

    frame.slider = slider
    frame.valueText = valueText
    frame.configKey = configKey
    frame.SetScaleValue = function(val)
        val = ApplyScaleValue(val)
        slider:SetValue(val)
    end

    return frame
end

-- ============================================================================
-- HELPER: Nameplate base color picker (oPatch / Shagu plates)
-- ============================================================================
local function CreatePlateColorPicker(parent, label, xPos, yPos, configKey, defaultR, defaultG, defaultB)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, yPos)
    row:SetWidth(390)
    row:SetHeight(20)

    local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetText(label)

    local swatch = CreateFrame("Button", nil, row)
    swatch:SetWidth(30)
    swatch:SetHeight(18)
    swatch:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    swatch:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile     = true, tileSize = 8, edgeSize  = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    swatch:SetBackdropBorderColor(0, 0, 0)

    local clickLbl = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    clickLbl:SetPoint("LEFT", swatch, "RIGHT", 4, 0)
    clickLbl:SetText("(click)")

    local defaultBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    defaultBtn:SetWidth(55)
    defaultBtn:SetHeight(18)
    defaultBtn:SetPoint("LEFT", swatch, "RIGHT", 52, 0)
    defaultBtn:SetText("Default")

    local function UpdateSwatch(hex)
        if hex and string.len(hex) == 6 then
            local r = tonumber(string.sub(hex, 1, 2), 16) / 255
            local g = tonumber(string.sub(hex, 3, 4), 16) / 255
            local b = tonumber(string.sub(hex, 5, 6), 16) / 255
            swatch:SetBackdropColor(r, g, b)
        else
            swatch:SetBackdropColor(defaultR, defaultG, defaultB)
        end
    end

    local function ApplyHex(hex)
        hex = hex or ""
        WoWTranslate_TempConfig[configKey] = hex
        if WoWTranslateDB then
            WoWTranslateDB[configKey] = hex
        end
        UpdateSwatch(hex)
        RefreshNameplatesNow(configKey)
    end

    swatch:SetScript("OnClick", function()
        local hex = (WoWTranslate_TempConfig[configKey]) or ""
        local r, g, b = defaultR, defaultG, defaultB
        if hex and string.len(hex) == 6 then
            r = tonumber(string.sub(hex, 1, 2), 16) / 255
            g = tonumber(string.sub(hex, 3, 4), 16) / 255
            b = tonumber(string.sub(hex, 5, 6), 16) / 255
        end
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.func = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            local nhex = string.format("%02X%02X%02X",
                math.floor(nr * 255), math.floor(ng * 255), math.floor(nb * 255))
            ApplyHex(nhex)
        end
        ColorPickerFrame.cancelFunc = function(pv)
            local pr, pg, pb = pv[1], pv[2], pv[3]
            local phex = string.format("%02X%02X%02X",
                math.floor(pr * 255), math.floor(pg * 255), math.floor(pb * 255))
            ApplyHex(phex)
        end
        ColorPickerFrame.previousValues = { r, g, b }
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        ShowUIPanel(ColorPickerFrame)
    end)

    defaultBtn:SetScript("OnClick", function()
        ApplyHex("")
    end)

    row.swatch = swatch
    row.SetColorHex = ApplyHex
    row.UpdateSwatch = UpdateSwatch
    return row
end

-- ============================================================================
-- HELPER: Create Language Selector
-- ============================================================================
local function CreateLangSelector(parent, label, xPos, yPos, configKey)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, yPos)
    frame:SetWidth(170)
    frame:SetHeight(50)

    local lbl = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 0, 0)
    lbl:SetText(label)

    local leftBtn = CreateFrame("Button", nil, frame)
    leftBtn:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)
    leftBtn:SetWidth(24)
    leftBtn:SetHeight(24)
    leftBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
    leftBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
    leftBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    local display = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    display:SetPoint("LEFT", leftBtn, "RIGHT", 10, 0)
    display:SetWidth(85)
    display:SetJustifyH("CENTER")
    display:SetText("Language")

    local rightBtn = CreateFrame("Button", nil, frame)
    rightBtn:SetPoint("LEFT", display, "RIGHT", 10, 0)
    rightBtn:SetWidth(24)
    rightBtn:SetHeight(24)
    rightBtn:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    rightBtn:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    rightBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    frame.display = display
    frame.configKey = configKey

    leftBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        local code = WoWTranslate_TempConfig[parent.configKey] or "zh"
        local idx = GetLanguageIndex(code) - 1
        if idx < 1 then idx = table.getn(LANGUAGES) end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    rightBtn:SetScript("OnClick", function()
        local parent = this:GetParent()
        local code = WoWTranslate_TempConfig[parent.configKey] or "zh"
        local idx = GetLanguageIndex(code) + 1
        if idx > table.getn(LANGUAGES) then idx = 1 end
        WoWTranslate_TempConfig[parent.configKey] = LANGUAGES[idx].code
        parent.display:SetText(LANGUAGES[idx].name)
    end)

    return frame
end

-- ============================================================================
-- BUILD UI — left: incoming, right: outgoing + display options
-- ============================================================================

-- ---- LEFT PANEL: Incoming ----
CreateHeader(leftPanel, "Incoming (Chat -> You)", -8)
configFrame.elements.inEnabled = CreateCheckbox(leftPanel, "Enable Incoming", 8, -34, "enabled", nil)
configFrame.elements.afkDisable = CreateCheckbox(leftPanel, "Disable while AFK", 210, -34, "disableWhileAfk", nil)
configFrame.elements.translateSystem = CreateCheckbox(leftPanel, "Translate system/emotes", 8, -58, "translateSystemMessages", nil)
configFrame.elements.inTo = CreateLangSelector(leftPanel, "To:", 8, -82, "incomingToLang")

local roleInfoText = leftPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
roleInfoText:SetPoint("TOPRIGHT", leftPanel, "TOPRIGHT", -4, -113)
roleInfoText:SetText("T=tank N=heal D=dps")
roleInfoText:SetTextColor(0.2, 1, 0.2)
roleInfoText:SetFont("Fonts\\FRIZQT__.TTF", 9, "ITALIC")

local srcLabel = leftPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
srcLabel:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 8, -118)
srcLabel:SetText("Translate incoming from:")

configFrame.elements.srcZH = CreateCheckbox(leftPanel, "Chinese",  8,   -142, "enabledSourceLangs", "zh")
configFrame.elements.srcJA = CreateCheckbox(leftPanel, "Japanese", 108, -142, "enabledSourceLangs", "ja")
configFrame.elements.srcKO = CreateCheckbox(leftPanel, "Korean",   208, -142, "enabledSourceLangs", "ko")
configFrame.elements.srcRU = CreateCheckbox(leftPanel, "Russian",  308, -142, "enabledSourceLangs", "ru")
configFrame.elements.srcEN = CreateCheckbox(leftPanel, "English",  8,   -166, "enabledSourceLangs", "en")

local inChLabel = leftPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
inChLabel:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 8, -196)
inChLabel:SetText("Incoming channels:")

configFrame.elements.inChSay = CreateCheckbox(leftPanel, "Say", 8, -218, "incomingChannels", "SAY")
configFrame.elements.inChYell = CreateCheckbox(leftPanel, "Yell", 108, -218, "incomingChannels", "YELL")
configFrame.elements.inChWhisper = CreateCheckbox(leftPanel, "Whisper", 208, -218, "incomingChannels", "WHISPER")
configFrame.elements.inChParty = CreateCheckbox(leftPanel, "Party", 308, -218, "incomingChannels", "PARTY")

configFrame.elements.inChGuild = CreateCheckbox(leftPanel, "Guild", 8, -242, "incomingChannels", "GUILD")
configFrame.elements.inChRaid = CreateCheckbox(leftPanel, "Raid", 108, -242, "incomingChannels", "RAID")
configFrame.elements.inChEnglish = CreateCheckbox(leftPanel, "English", 208, -242, "incomingChannels", "ENGLISH")
configFrame.elements.inChBG = CreateCheckbox(leftPanel, "BG", 308, -242, "incomingChannels", "BATTLEGROUND")

configFrame.elements.inChChannel = CreateCheckbox(leftPanel, "World/Local", 8, -266, "incomingChannels", "CHANNEL")
configFrame.elements.inChHC = CreateCheckbox(leftPanel, "Hardcore", 208, -266, "incomingChannels", "HARDCORE")

CreateHeader(leftPanel, "Name Translation", -292)
configFrame.elements.translateNames = CreateCheckbox(leftPanel, "Sender names", 8, -318, "translatePlayerNames", nil)
configFrame.elements.translateGuilds = CreateCheckbox(leftPanel, "Guild (tooltip)", 210, -318, "translateGuildNames", nil)

-- oPatch (left): nameplate name options (OPATCH_Y less negative = higher on screen)
local OPATCH_Y = -374

local opatchHeader = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
opatchHeader:SetPoint("TOP", configFrame, "TOP", 0, -46 + OPATCH_Y + 22)
opatchHeader:SetText("oPatch:")
opatchHeader:SetTextColor(1, 0, 0)

local opatchSub = configFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
opatchSub:SetPoint("TOP", opatchHeader, "BOTTOM", 0, -2)
opatchSub:SetText("require ShaguPlates")
opatchSub:SetTextColor(0.65, 0.65, 0.65)

local autoscaleHint = configFrame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
autoscaleHint:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 50)
autoscaleHint:SetWidth(FRAME_W - 48)
autoscaleHint:SetJustifyH("CENTER")
autoscaleHint:SetText("Autoscale shrinks long name/guild text so labels use less nameplate space.")
autoscaleHint:SetTextColor(0.6, 0.6, 0.6)

configFrame.elements.translateNP = CreateCheckbox(leftPanel, "Translate nameplates (Shagu)", 8, OPATCH_Y, "translateNameplates", nil, 1, 0.45, 0)
configFrame.elements.translateNP.wrapper:SetWidth(390)
configFrame.elements.translateNP.wrapper:SetHeight(24)
configFrame.elements.nameScaleSlider = CreateScaleSlider(leftPanel, "Name scale amount", 8, OPATCH_Y - 26, "nameplateAutoscaleNamesScale", 0.33, 1.5, true, 0.05)
configFrame.elements.nameAutoscaleRatioSlider = CreateScaleSlider(leftPanel, "Name autoscale amount", 8, OPATCH_Y - 52, "nameplateAutoscaleNamesRatio", 0, 1, true, 0.05, true)
configFrame.elements.nameColorPicker = CreatePlateColorPicker(leftPanel, "Name color:", 8, OPATCH_Y - 78, "nameplateNameColor", 1, 1, 1)
configFrame.elements.playerNameScaleSlider = CreateScaleSlider(leftPanel, "Player name scale", 8, OPATCH_Y - 104, "nameplatePlayerNameScale", 0.5, 3, true)
configFrame.elements.targetNameScaleSlider = CreateScaleSlider(leftPanel, "Active target scale", 8, OPATCH_Y - 130, "nameplateTargetNameScale", 0.5, 3, true)

-- ---- RIGHT PANEL: Outgoing + display ----
CreateHeader(rightPanel, "Outgoing (You -> Chat)", -8)
configFrame.elements.outEnabled = CreateCheckbox(rightPanel, "Enable Outgoing", 8, -34, "outgoingEnabled", nil)
configFrame.elements.outPrefix = CreateCheckbox(rightPanel, "Send [WT] prefix", 210, -34, "outgoingPrefixEnabled", nil)
configFrame.elements.outFrom = CreateLangSelector(rightPanel, "From:", 8, -58, "outgoingFromLang")
configFrame.elements.outTo = CreateLangSelector(rightPanel, "To:", 210, -58, "outgoingToLang")

local chLabel = rightPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
chLabel:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -118)
chLabel:SetText("Outgoing channels:")

configFrame.elements.chWhisper = CreateCheckbox(rightPanel, "Whisper", 8, -140, "outgoingChannels", "WHISPER")
configFrame.elements.chParty = CreateCheckbox(rightPanel, "Party", 108, -140, "outgoingChannels", "PARTY")
configFrame.elements.chSay = CreateCheckbox(rightPanel, "Say", 208, -140, "outgoingChannels", "SAY")
configFrame.elements.chGuild = CreateCheckbox(rightPanel, "Guild", 308, -140, "outgoingChannels", "GUILD")

configFrame.elements.chRaid = CreateCheckbox(rightPanel, "Raid", 8, -164, "outgoingChannels", "RAID")
configFrame.elements.chYell = CreateCheckbox(rightPanel, "Yell", 108, -164, "outgoingChannels", "YELL")
configFrame.elements.chEnglish = CreateCheckbox(rightPanel, "English", 208, -164, "outgoingChannels", "ENGLISH")
configFrame.elements.chBG = CreateCheckbox(rightPanel, "BG", 308, -164, "outgoingChannels", "BATTLEGROUND")

configFrame.elements.chChannel = CreateCheckbox(rightPanel, "World/Local", 8, -188, "outgoingChannels", "CHANNEL")
configFrame.elements.chHC = CreateCheckbox(rightPanel, "Hardcore", 208, -188, "outgoingChannels", "HARDCORE")

local Y_COLOR = -218
local colorSectionLabel = rightPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
colorSectionLabel:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, Y_COLOR)
colorSectionLabel:SetText("Translation text color:")

local colorSwatch = CreateFrame("Button", "WoWTranslateColorSwatch", rightPanel)
colorSwatch:SetWidth(30)
colorSwatch:SetHeight(18)
colorSwatch:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 168, Y_COLOR - 2)
colorSwatch:SetBackdrop({
    bgFile   = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile     = true, tileSize = 8, edgeSize  = 1,
    insets   = { left = 1, right = 1, top = 1, bottom = 1 },
})
colorSwatch:SetBackdropBorderColor(0, 0, 0)
colorSwatch:SetBackdropColor(1, 1, 1)

local colorSwatchLabel = rightPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
colorSwatchLabel:SetPoint("LEFT", colorSwatch, "RIGHT", 6, 0)
colorSwatchLabel:SetText("(click)")

local colorDefaultBtn = CreateFrame("Button", nil, rightPanel, "UIPanelButtonTemplate")
colorDefaultBtn:SetWidth(60)
colorDefaultBtn:SetHeight(18)
colorDefaultBtn:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 318, Y_COLOR - 2)
colorDefaultBtn:SetText("Default")

local function ApplyTranslationColor(hex)
    WoWTranslate_TempConfig.translationColor = hex
    if WoWTranslateDB then WoWTranslateDB.translationColor = hex end
    if hex and string.len(hex) == 6 then
        local r = tonumber(string.sub(hex, 1, 2), 16) / 255
        local g = tonumber(string.sub(hex, 3, 4), 16) / 255
        local b = tonumber(string.sub(hex, 5, 6), 16) / 255
        colorSwatch:SetBackdropColor(r, g, b)
    else
        colorSwatch:SetBackdropColor(0.5, 0.5, 0.5)  -- gray = default (no override)
    end
end

colorSwatch:SetScript("OnClick", function()
    local hex = (WoWTranslateDB and WoWTranslateDB.translationColor) or ""
    local r, g, b = 1, 1, 1
    if hex and string.len(hex) == 6 then
        r = tonumber(string.sub(hex, 1, 2), 16) / 255
        g = tonumber(string.sub(hex, 3, 4), 16) / 255
        b = tonumber(string.sub(hex, 5, 6), 16) / 255
    end
    ColorPickerFrame.hasOpacity = false
    ColorPickerFrame.func = function()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        local nhex = string.format("%02X%02X%02X",
            math.floor(nr * 255), math.floor(ng * 255), math.floor(nb * 255))
        ApplyTranslationColor(nhex)
    end
    ColorPickerFrame.cancelFunc = function(pv)
        local pr, pg, pb = pv[1], pv[2], pv[3]
        local phex = string.format("%02X%02X%02X",
            math.floor(pr * 255), math.floor(pg * 255), math.floor(pb * 255))
        ApplyTranslationColor(phex)
    end
    ColorPickerFrame.previousValues = { r, g, b }
    ColorPickerFrame:SetColorRGB(r, g, b)
    -- Ensure the picker appears above our DIALOG-strata config frame
    ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    ShowUIPanel(ColorPickerFrame)
end)

colorDefaultBtn:SetScript("OnClick", function()
    ApplyTranslationColor("")
end)

configFrame.elements.colorSwatch = colorSwatch

configFrame.elements.colorFollow = CreateCheckbox(rightPanel, "Follow channel color", 8, -244, "translationColorFollow", nil)

local expHeader = rightPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
expHeader:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 8, -272)
expHeader:SetText("Experimental:")
expHeader:SetTextColor(1, 0.5, 0)

configFrame.elements.replaceMode = CreateCheckbox(rightPanel, "Replace with translation", 8, -294, "replaceMode", nil)

-- oPatch (right): name toggles + guild / health / OOC
configFrame.elements.playerNameClassColor = CreateCheckbox(rightPanel, "Class-colored names (friendly)", 8, OPATCH_Y, "playerNameClassColor", nil)
configFrame.elements.nameplateShort = CreateCheckbox(rightPanel, "Only Show Translated Names", 210, OPATCH_Y, "nameplateShortNames", nil)
configFrame.elements.nameplateAutoscale = CreateCheckbox(rightPanel, "Autoscale names", 8, OPATCH_Y - 26, "nameplateAutoscaleNames", nil)
configFrame.elements.nameplateAutoscaleGuild = CreateCheckbox(rightPanel, "Autoscale guild", 8, OPATCH_Y - 52, "nameplateAutoscaleGuild", nil)
configFrame.elements.nameplateHideHealth = CreateCheckbox(rightPanel, "hide healthbar (out of combat)", 210, OPATCH_Y - 52, "nameplateHideHealthOOC", nil)
configFrame.elements.guildAutoscaleRatioSlider = CreateScaleSlider(rightPanel, "Guild autoscale amount", 8, OPATCH_Y - 78, "nameplateAutoscaleGuildRatio", 0, 1, true, 0.05, true)
configFrame.elements.guildScaleSlider = CreateScaleSlider(rightPanel, "Guild scale amount", 8, OPATCH_Y - 104, "nameplateAutoscaleGuildScale")
configFrame.elements.guildColorPicker = CreatePlateColorPicker(rightPanel, "Guild color:", 8, OPATCH_Y - 130, "nameplateGuildColor", 0.75, 0.75, 0.75)
configFrame.elements.nameplateGuildOOC = CreateCheckbox(rightPanel, "Guild under Shagu nameplate (out of combat)", 8, OPATCH_Y - 156, "nameplateGuildOOC", nil)
configFrame.elements.nameplateGuildOOC.wrapper:SetWidth(390)

-- Bottom Buttons (full width)
local clearBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
clearBtn:SetPoint("BOTTOMLEFT", configFrame, "BOTTOMLEFT", 24, 18)
clearBtn:SetWidth(120)
clearBtn:SetHeight(26)
clearBtn:SetText("Clear Cache")
clearBtn:SetScript("OnClick", function()
    if WoWTranslate_CacheClear then
        WoWTranslate_CacheClear()
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00[WoWTranslate] Cache cleared|r")
    end
end)

local saveBtn = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
saveBtn:SetPoint("BOTTOMRIGHT", configFrame, "BOTTOMRIGHT", -24, 18)
saveBtn:SetWidth(80)
saveBtn:SetHeight(26)
saveBtn:SetText("Save")
saveBtn:SetScript("OnClick", function()
    SaveTempConfig()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[WoWTranslate] Settings saved!|r")
    configFrame:Hide()
end)

-- ============================================================================
-- REFRESH UI FROM CONFIG
-- ============================================================================
local function RefreshUI()
    local e = configFrame.elements
    local cfg = WoWTranslate_TempConfig

    if e.colorSwatch then
        local hex = cfg.translationColor or ""
        if hex and string.len(hex) == 6 then
            local r = tonumber(string.sub(hex, 1, 2), 16) / 255
            local g = tonumber(string.sub(hex, 3, 4), 16) / 255
            local b = tonumber(string.sub(hex, 5, 6), 16) / 255
            e.colorSwatch:SetBackdropColor(r, g, b)
        else
            e.colorSwatch:SetBackdropColor(0.5, 0.5, 0.5)
        end
    end
    if e.colorFollow then e.colorFollow:SetChecked(cfg.translationColorFollow) end
    if e.replaceMode then e.replaceMode:SetChecked(cfg.replaceMode) end
    if e.translateNP then e.translateNP:SetChecked(cfg.translateNameplates) end
    if e.translateNames then e.translateNames:SetChecked(cfg.translatePlayerNames) end
    if e.translateGuilds then e.translateGuilds:SetChecked(cfg.translateGuildNames) end
    if e.inEnabled then e.inEnabled:SetChecked(cfg.enabled) end
    if e.afkDisable then e.afkDisable:SetChecked(cfg.disableWhileAfk) end
    if e.translateSystem then e.translateSystem:SetChecked(cfg.translateSystemMessages) end
    if e.nameplateShort then e.nameplateShort:SetChecked(cfg.nameplateShortNames) end
    if e.playerNameClassColor then e.playerNameClassColor:SetChecked(cfg.playerNameClassColor) end
    if e.nameplateHideHealth then e.nameplateHideHealth:SetChecked(cfg.nameplateHideHealthOOC) end
    if e.nameplateAutoscale then e.nameplateAutoscale:SetChecked(cfg.nameplateAutoscaleNames) end
    if e.nameScaleSlider and e.nameScaleSlider.SetScaleValue then
        e.nameScaleSlider.SetScaleValue(cfg.nameplateAutoscaleNamesScale or 1)
    end
    if e.nameAutoscaleRatioSlider and e.nameAutoscaleRatioSlider.SetScaleValue then
        e.nameAutoscaleRatioSlider.SetScaleValue(cfg.nameplateAutoscaleNamesRatio or 0.5)
    end
    if e.playerNameScaleSlider and e.playerNameScaleSlider.SetScaleValue then
        e.playerNameScaleSlider.SetScaleValue(cfg.nameplatePlayerNameScale or 1)
    end
    if e.targetNameScaleSlider and e.targetNameScaleSlider.SetScaleValue then
        e.targetNameScaleSlider.SetScaleValue(cfg.nameplateTargetNameScale or 1)
    end
    if e.nameplateAutoscaleGuild then e.nameplateAutoscaleGuild:SetChecked(cfg.nameplateAutoscaleGuild) end
    if e.guildAutoscaleRatioSlider and e.guildAutoscaleRatioSlider.SetScaleValue then
        e.guildAutoscaleRatioSlider.SetScaleValue(cfg.nameplateAutoscaleGuildRatio or 0.5)
    end
    if e.guildScaleSlider and e.guildScaleSlider.SetScaleValue then
        e.guildScaleSlider.SetScaleValue(cfg.nameplateAutoscaleGuildScale or 1)
    end
    if e.nameplateGuildOOC then e.nameplateGuildOOC:SetChecked(cfg.nameplateGuildOOC) end
    if e.nameColorPicker and e.nameColorPicker.SetColorHex then
        e.nameColorPicker.SetColorHex(cfg.nameplateNameColor or "")
    end
    if e.guildColorPicker and e.guildColorPicker.SetColorHex then
        e.guildColorPicker.SetColorHex(cfg.nameplateGuildColor or "")
    end
    if e.outEnabled then e.outEnabled:SetChecked(cfg.outgoingEnabled) end
    if e.outPrefix then e.outPrefix:SetChecked(cfg.outgoingPrefixEnabled) end

    -- Source language checkboxes
    local srcLangs = cfg.enabledSourceLangs or {}
    if e.srcZH then e.srcZH:SetChecked(srcLangs.zh) end
    if e.srcJA then e.srcJA:SetChecked(srcLangs.ja) end
    if e.srcKO then e.srcKO:SetChecked(srcLangs.ko) end
    if e.srcRU then e.srcRU:SetChecked(srcLangs.ru) end
    if e.srcEN then e.srcEN:SetChecked(srcLangs.en) end

    if e.inTo and e.inTo.display then
        e.inTo.display:SetText(GetLanguageName(cfg.incomingToLang or "en"))
    end
    if e.outFrom and e.outFrom.display then
        e.outFrom.display:SetText(GetLanguageName(cfg.outgoingFromLang or "en"))
    end
    if e.outTo and e.outTo.display then
        e.outTo.display:SetText(GetLanguageName(cfg.outgoingToLang or "zh"))
    end

    -- Incoming channels
    local inCh = cfg.incomingChannels or {}
    if e.inChSay then e.inChSay:SetChecked(inCh.SAY) end
    if e.inChYell then e.inChYell:SetChecked(inCh.YELL) end
    if e.inChWhisper then e.inChWhisper:SetChecked(inCh.WHISPER) end
    if e.inChParty then e.inChParty:SetChecked(inCh.PARTY) end
    if e.inChGuild then e.inChGuild:SetChecked(inCh.GUILD) end
    if e.inChRaid then e.inChRaid:SetChecked(inCh.RAID) end
    if e.inChBG then e.inChBG:SetChecked(inCh.BATTLEGROUND) end
    if e.inChChannel then e.inChChannel:SetChecked(inCh.CHANNEL) end
    if e.inChHC then e.inChHC:SetChecked(inCh.HARDCORE) end
    if e.inChEnglish then e.inChEnglish:SetChecked(inCh.ENGLISH) end

    -- Outgoing channels
    local ch = cfg.outgoingChannels or {}
    if e.chWhisper then e.chWhisper:SetChecked(ch.WHISPER) end
    if e.chParty then e.chParty:SetChecked(ch.PARTY) end
    if e.chSay then e.chSay:SetChecked(ch.SAY) end
    if e.chGuild then e.chGuild:SetChecked(ch.GUILD) end
    if e.chRaid then e.chRaid:SetChecked(ch.RAID) end
    if e.chYell then e.chYell:SetChecked(ch.YELL) end
    if e.chBG then e.chBG:SetChecked(ch.BATTLEGROUND) end
    if e.chChannel then e.chChannel:SetChecked(ch.CHANNEL) end
    if e.chHC then e.chHC:SetChecked(ch.HARDCORE) end
    if e.chEnglish then e.chEnglish:SetChecked(ch.ENGLISH) end
end

-- ============================================================================
-- PUBLIC API
-- ============================================================================
function WoWTranslate_ShowConfig()
    LoadTempConfig()
    RefreshUI()
    configFrame:Show()
end

function WoWTranslate_HideConfig()
    configFrame:Hide()
end

function WoWTranslate_ToggleConfig()
    if configFrame:IsVisible() then
        configFrame:Hide()
    else
        WoWTranslate_ShowConfig()
    end
end
