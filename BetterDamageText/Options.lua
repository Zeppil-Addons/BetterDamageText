-- Settings window for Better Damage Text. Open with /bdt, or from
-- Options > AddOns > Better Damage Text. Every change is saved straight away
-- and shown with a short preview.

local ADDON, ns = ...

-- Your own fonts go in this folder; type the file name in the settings window.
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
    local function Add(path, name)
        local key = path and path:lower()
        if key and not seen[key] and FontExists(path) then
            seen[key] = true
            table.insert(list, { path, name })
        end
    end
    for _, f in ipairs(GAME_FONTS) do Add(f[1], f[2]) end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    if lsm then
        for _, name in ipairs(lsm:List("font")) do Add(lsm:Fetch("font", name), name) end
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

-- Text box for a font file the player put in the addon's Fonts folder
local function CustomFont(parent, x, y)
    Label(parent, "Your own font (file in " .. ADDON .. "\\Fonts)", x, y)

    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetPoint("TOPLEFT", x + 6, y - 20)
    box:SetSize(150, 22)
    box:SetAutoFocus(false)
    box:SetText("e.g. pepsi.ttf")

    local status = parent:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    status:SetPoint("LEFT", box, "RIGHT", 54, 0)

    local use = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    use:SetPoint("LEFT", box, "RIGHT", 4, 0)
    use:SetSize(46, 22)
    use:SetText("Use")

    local function Apply()
        local file = strtrim(box:GetText() or "")
        local path = CUSTOM_FONT_FOLDER .. file
        if file ~= "" and FontExists(path) then
            ns.db.font = path
            status:SetText("|cff55ff55ok|r")
            Refresh()
            QueuePreview()
        else
            status:SetText("|cffff5555not found|r")
        end
        box:ClearFocus()
    end
    use:SetScript("OnClick", Apply)
    box:SetScript("OnEnterPressed", Apply)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEditFocusGained", function(self)
        if self:GetText() == "e.g. pepsi.ttf" then self:SetText("") end
    end)
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

local function BuildWindow()
    window = CreateFrame("Frame", "BetterDamageTextOptions", UIParent, "BasicFrameTemplateWithInset")
    window:SetSize(560, 560)
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

    -- left column
    local L = 20
    Header(window, "Text", L, -36)
    Choice(window, L, -64, "Font", "font", BuildFontList())
    CustomFont(window, L, -112)
    Choice(window, L, -160, "Outline", "outline", OUTLINES)
    Check(window, L, -208, "Drop shadow", "shadow")
    Slider(window, L, -236, "Font size", "fontSize", 10, 60, 1, fmtInt)
    Slider(window, L, -284, "Crit size", "critScale", 1, 3, 0.1, fmtX)
    Slider(window, L, -332, "Crit pop (starting size)", "critPop", 1, 5, 0.1, fmtX)

    Header(window, "Animation", L, -384)
    Slider(window, L, -412, "Time on screen", "duration", 0.5, 3, 0.1, fmtSec)
    Slider(window, L, -460, "Float distance", "rise", 0, 200, 5, fmtInt)

    -- right column
    local R = 300
    Header(window, "Icon", R, -36)
    Check(window, R, -64, "Show spell icon", "showIcon")
    Check(window, R, -90, "Icon on white hits too", "showMeleeIcon")
    Choice(window, R, -118, "Icon position", "iconSide", ICON_SIDES)
    Slider(window, R, -166, "Icon size", "iconSize", 10, 60, 1, fmtInt)

    Header(window, "Colours", R, -218)
    ColorSwatch(window, R, -246, "Melee (white hits)", "colorMelee")
    ColorSwatch(window, R, -276, "Spells and procs", "colorSpell")

    Header(window, "Show", R, -318)
    Check(window, R, -346, "Misses, dodges, parries", "showAvoids")
    Check(window, R, -372, "(blocked), (glancing)... labels", "showSuffixes")
    Check(window, R, -398, "Only my hits", "onlyMine")
    Check(window, R + 20, -424, "Instant (skip threat wait when sure)", "instant")
    Check(window, R, -450, "Hide Blizzard's damage numbers", "hideBlizzard",
        function() ns.ApplyBlizzardSetting(true) end)

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

    pcall(function()
        local category = Settings.RegisterCanvasLayoutCategory(panel, "Better Damage Text")
        Settings.RegisterAddOnCategory(category)
    end)
end)
