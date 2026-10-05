-- Minimap button: left-click opens the settings, right-click shows a preview,
-- drag to move it around the minimap. Can be hidden in the settings.

local ADDON, ns = ...

local ICON = "Interface\\AddOns\\" .. ADDON .. "\\icon.png"

local button

local function UpdatePosition()
    local angle = math.rad(ns.db.minimapAngle)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- follow the cursor around the minimap's edge while dragging
local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    UpdatePosition()
end

local function Create()
    button = CreateFrame("Button", "BetterDamageTextMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- the same round border every minimap button uses
    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 7, -6)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.Preview()
        else
            ns.ToggleOptions()
        end
    end)
    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Better Damage Text")
        GameTooltip:AddLine("|cffffffffLeft-click|r to open settings", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffRight-click|r for a preview", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("|cffffffffDrag|r to move this button", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
end

-- Shows or hides the button to match the "Minimap button" setting.
function ns.UpdateMinimapButton()
    if not button then Create() end
    button:SetShown(ns.db.minimapButton)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", ns.UpdateMinimapButton)
