-- CraftSell: minimap button
--   Left click : show/hide the CraftSell window (works without profession window)
--   Right click: print the gold tracker summary
--   Drag       : move the button around the minimap
local ADDON, ns = ...

local button
local atan2 = math.atan2 or atan2

local function UpdatePosition()
  local angle = math.rad(CraftSellDB.minimapAngle or 200)
  local radius = (Minimap:GetWidth() / 2) + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  CraftSellDB.minimapAngle = math.deg(atan2(py - my, px - mx))
  UpdatePosition()
end

local function Create()
  if button or not Minimap then return end
  button = CreateFrame("Button", "CraftSellMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  button:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then
      ns.Ledger.PrintSummary()
    else
      ns.ToggleStandalone()
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", OnDragUpdate)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("CraftSell")
    GameTooltip:AddLine(ns.Ledger.TodayLine(), 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Linksklick: Übersicht ein-/ausblenden", 0.5, 0.8, 1)
    GameTooltip:AddLine("Rechtsklick: Gold-Bilanz im Chat", 0.5, 0.8, 1)
    GameTooltip:AddLine("Ziehen: Symbol verschieben", 0.5, 0.8, 1)
    GameTooltip:AddLine("/cs minimap blendet das Symbol aus", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
end

function ns.UpdateMinimapButton()
  Create()
  if not button then return end
  UpdatePosition()
  button:SetShown(not CraftSellDB.minimapHide)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
  if CraftSellDB then ns.UpdateMinimapButton() end
end)
