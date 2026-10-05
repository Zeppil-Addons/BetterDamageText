-- Settings window for Better Damage Text. Open with /bdt, or from
-- Options > AddOns > Better Damage Text. Every change is saved straight away
-- and shown with a short preview.

local ADDON, ns = ...

-- Fonts bundled with the addon (listed in FontList.lua by tools/update-fonts.sh)
local CUSTOM_FONT_FOLDER = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"

-- Fonts that ship with the game. Not every client has all of them, so the
-- list is checked when the window opens and missing ones are left out.
local GAME_FONTS = {
    { "Fonts\\FRIZQT__.TTF",       "Friz Quadrata (default)" },
    { DAMAGE_TEXT_FONT,            "Blizzard damage font" },
    { "Fonts\\2002B.TTF",          "2002 Bold" },
    { "Fonts\\2002.TTF",           "2002" },
    { "Fonts\\K_Damage.TTF",       "Korean damage font (bold numbers)" },
    { "Fonts\\bLEI00D.ttf",        "Bold Chinese UI font" },
    { "Fonts\\ARKai_C.ttf",        "AR Kai" },
    { "Fonts\\ARIALN.TTF",         "Arial Narrow" },
    { "Fonts\\NIM_____.ttf",       "Nimrod" },
    { "Fonts\\MORPHEUS.TTF",       "Morpheus" },
    { "Fonts\\SKURRI.TTF",         "Skurri" },
}

local fontTester = UIParent:CreateFontString()

local function FontExists(path)
    return type(path) == "string" and fontTester:SetFont(path, 12, "") and true or false
end

-- Game fonts that load, plus any registered by other addons through
-- LibSharedMedia (ElvUI, Details, SharedMedia packs...).
local function BuildFontList()
    local list, seen = {}, {}
    local function Add(path, name, check)
        local key = type(path) == "string" and path:lower()
        if key and not seen[key] and (not check or FontExists(path)) then
            seen[key] = true
            table.insert(list, { path, name })
        end
    end
    -- fonts shipped in our Fonts folder (FontList.lua), named after the file:
    -- "LuckiestGuy-Regular.ttf" -> "Luckiest Guy", "PassionOne-Black.ttf" -> "Passion One Black".
    -- Always listed: they're in the download, but the game only loads new font
    -- files after a full restart, so a load check could hide them.
    local bundled = {}
    for _, file in ipairs(ns.bundledFonts or {}) do
        local name = file:gsub("%.[Tt][Tt][Ff]$", ""):gsub("%-Regular$", ""):gsub("[-_]", " "):gsub("(%l)(%u)", "%1 %2")
        table.insert(bundled, { CUSTOM_FONT_FOLDER .. file, name })
    end

    for _, f in ipairs(GAME_FONTS) do Add(f[1], f[2], true) end
    for _, f in ipairs(bundled) do Add(f[1], f[2], false) end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm then
        for _, name in ipairs(lsm:List("font")) do Add(lsm:Fetch("font", name), name, true) end
    end
    return list
end

local OUTLINES = {
    { "",             "None" },
    { "OUTLINE",      "Thin" },
    { "THICKOUTLINE", "Thick" },
}

local ICON_SIDES = {
    { "LEFT",  "Left of number" },
    { "RIGHT", "Right of number" },
}

local window
local feedbackBox     -- the box holding the feedback link; see ns.ShowFeedback
local refreshers = {} -- functions that update each control from the saved settings
local Refresh         -- defined below; updates every control

-- Show a preview once the player stops changing things for a moment, so
-- dragging a slider doesn't spam the screen.
local previewTimer
local function QueuePreview()
    if previewTimer then previewTimer:Cancel() end
    previewTimer = C_Timer.NewTimer(0.4, ns.Preview)
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------
local function Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
end

local function Label(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Slider(parent, x, y, text, key, min, max, step, format)
    Label(parent, text, x, y)

    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetPoint("TOPLEFT", x, y - 20)
    s:SetSize(190, 17)
    s:SetOrientation("HORIZONTAL")
    s:SetHitRectInsets(0, 0, -8, -8)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(min, max)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)

    local value = s:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    value:SetPoint("LEFT", s, "RIGHT", 8, 0)

    s:SetScript("OnValueChanged", function(_, v, userInput)
        v = math.floor(v / step + 0.5) * step
        ns.db[key] = v
        value:SetText(format(v))
        if userInput then QueuePreview() end
    end)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(self:GetValue() + delta * step)
        QueuePreview()
    end)

    table.insert(refreshers, function()
        s:SetValue(ns.db[key])
        value:SetText(format(ns.db[key])) -- SetValue doesn't fire OnValueChanged if unchanged
    end)
end

local function Check(parent, x, y, text, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x - 4, y + 4)
    cb:SetSize(26, 26)
    local label = Label(parent, text, x + 24, y)
    label:SetPoint("TOPLEFT", x + 24, y - 2)
    cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        if onChange then onChange() end
        QueuePreview()
    end)
    table.insert(refreshers, function() cb:SetChecked(ns.db[key]) end)
end

-- "< value >" picker for a short list of choices
local function Choice(parent, x, y, text, key, options)
    Label(parent, text, x, y)

    local shown = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    shown:SetPoint("TOPLEFT", x + 30, y - 25)
    shown:SetWidth(150)

    local function Update()
        local current = ns.db[key]
        local name = current:match("[^\\]+$") or current -- unknown font: show its file name
        for _, o in ipairs(options) do
            if o[1] == current then name = o[2] end
        end
        shown:SetText(name)
    end

    local function Step(dir)
        local index = 0
        for i, o in ipairs(options) do
            if o[1] == ns.db[key] then index = i end
        end
        index = (index - 1 + dir) % #options + 1
        ns.db[key] = options[index][1]
        Update()
        QueuePreview()
    end

    local prev = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    prev:SetPoint("TOPLEFT", x, y - 20)
    prev:SetSize(26, 22)
    prev:SetText("<")
    prev:SetScript("OnClick", function() Step(-1) end)

    local nextButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    nextButton:SetPoint("TOPLEFT", x + 184, y - 20)
    nextButton:SetSize(26, 22)
    nextButton:SetText(">")
    nextButton:SetScript("OnClick", function() Step(1) end)

    table.insert(refreshers, Update)
end

local function ColorSwatch(parent, x, y, text, key)
    local swatch = CreateFrame("Button", nil, parent, "BackdropTemplate")
    swatch:SetPoint("TOPLEFT", x, y)
    swatch:SetSize(22, 22)
    swatch:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
    local fill = swatch:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(1, 1, 1)
    Label(parent, text, x + 30, y - 4)

    local function Set(r, g, b)
        ns.db[key] = { r, g, b }
        fill:SetVertexColor(r, g, b)
    end

    swatch:SetScript("OnClick", function()
        local r, g, b = unpack(ns.db[key])
        local function Changed()
            Set(ColorPickerFrame:GetColorRGB())
            QueuePreview()
        end
        local function Cancelled()
            Set(r, g, b)
        end
        if ColorPickerFrame.SetupColorPickerAndShow then
            ColorPickerFrame:SetupColorPickerAndShow({
                r = r, g = g, b = b, hasOpacity = false,
                swatchFunc = Changed, cancelFunc = Cancelled,
            })
        else -- older colour picker
            ColorPickerFrame.func, ColorPickerFrame.cancelFunc = Changed, Cancelled
            ColorPickerFrame.hasOpacity = false
            ColorPickerFrame:SetColorRGB(r, g, b)
            ShowUIPanel(ColorPickerFrame)
        end
    end)

    table.insert(refreshers, function() fill:SetVertexColor(unpack(ns.db[key])) end)
end

-- A box holding a link for the player to copy. Clicking it selects the whole
-- link, ready for Ctrl+C: the game can't open a browser itself. Typing in it
-- does nothing, so the link can't be lost.
local function CopyBox(parent, width, text)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetFontObject(GameFontHighlightSmall)
    box:SetText(text)
    box:SetCursorPosition(0)

    local function SelectAll(self)
        self:SetText(text) -- undo anything typed over it
        self:HighlightText()
    end
    box:SetScript("OnEditFocusGained", SelectAll)
    box:SetScript("OnMouseUp", SelectAll)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then SelectAll(self) end
    end)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Click, then press Ctrl+C to copy. Paste it in your browser.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return box
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
function Refresh()
    for _, r in ipairs(refreshers) do r() end
end

local function ResetToDefaults()
    for k, v in pairs(ns.defaults) do
        ns.db[k] = type(v) == "table" and CopyTable(v) or v
    end
    ns.ApplyBlizzardSetting()
    Refresh()
    ns.Preview()
end

-- One-click looks. A preset sets every appearance setting: anything it doesn't
-- list goes back to the default. Behaviour settings (only my hits, etc.) are left alone.
local LOOK_SETTINGS = {
    "font", "outline", "shadow", "fontSize", "critScale", "critPop",
    "animation", "duration", "rise",
    "showIcon", "showMeleeIcon", "iconSide", "iconSize", "colorMelee", "colorSpell",
}

local PRESETS = {
    { name = "Blizzard", values = {} }, -- the defaults
    { name = "Big & Bold", values = {
        font = CUSTOM_FONT_FOLDER .. "LuckiestGuy-Regular.ttf", outline = "THICKOUTLINE", shadow = true,
        fontSize = 34, critScale = 1.9, critPop = 3.5, animation = "pop", duration = 1.6, rise = 40, iconSize = 34,
    } },
    { name = "Fountain", values = {
        font = CUSTOM_FONT_FOLDER .. "Bangers-Regular.ttf", shadow = true,
        fontSize = 30, critScale = 1.8, animation = "fountain", duration = 1.5, rise = 90, iconSize = 28,
    } },
    { name = "Arcade", values = {
        font = CUSTOM_FONT_FOLDER .. "TitanOne-Regular.ttf", outline = "THICKOUTLINE",
        fontSize = 28, critScale = 2.0, critPop = 4.0, animation = "scatter", duration = 1.3, rise = 80,
        iconSize = 28, colorSpell = { 1, 0.55, 0.1 },
    } },
    { name = "Minimal", values = {
        font = "Fonts\\ARIALN.TTF", fontSize = 20, critScale = 1.4, critPop = 2.0,
        duration = 1.0, rise = 50, iconSize = 18, showMeleeIcon = false,
    } },
}

local function ApplyPreset(preset)
    for _, key in ipairs(LOOK_SETTINGS) do
        local v = preset.values[key]
        if v == nil then v = ns.defaults[key] end
        ns.db[key] = type(v) == "table" and CopyTable(v) or v
    end
    Refresh()
    ns.Preview()
end

local function BuildWindow()
    window = CreateFrame("Frame", "BetterDamageTextOptions", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(560, 650)
    window:SetPoint("CENTER")
    window:SetFrameStrata("DIALOG")
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetClampedToScreen(true)
    table.insert(UISpecialFrames, "BetterDamageTextOptions") -- Escape closes it

    if window.TitleText then
        window.TitleText:SetText("Better Damage Text")
    else
        local title = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("Better Damage Text")
    end

    local fmtInt = function(v) return string.format("%d", v) end
    local fmtX = function(v) return string.format("%.1fx", v) end
    local fmtSec = function(v) return string.format("%.1fs", v) end

    -- presets across the top
    Header(window, "Presets", 20, -36)
    for i, preset in ipairs(PRESETS) do
        local b = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        b:SetPoint("TOPLEFT", 20 + (i - 1) * 104, -60)
        b:SetSize(98, 24)
        b:SetText(preset.name)
        b:SetScript("OnClick", function() ApplyPreset(preset) end)
    end

    -- left column
    local L = 20
    Header(window, "Text", L, -100)
    Choice(window, L, -128, "Font", "font", BuildFontList())
    Choice(window, L, -176, "Outline", "outline", OUTLINES)
    Check(window, L, -224, "Drop shadow", "shadow")
    Slider(window, L, -252, "Font size", "fontSize", 10, 60, 1, fmtInt)
    Slider(window, L, -300, "Crit size", "critScale", 1, 3, 0.1, fmtX)
    Slider(window, L, -348, "Crit pop (starting size)", "critPop", 1, 5, 0.1, fmtX)

    Header(window, "Animation", L, -400)
    Choice(window, L, -428, "Style", "animation", ns.ANIMATIONS)
    Slider(window, L, -476, "Time on screen", "duration", 0.5, 3, 0.1, fmtSec)
    Slider(window, L, -524, "Distance", "rise", 0, 200, 5, fmtInt)

    -- right column
    local R = 300
    Header(window, "Icon", R, -100)
    Check(window, R, -128, "Show spell icon", "showIcon")
    Check(window, R, -154, "Icon on white hits too", "showMeleeIcon")
    Choice(window, R, -182, "Icon position", "iconSide", ICON_SIDES)
    Slider(window, R, -230, "Icon size", "iconSize", 10, 60, 1, fmtInt)

    Header(window, "Colours", R, -282)
    ColorSwatch(window, R, -310, "Melee (white hits)", "colorMelee")
    ColorSwatch(window, R, -340, "Spells and procs", "colorSpell")

    Header(window, "Show", R, -382)
    Check(window, R, -410, "Misses, dodges, parries", "showAvoids")
    Check(window, R, -436, "(blocked), (glancing)... labels", "showSuffixes")
    Check(window, R, -462, "Hide Blizzard's damage numbers", "hideBlizzard",
        function() ns.ApplyBlizzardSetting(true) end)
    Check(window, R, -488, "Minimap button", "minimapButton", ns.UpdateMinimapButton)

    Header(window, "Feedback", R, -520)
    Label(window, "Found a bug or have an idea?", R, -546)
    feedbackBox = CopyBox(window, 222, ns.FEEDBACK_URL)
    feedbackBox:SetPoint("TOPLEFT", R + 10, -566) -- the template draws its border 10px left of the box

    local preview = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    preview:SetPoint("BOTTOMRIGHT", -20, 18)
    preview:SetSize(110, 24)
    preview:SetText("Preview")
    preview:SetScript("OnClick", ns.Preview)

    local reset = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
    reset:SetPoint("RIGHT", preview, "LEFT", -8, 0)
    reset:SetSize(130, 24)
    reset:SetText("Reset to defaults")
    reset:SetScript("OnClick", ResetToDefaults)

    local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 20, 24)
    hint:SetText("Changes save automatically. Previews show on your target.")
end

function ns.OpenOptions()
    if not window then BuildWindow() end
    Refresh()
    window:Show()
end

function ns.ToggleOptions()
    if window and window:IsShown() then
        window:Hide()
    else
        ns.OpenOptions()
    end
end

-- Opens the settings with the feedback link selected, ready for Ctrl+C.
function ns.ShowFeedback()
    ns.OpenOptions()
    feedbackBox:SetFocus()
end

---------------------------------------------------------------------------
-- Entry in Options > AddOns
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    -- the Settings panel calls these; nothing to do since changes save immediately
    panel.OnCommit = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() end

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Better Damage Text")

    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetText("Settings are in their own window. You can also open it with /bdt.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -12)
    open:SetSize(160, 26)
    open:SetText("Open settings")
    open:SetScript("OnClick", function()
        if SettingsPanel then HideUIPanel(SettingsPanel) end
        ns.OpenOptions()
    end)

    local feedback = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    feedback:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -24)
    feedback:SetText("Found a bug or have an idea? Copy this link into your browser:")

    local link = CopyBox(panel, 360, ns.FEEDBACK_URL)
    link:SetPoint("TOPLEFT", feedback, "BOTTOMLEFT", 10, -8)

    pcall(function()
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Better Damage Text")
        Settings.RegisterAddOnCategory(category)
    end)
end)
