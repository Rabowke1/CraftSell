-- CraftSell: side panel attached to the profession window
local ADDON, ns = ...
local P = ns.Prices
local Money = P.FormatMoney

local WIDTH, ROW_H, MAX_ROWS = 340, 32, 30

local function Colorize(entry)
  local name = entry.name or "?"
  local c = TradeSkillTypeColor and entry.kind and TradeSkillTypeColor[entry.kind]
  if c then
    return string.format("|cff%02x%02x%02x%s|r",
      math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), name)
  end
  return name
end

-- The MicroStream textures all point down; the green one is flipped
-- vertically (top/bottom texcoords swapped) so "profit rose" points up.
local ARROW_UP   = "|TInterface\\Buttons\\UI-MicroStream-Green:12:12:0:0:32:32:0:32:32:0|t"
local ARROW_DOWN = "|TInterface\\Buttons\\UI-MicroStream-Red:12:12|t"
local TREND_SECONDS = 600   -- show arrows for 10 minutes after a change

-- Remember the last profit per recipe to show trends. Stored in the saved
-- variables (CraftSellDB.trend), so it survives /reload and relogging.
local function UpdateTrend(key, e)
  CraftSellDB.trend = CraftSellDB.trend or {}
  local h = CraftSellDB.trend[key]
  if not h then
    h = {}
    CraftSellDB.trend[key] = h
  end
  local now = time()
  if e.profitItem and h.value and math.abs(e.profitItem - h.value) >= 1 then
    h.dir = (e.profitItem > h.value) and 1 or -1
    h.old = h.value
    h.time = now
  end
  if e.profitItem then h.value = e.profitItem end
  if h.dir and h.time and now - h.time < TREND_SECONDS then
    e.trend, e.oldProfit = h.dir, h.old
  else
    e.trend, e.oldProfit = nil, nil
  end
end

local function ProfitText(e)
  if e.profitItem == nil then return "|cff888888?|r" end
  local s = Money(e.profitItem)
  if e.unknownCost then s = s .. " |cffff8000*|r" end
  if e.trend == 1 then
    s = ARROW_UP .. s
  elseif e.trend == -1 then
    s = ARROW_DOWN .. s
  end
  return s
end

local function DetailText(e)
  local made = ""
  if e.made and e.made ~= 1 then made = string.format(" (x%g)", e.made) end
  local own = ""
  for _, r in ipairs(e.reagents) do
    if r.via then own = " |cff80c0ff(inkl. Eigenherst.)|r" break end
  end
  local inter = e.isIntermediate and "  |cff80c0ff[Zwischenprodukt]|r" or ""
  return "|cffaaaaaaVerkauf:|r " .. Money(e.sellUnit) .. made
    .. "   |cffaaaaaaMaterial:|r " .. Money(e.cost) .. (e.unknownCost and " |cffff8000*|r" or "")
    .. own .. inter
end

-- Second line of a learnable recipe: trainer cost, skill, gain vs. best known.
local function LearnDetailText(e)
  local parts = { "|cffaaaaaaLernen:|r " .. (e.fee and Money(e.fee) or "|cff888888?|r") }
  if e.skill then
    parts[#parts + 1] = "|cffaaaaaaSkill|r " .. (e.canLearn and e.skill or ("|cffff6060" .. e.skill .. "|r"))
  end
  if e.noReagents then
    parts[#parts + 1] = "|cffff8000Materialien unbekannt|r"
  elseif e.gain then
    parts[#parts + 1] = "|cffaaaaaavs. bestes:|r " .. (e.gain > 0 and "|cff40ff40+|r" or "") .. Money(e.gain)
  end
  if e.payback then parts[#parts + 1] = "|cffaaaaaarein nach|r " .. e.payback .. "x" end
  return table.concat(parts, "   ")
end

local function LearnName(e)
  local name = e.canLearn and (e.name or "?") or ("|cff9d9d9d" .. (e.name or "?") .. "|r")
  if e.better then name = name .. " |cff40ff40(lohnt)|r" end
  return name
end

local function ShowTooltip(owner, e)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  if type(e.output) == "number" then
    GameTooltip:SetItemByID(e.output)
  else
    GameTooltip:SetHyperlink(e.output)
  end
  GameTooltip:AddLine(" ")
  if e.learn then
    GameTooltip:AddLine("|cffffd200CraftSell – beim Lehrer lernbar|r")
    GameTooltip:AddDoubleLine("Lernkosten", e.fee and Money(e.fee) or "unbekannt", 1, 1, 1)
    if e.skill then
      local you = e.playerSkill and ("  (du: " .. e.playerSkill .. ")") or ""
      GameTooltip:AddDoubleLine("Benötigte Fertigkeit", e.skill .. you,
        1, 1, 1, e.canLearn and 0.3 or 1, e.canLearn and 1 or 0.3, 0.3)
    end
  else
    GameTooltip:AddLine("|cffffd200CraftSell – Händlerverkauf|r")
  end
  if e.sellUnit then
    GameTooltip:AddDoubleLine("Händlerpreis pro Stück", Money(e.sellUnit), 1, 1, 1)
  else
    GameTooltip:AddLine("Händlerpreis wird noch geladen …", 0.6, 0.6, 0.6)
  end
  if e.made and e.made ~= 1 then
    GameTooltip:AddDoubleLine("Stück pro Herstellung", string.format("%g", e.made), 1, 1, 1, 1, 1, 1)
  end
  GameTooltip:AddLine("Materialkosten:", 1, 1, 1)
  for _, r in ipairs(e.reagents) do
    local right
    if r.unit then
      right = Money(r.unit * r.count) .. " |cff888888(" .. (r.src or "?") .. ")|r"
    else
      right = "|cffff8000kein Preis|r"
    end
    GameTooltip:AddDoubleLine("  " .. r.count .. "x " .. (r.name or "?"), right, 0.8, 0.8, 0.8)
    if r.via then
      -- cheaper to craft this reagent yourself
      GameTooltip:AddDoubleLine("     -> selbst herstellen: " .. (r.via.name or "?"),
        "Kauf: " .. Money(r.market and r.market * r.count), 0.5, 0.8, 1, 0.6, 0.6, 0.6)
      for _, s in ipairs(r.via.reagents) do
        GameTooltip:AddLine("         " .. s.count .. "x " .. (s.name or (s.itemID and C_Item.GetItemNameByID and C_Item.GetItemNameByID(s.itemID)) or "?"), 0.6, 0.6, 0.6)
      end
    end
  end
  GameTooltip:AddDoubleLine("Summe Material", Money(e.cost), 1, 1, 1)
  if e.profitItem then
    GameTooltip:AddDoubleLine("Gewinn pro Gegenstand", Money(e.profitItem), 1, 0.82, 0)
    if e.trend and e.oldProfit then
      GameTooltip:AddDoubleLine(e.trend == 1 and "  gestiegen, vorher" or "  gefallen, vorher",
        Money(e.oldProfit), e.trend == 1 and 0.3 or 1, e.trend == 1 and 1 or 0.3, 0.3)
    end
    GameTooltip:AddDoubleLine("Gewinn pro Herstellung", Money(e.profitCraft), 1, 1, 1)
    if (e.numAvailable or 0) > 0 then
      GameTooltip:AddDoubleLine("Jetzt herstellbar: " .. e.numAvailable .. "x  → gesamt",
        Money(e.profitCraft * e.numAvailable), 1, 1, 1)
    end
  end
  if e.learn then
    local best = e.bestName and ('"' .. e.bestName .. '"') or "dein bestes Rezept"
    if e.gain then
      GameTooltip:AddDoubleLine("Mehr pro Stück als " .. best, Money(e.gain),
        1, 1, 1, e.gain > 0 and 0.3 or 1, e.gain > 0 and 1 or 0.3, 0.3)
    end
    if e.payback then
      GameTooltip:AddDoubleLine("Lernkosten wieder drin nach", e.payback .. " Herstellungen", 1, 1, 1, 1, 1, 1)
    elseif e.profitCraft and e.profitCraft <= 0 then
      GameTooltip:AddLine("Kein Gewinn beim Händler – lernen lohnt sich dafür nicht.", 1, 0.3, 0.3, true)
    end
  end
  if e.noReagents then
    GameTooltip:AddLine("Materialien unbekannt: öffne einmal das Berufsfenster oder installiere Crafter's Journal.", 1, 0.5, 0, true)
  elseif e.unknownCost then
    GameTooltip:AddLine("* Für mind. ein Material fehlt ein Preis – Gewinn ist zu hoch angesetzt. Einmal im AH scannen!", 1, 0.5, 0, true)
  end
  if e.learn then
    if e.source then GameTooltip:AddLine("Quelle: " .. e.source, 0.6, 0.6, 0.6) end
    if ns.Learn.TrainerOpen() then
      GameTooltip:AddLine("Klick: beim Lehrer auswählen", 0.5, 0.8, 1)
    end
  else
    GameTooltip:AddLine("Klick: Rezept im Berufsfenster öffnen", 0.5, 0.8, 1)
  end
  GameTooltip:Show()
end

local function OnEntryClick(adapter, e)
  if not e then return end
  if e.learn then
    ns.Learn.SelectAtTrainer(e.name)
  else
    adapter.Select(e.id)
  end
end

local function MakeCheck(panel, label, key, x, y)
  local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  cb:SetSize(22, 22)
  cb:SetPoint("TOPLEFT", x, y)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  cb.label = fs
  -- the same box can switch the setting it stands for (learn mode)
  function cb:SetKey(newKey, newLabel)
    self.key = newKey
    self.label:SetText(newLabel)
    self:SetChecked(CraftSellDB[newKey])
  end
  cb:SetKey(key, label)
  cb:SetScript("OnClick", function(self)
    CraftSellDB[self.key] = self:GetChecked() and true or false
    ns.ScheduleRefresh(0)
  end)
  return cb
end

local function AddBackground(frame, r, g, b, a, inset)
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", inset or 0, -(inset or 0))
  bg:SetPoint("BOTTOMRIGHT", -(inset or 0), inset or 0)
  bg:SetColorTexture(r, g, b, a)
  return bg
end

local function AddBorder(frame, r, g, b, a)
  if not frame.SetBackdrop then return end
  frame:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  frame:SetBackdropBorderColor(r, g, b, a)
end

local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil

function ns.CreatePanel(parent, adapter)
  local panel = CreateFrame("Frame", "CraftSellPanel_" .. adapter.key, parent, BACKDROP)
  panel.adapter = adapter

  -- Docked panels share CraftSellDB.pos/width; the standalone window keeps
  -- its own geometry in CraftSellDB.standalone.
  local cfg
  if adapter.standalone then
    CraftSellDB.standalone = CraftSellDB.standalone or {}
    cfg = CraftSellDB.standalone
  else
    cfg = CraftSellDB
  end
  panel.cfg = cfg
  panel:SetWidth(cfg.width or WIDTH)

  -- Sit to the right of anything that sticks out of the profession window
  -- (e.g. the profession tabs on its right edge).
  function panel:Reanchor()
    -- Never while the user drags or resizes: the periodic refresh would put
    -- the window back to its old saved position (it "jumps").
    if self.moving then return end
    local pos = cfg.pos
    if pos then
      -- user moved the window: restore saved position (stored in screen pixels)
      local es = self:GetEffectiveScale()
      self.anchoredExtra = nil
      self.centered = nil
      self:ClearAllPoints()
      self:SetHeight(pos.h / es)
      self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x / es, pos.y / es)
      return
    end
    local dock, a = parent, adapter.anchor
    if adapter.standalone then
      -- dock next to the open profession window, otherwise screen center
      dock, a = nil, nil
      if adapter.DockFrame then dock, a = adapter.DockFrame() end
      if not dock then
        self.dockedTo = nil
        if not self.centered then
          self.centered = true
          self:ClearAllPoints()
          self:SetHeight(560)
          self:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
        end
        return
      end
      self.centered = nil
      if self.dockedTo ~= dock then
        self.dockedTo = dock
        self.anchoredExtra = nil
      end
      a = a or { 0, 0, 0, 0 }
    end
    local extra = 0
    local right = dock:GetRight()
    if right then
      for _, child in ipairs({ dock:GetChildren() }) do
        if child ~= self and child:IsShown() then
          local l, r = child:GetLeft(), child:GetRight()
          if l and r and l >= right - 15 and r > right then
            extra = math.max(extra, r - right)
          end
        end
      end
    end
    if extra > 0 then extra = math.min(extra, 120) + 4 end
    if self.anchoredExtra == extra then return end
    self.anchoredExtra = extra
    self:ClearAllPoints()
    self:SetPoint("TOPLEFT", dock, "TOPRIGHT", a[1] + extra, a[2])
    self:SetPoint("BOTTOMLEFT", dock, "BOTTOMRIGHT", a[3] + extra, a[4])
  end
  panel:Reanchor()
  panel:SetFrameStrata(parent:GetFrameStrata())
  panel:SetFrameLevel(parent:GetFrameLevel() + 10)
  panel:EnableMouse(true)
  panel.bg = AddBackground(panel, 0.06, 0.05, 0.04, 1, 3)
  AddBorder(panel, 0.6, 0.5, 0.3, 1)

  -- Background opacity (text and icons stay fully visible)
  function panel:ApplyAlpha()
    local a = CraftSellDB.bgAlpha or 0.75
    self.bg:SetAlpha(a)
    if self.SetBackdropBorderColor then self:SetBackdropBorderColor(0.6, 0.5, 0.3, math.max(a, 0.4)) end
    if self.bestBg then self.bestBg:SetAlpha(math.max(a, 0.3)) end
  end

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -12)
  title:SetText("CraftSell – Händler-Gewinn")

  -- Drag handle on the title bar ---------------------------------------------
  panel:SetMovable(true)
  panel:SetClampedToScreen(true)
  local drag = CreateFrame("Frame", nil, panel)
  drag:SetPoint("TOPLEFT", 4, -4)
  drag:SetPoint("TOPRIGHT", -4, -4)
  drag:SetHeight(28)
  drag:EnableMouse(true)
  drag:RegisterForDrag("LeftButton")
  -- Turn the docked panel into a freely positioned one (same place/size).
  local function Detach()
    local l, t, h = panel:GetLeft(), panel:GetTop(), panel:GetHeight()
    panel:ClearAllPoints()
    panel:SetHeight(h)
    panel:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
  end
  local function SaveGeometry()
    if not panel.moving then return end
    panel:StopMovingOrSizing()
    panel.moving = nil
    if panel.SetUserPlaced then panel:SetUserPlaced(false) end
    local es = panel:GetEffectiveScale()
    local l, t = panel:GetLeft(), panel:GetTop()
    if l and t then
      cfg.pos = { x = l * es, y = t * es, h = panel:GetHeight() * es }
      cfg.width = panel:GetWidth()
    end
    panel:Reanchor()
    panel:UpdateRows()
  end
  drag:SetScript("OnDragStart", function()
    Detach()
    panel.moving = true
    panel:StartMoving()
  end)
  drag:SetScript("OnDragStop", SaveGeometry)

  -- Ctrl + mouse wheel on the title: background opacity
  drag:EnableMouseWheel(true)
  drag:SetScript("OnMouseWheel", function(_, delta)
    if not IsControlKeyDown() then return end
    local a = (CraftSellDB.bgAlpha or 0.75) + delta * 0.05
    CraftSellDB.bgAlpha = math.max(0, math.min(1, a))
    if ns.ApplyAlphaAll then ns.ApplyAlphaAll() else panel:ApplyAlpha() end
  end)

  -- Resize grip (bottom right) ------------------------------------------------
  panel:SetResizable(true)
  if panel.SetResizeBounds then
    panel:SetResizeBounds(300, 344, 900, 1400)
  else
    if panel.SetMinResize then panel:SetMinResize(300, 344) end
    if panel.SetMaxResize then panel:SetMaxResize(900, 1400) end
  end
  local grip = CreateFrame("Button", nil, panel)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetFrameLevel(panel:GetFrameLevel() + 20)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then return end
    Detach()
    panel.moving = true
    panel:StartSizing("BOTTOMRIGHT")
  end)
  grip:SetScript("OnMouseUp", SaveGeometry)
  grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Ziehen: Fenstergröße ändern")
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", GameTooltip_Hide)
  drag:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then
      cfg.pos = nil
      panel.anchoredExtra = nil
      panel.centered = nil
      panel:Reanchor()
    end
  end)
  drag:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("CraftSell")
    GameTooltip:AddLine("Linke Maustaste ziehen: Fenster verschieben", 1, 1, 1)
    if adapter.standalone then
      GameTooltip:AddLine("Rechtsklick: wieder ans Berufsfenster andocken (ohne Beruf: Bildschirmmitte)", 1, 1, 1)
      GameTooltip:AddLine("Pfeile links/rechts: Beruf wechseln (wenn kein Berufsfenster offen ist)", 1, 1, 1)
    else
      GameTooltip:AddLine("Rechtsklick: wieder am Berufsfenster andocken", 1, 1, 1)
    end
    GameTooltip:AddLine("Strg + Mausrad: Transparenz (" .. math.floor((CraftSellDB.bgAlpha or 0.75) * 100 + 0.5) .. "% deckend)", 1, 1, 1)
    GameTooltip:AddLine("Ecke unten rechts ziehen: Größe ändern", 1, 1, 1)
    GameTooltip:Show()
  end)
  drag:SetScript("OnLeave", GameTooltip_Hide)
  panel.title = title

  -- Standalone window: close button, profession switcher ------------------------
  if adapter.standalone then
    local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetFrameLevel(drag:GetFrameLevel() + 2)
    close:SetScript("OnClick", function() panel:Hide() end)

    local function Arrow(dir, point, x)
      local b = CreateFrame("Button", nil, panel)
      b:SetSize(24, 24)
      b:SetPoint(point, x, -6)
      b:SetFrameLevel(drag:GetFrameLevel() + 2)
      local tex = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-"
      b:SetNormalTexture(tex .. "Up")
      b:SetPushedTexture(tex .. "Down")
      b:SetDisabledTexture(tex .. "Disabled")
      b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
      b:SetScript("OnClick", function()
        adapter.Cycle(dir)
        FauxScrollFrame_SetOffset(panel.scroll, 0)
        panel:Refresh()
      end)
      return b
    end
    panel.prevButton = Arrow(-1, "TOPLEFT", 8)
    panel.nextButton = Arrow(1, "TOPRIGHT", -30)

    -- ESC closes the standalone window
    tinsert(UISpecialFrames, panel:GetName())
  end

  -- Tabs: own recipes / recipes learnable at the trainer -------------------------
  local function MakeTab(text, learn)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetHeight(20)
    b:SetText(text)
    b:SetScript("OnClick", function()
      ns.SetLearnMode(learn)
      FauxScrollFrame_SetOffset(panel.scroll, 0)
      panel:Refresh()
    end)
    return b
  end
  local tabMine = MakeTab("Meine Rezepte", false)
  tabMine:SetPoint("TOPLEFT", 10, -34)
  tabMine:SetPoint("TOPRIGHT", panel, "TOP", -2, -34)
  local tabLearn = MakeTab("Beim Lehrer lernbar", true)
  tabLearn:SetPoint("TOPLEFT", panel, "TOP", 2, -34)
  tabLearn:SetPoint("TOPRIGHT", -10, -34)
  tabLearn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Rezepte vom Lehrer, die du noch nicht kannst")
    GameTooltip:AddLine("Bewertet wie deine Rezepte (Händlerpreis minus Material) und verglichen mit deinem besten gelernten Rezept.", 1, 1, 1, true)
    GameTooltip:AddLine("Daten: Lehrer einmal besuchen (Kosten, Skill), Materialien aus dem Berufsfenster oder Crafter's Journal.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  tabLearn:SetScript("OnLeave", GameTooltip_Hide)

  -- Best recipe highlight -----------------------------------------------------
  local best = CreateFrame("Button", nil, panel, BACKDROP)
  best:SetPoint("TOPLEFT", 10, -60)
  best:SetPoint("TOPRIGHT", -10, -60)
  best:SetHeight(62)
  panel.bestBg = AddBackground(best, 0.25, 0.18, 0.02, 0.85, 3)
  AddBorder(best, 1, 0.82, 0, 1)
  best:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  best.icon = best:CreateTexture(nil, "ARTWORK")
  best.icon:SetSize(40, 40)
  best.icon:SetPoint("LEFT", 9, 0)
  best.label = best:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  best.label:SetPoint("TOPLEFT", best.icon, "TOPRIGHT", 8, 2)
  best.label:SetText("Platz 1 – bester Gewinn pro Stück")
  best.profit = best:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  best.profit:SetPoint("TOPRIGHT", -10, -8)
  best.profit:SetJustifyH("RIGHT")
  best.name = best:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  best.name:SetPoint("LEFT", best.icon, "RIGHT", 8, 0)
  best.name:SetPoint("RIGHT", best, "RIGHT", -10, 0)
  best.name:SetJustifyH("LEFT")
  best.name:SetWordWrap(false)
  best.detail = best:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  best.detail:SetPoint("BOTTOMLEFT", best.icon, "BOTTOMRIGHT", 8, -2)
  best.detail:SetPoint("RIGHT", best, "RIGHT", -10, 0)
  best.detail:SetJustifyH("LEFT")
  best.detail:SetWordWrap(false)
  best:SetScript("OnEnter", function(self) if self.entry then ShowTooltip(self, self.entry) end end)
  best:SetScript("OnLeave", GameTooltip_Hide)
  best:SetScript("OnClick", function(self) OnEntryClick(adapter, self.entry) end)
  panel.best = best

  -- Filters -------------------------------------------------------------------
  local y = -128
  local check1 = MakeCheck(panel, "Nur herstellbar", "onlyCraftable", 10, y)
  local check2 = MakeCheck(panel, "Nur mit Gewinn", "onlyProfit", 130, y)
  check2:SetScript("OnEnter", function(self)
    if self.key ~= "onlyBetter" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Nur Rezepte, die mehr Gewinn pro Stück bringen als dein bestes gelerntes Rezept.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  check2:SetScript("OnLeave", GameTooltip_Hide)
  if adapter.ExpandAll then
    -- Only classic windows hide recipes in collapsed categories.
    local cb = MakeCheck(panel, "Aufklappen", "autoExpand", 245, y)
    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Kategorien automatisch aufklappen")
      GameTooltip:AddLine("Klappt alle Kategorien im Berufsfenster auf, damit jedes Rezept bewertet wird.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", GameTooltip_Hide)
  end

  -- Column headers ------------------------------------------------------------
  local hName = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hName:SetPoint("TOPLEFT", 14, -156)
  hName:SetText("#   Rezept")
  local hProfit = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hProfit:SetPoint("TOPRIGHT", -34, -156)
  hProfit:SetText("Gewinn / Stück")
  local sep = panel:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(0.6, 0.5, 0.3, 0.6)
  sep:SetHeight(1)
  sep:SetPoint("TOPLEFT", 10, -170)
  sep:SetPoint("TOPRIGHT", -10, -170)

  -- List ----------------------------------------------------------------------
  local scroll = CreateFrame("ScrollFrame", "CraftSellScroll_" .. adapter.key, panel, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -174)
  scroll:SetPoint("BOTTOMRIGHT", -30, 52)
  scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function() panel:UpdateRows() end)
  end)
  scroll:SetScript("OnSizeChanged", function() panel:UpdateRows() end)
  panel.scroll = scroll

  panel.rows = {}
  for i = 1, MAX_ROWS do
    local row = CreateFrame("Button", nil, panel)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    AddBackground(row, 1, 1, 1, (i % 2 == 0) and 0.04 or 0)

    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.rank:SetPoint("LEFT", 0, 0)
    row.rank:SetWidth(22)
    row.rank:SetJustifyH("RIGHT")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(26, 26)
    row.icon:SetPoint("LEFT", row.rank, "RIGHT", 5, 0)
    row.profit = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.profit:SetPoint("TOPRIGHT", -2, -3)
    row.profit:SetJustifyH("RIGHT")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.profit, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, 0)
    row.detail:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row:SetScript("OnEnter", function(self) if self.entry then ShowTooltip(self, self.entry) end end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnClick", function(self) OnEntryClick(adapter, self.entry) end)
    row:Hide()
    panel.rows[i] = row
  end

  -- Daily gold tracker line --------------------------------------------------
  local ledger = CreateFrame("Button", nil, panel)
  ledger:SetPoint("BOTTOMLEFT", 8, 26)
  ledger:SetPoint("BOTTOMRIGHT", -8, 26)
  ledger:SetHeight(22)
  AddBackground(ledger, 0.2, 0.2, 0.2, 0.5)
  ledger:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  ledger.text = ledger:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ledger.text:SetPoint("LEFT", 6, 0)
  ledger.text:SetPoint("RIGHT", -6, 0)
  ledger.text:SetJustifyH("LEFT")
  ledger.text:SetWordWrap(false)
  ledger:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    ns.Ledger.FillTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  ledger:SetScript("OnLeave", GameTooltip_Hide)
  ledger:SetScript("OnClick", function() ns.Ledger.PrintSummary() end)
  function panel:UpdateLedger()
    ledger.text:SetText(ns.Ledger.TodayLine())
  end

  panel.status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  panel.status:SetPoint("BOTTOMLEFT", 12, 10)
  panel.status:SetPoint("BOTTOMRIGHT", -12, 10)
  panel.status:SetJustifyH("LEFT")
  panel.status:SetWordWrap(false)

  panel.list = {}

  function panel:Refresh()
    self:Reanchor()
    self:UpdateLedger()
    if adapter.Title then self.title:SetText(adapter.Title()) end
    if self.prevButton then
      local multiple = adapter.Count and adapter.Count() > 1
      self.prevButton:SetEnabled(multiple)
      self.nextButton:SetEnabled(multiple)
    end
    local learn = CraftSellDB.learnMode and true or false
    self.learn = learn
    if learn then
      tabLearn:LockHighlight()
      tabMine:UnlockHighlight()
      check1:SetKey("onlyLearnable", "Nur jetzt lernbar")
      check2:SetKey("onlyBetter", "Nur lohnend")
      best.label:SetText("Bestes lernbares Rezept")
    else
      tabMine:LockHighlight()
      tabLearn:UnlockHighlight()
      check1:SetKey("onlyCraftable", "Nur herstellbar")
      check2:SetKey("onlyProfit", "Nur mit Gewinn")
      best.label:SetText("Platz 1 – bester Gewinn pro Stück")
    end

    local all = ns.Scan(self.adapter)
    local list, sources, nBetter = {}, nil, 0
    if learn then
      local top
      for _, e in ipairs(all) do
        if e.profitItem and not e.unknownCost then top = e break end
      end
      local prof = adapter.ProfessionName and adapter.ProfessionName()
      local learnable
      learnable, sources = ns.Learn.Scan(prof, all, top)
      for _, e in ipairs(learnable) do
        if e.better then nBetter = nBetter + 1 end
        local ok = true
        if CraftSellDB.onlyLearnable and not e.canLearn then ok = false end
        if CraftSellDB.onlyBetter and not e.better then ok = false end
        if ok then list[#list + 1] = e end
      end
    else
      for _, e in ipairs(all) do
        UpdateTrend(adapter.key .. ":" .. tostring(e.id) .. ":" .. tostring(e.output), e)
        local ok = true
        if CraftSellDB.onlyCraftable and (e.numAvailable or 0) <= 0 then ok = false end
        if CraftSellDB.onlyProfit and not (e.profitItem and e.profitItem > 0) then ok = false end
        if ok then list[#list + 1] = e end
      end
    end
    self.list = list

    local top = list[1]
    if top and top.profitItem then
      best.entry = top
      best.icon:SetTexture(top.icon)
      best.name:SetText(learn and LearnName(top) or Colorize(top))
      best.profit:SetText(ProfitText(top))
      best.detail:SetText(learn and LearnDetailText(top) or DetailText(top))
    else
      local empty = adapter.EmptyText and adapter.EmptyText() or "Kein passendes Rezept"
      if learn and sources and not (sources.trainer or sources.cj) then
        empty = "Besuche einmal einen Lehrer dieses Berufs"
      end
      best.entry = nil
      best.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      best.name:SetText("|cff888888" .. empty .. "|r")
      best.profit:SetText("")
      best.detail:SetText("")
    end

    if not P.HasPriceAddon() then
      self.status:SetText("|cffff8000Auctionator/Auctioneer nicht geladen – nur Händlerpreise.|r")
    elseif learn then
      local hint = ""
      if sources and not sources.learned then
        hint = "  ·  |cffff8000Beruf einmal öffnen!|r"
      end
      self.status:SetText(string.format("%d lernbar  ·  |cff40ff40%d lohnend|r%s  ·  %s",
        #list, nBetter, hint, date("%H:%M:%S")))
    else
      self.status:SetText(string.format("%d Rezepte  ·  * = Preis fehlt  ·  aktualisiert %s",
        #list, date("%H:%M:%S")))
    end
    self:UpdateRows()
  end

  function panel:UpdateRows()
    local list = self.list or {}
    local visible = math.max(1, math.min(MAX_ROWS, math.floor((scroll:GetHeight() or 0) / ROW_H)))
    FauxScrollFrame_Update(scroll, #list, visible, ROW_H)
    local offset = FauxScrollFrame_GetOffset(scroll) or 0
    for i = 1, MAX_ROWS do
      local row = self.rows[i]
      local e = (i <= visible) and list[offset + i] or nil
      row.entry = e
      if e then
        local rank = offset + i
        row.rank:SetText(rank == 1 and "|cffffd2001|r" or tostring(rank))
        row.icon:SetTexture(e.icon)
        if e.learn then
          row.name:SetText(LearnName(e))
          row.detail:SetText(LearnDetailText(e))
        else
          local name = Colorize(e)
          if (e.numAvailable or 0) > 0 then name = name .. " |cff80ff80[" .. e.numAvailable .. "]|r" end
          row.name:SetText(name)
          row.detail:SetText(DetailText(e))
        end
        row.profit:SetText(ProfitText(e))
        row:Show()
      else
        row:Hide()
      end
    end
  end

  -- Auto refresh while visible: picks up new AH prices (Auctionator and
  -- Auctioneer) even when no event tells us about them.
  panel:SetScript("OnShow", function(self)
    ns.ScheduleRefresh(0.05)
    if not self.ticker and C_Timer.NewTicker then
      self.ticker = C_Timer.NewTicker(10, function() ns.ScheduleRefresh(0) end)
    end
  end)
  panel:SetScript("OnHide", function(self)
    if self.ticker then
      self.ticker:Cancel()
      self.ticker = nil
    end
  end)
  -- closed while dragging (ESC): finish the move, or the flag would stick
  panel:HookScript("OnHide", SaveGeometry)
  if panel:IsShown() and C_Timer.NewTicker then
    panel.ticker = C_Timer.NewTicker(10, function() ns.ScheduleRefresh(0) end)
  end
  if adapter.standalone then
    -- remember open/closed state (X button, ESC, minimap click)
    panel:HookScript("OnHide", function() CraftSellDB.standaloneShown = false end)
    panel:HookScript("OnShow", function() CraftSellDB.standaloneShown = true end)
  end
  panel:ApplyAlpha()
  return panel
end
