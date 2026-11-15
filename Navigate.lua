-- CraftSell: click a reagent in Blizzard's recipe details to jump to the
-- recipe that crafts it (e.g. "Geschmeidiger mittlerer Balg").
-- A "< Zurück" button returns to the previous recipe.
local ADDON, ns = ...

local producerCache      -- itemID -> { recipeID, name }
local history = {}       -- recipe IDs we came from
local backButton
local hookedForm = false

local function InvalidateCache()
  producerCache = nil
end

local function BuildCache()
  producerCache = {}
  if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs) then return end
  for _, id in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
    local info = C_TradeSkillUI.GetRecipeInfo(id)
    if info and info.learned then
      local s = C_TradeSkillUI.GetRecipeSchematic(id, false)
      local out = s and s.outputItemID
      if out and not producerCache[out] then
        producerCache[out] = { recipeID = id, name = info.name }
      end
    end
  end
end

local function Producer(itemID)
  if not itemID then return nil end
  if not producerCache then BuildCache() end
  return producerCache[itemID]
end

local function Form()
  return ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
end

local function CurrentRecipeID()
  local form = Form()
  if form and form.GetRecipeInfo then
    local ok, info = pcall(form.GetRecipeInfo, form)
    if ok and info then return info.recipeID end
  end
end

-- Select a recipe in the open profession window.
-- Local selection in Blizzard's list is instant; C_TradeSkillUI.OpenRecipe
-- may reload the whole profession from the server (slow), so it is only
-- used as a last resort.
local function OpenRecipe(recipeID)
  local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
  local info = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
  local list = page and page.RecipeList

  local attempts = {
    function() if list and list.SelectRecipe and info then list:SelectRecipe(info, true) end end,
    function() if list and list.SelectRecipeID then list:SelectRecipeID(recipeID) end end,
    function() if page and page.SelectRecipe and info then page:SelectRecipe(info) end end,
  }
  for _, try in ipairs(attempts) do
    pcall(try)
    if CurrentRecipeID() == recipeID then return end
  end
  if C_TradeSkillUI.OpenRecipe then pcall(C_TradeSkillUI.OpenRecipe, recipeID) end
end
ns.OpenModernRecipe = OpenRecipe

local function UpdateBackButton()
  if not backButton then return end
  backButton:SetShown(#history > 0)
end

local function JumpTo(recipeID)
  local current = CurrentRecipeID()
  if current and current ~= recipeID then
    table.insert(history, current)
    if #history > 20 then table.remove(history, 1) end
  end
  OpenRecipe(recipeID)
  UpdateBackButton()
end

local function SlotItemID(slot)
  local ok, schematic = pcall(slot.GetReagentSlotSchematic, slot)
  local first = ok and schematic and schematic.reagents and schematic.reagents[1]
  return first and first.itemID
end

-- Hook one reagent slot (slots are pooled and reused, so hook each once and
-- read the slot's current reagent at click time).
local function HookSlot(slot)
  local button = slot.Button or slot
  if button.craftSellHooked then return end
  button.craftSellHooked = true

  button:HookScript("OnMouseUp", function(self, mouseButton)
    if mouseButton ~= "LeftButton" or IsModifierKeyDown() or not self:IsMouseOver() then return end
    local p = Producer(SlotItemID(slot))
    if p and p.recipeID ~= CurrentRecipeID() then
      JumpTo(p.recipeID)
    end
  end)

  button:HookScript("OnEnter", function()
    local p = Producer(SlotItemID(slot))
    if p and p.recipeID ~= CurrentRecipeID() and GameTooltip:IsOwned(button) then
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("|cffffd200CraftSell:|r Klick öffnet Rezept „" .. (p.name or "?") .. "“", 0.5, 0.8, 1, true)
      GameTooltip:Show()
    end
  end)
end

-- Find all reagent slots below the schematic form (structure differs a bit
-- between client versions, so search instead of relying on field names).
local function ScanForSlots(frame, depth)
  if depth > 7 then return end
  for _, child in ipairs({ frame:GetChildren() }) do
    if type(child.GetReagentSlotSchematic) == "function" then
      HookSlot(child)
    else
      ScanForSlots(child, depth + 1)
    end
  end
end

local function CreateBackButton(form)
  backButton = CreateFrame("Button", "CraftSellBackButton", form, "UIPanelButtonTemplate")
  backButton:SetSize(110, 22)
  backButton:SetPoint("TOPRIGHT", form, "TOPRIGHT", -12, -44)
  backButton:SetText("< Zurück")
  backButton:SetScript("OnClick", function()
    local id = table.remove(history)
    if id then OpenRecipe(id) end
    UpdateBackButton()
  end)
  backButton:SetScript("OnEnter", function(self)
    local id = history[#history]
    local info = id and C_TradeSkillUI.GetRecipeInfo(id)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Zurück zu: " .. (info and info.name or "?"))
    GameTooltip:Show()
  end)
  backButton:SetScript("OnLeave", GameTooltip_Hide)
  backButton:Hide()
end

local function TryHookForm()
  local form = Form()
  if hookedForm or not form or not form.Init then return end
  hookedForm = true
  CreateBackButton(form)
  hooksecurefunc(form, "Init", function()
    -- slots are (re)built during Init; scan on the next frame
    C_Timer.After(0, function() ScanForSlots(form, 0) end)
  end)
  ScanForSlots(form, 0)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
                     "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_CLOSE" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if event == "ADDON_LOADED" or event == "TRADE_SKILL_SHOW" then
    C_Timer.After(0, TryHookForm)
    if event == "TRADE_SKILL_SHOW" then InvalidateCache() end
  elseif event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "TRADE_SKILL_CLOSE" then
    -- other profession / window closed: old history no longer applies.
    -- (Only wipe when the profession really changed – opening a recipe may
    -- fire this event as well.)
    InvalidateCache()
    local prof
    if event ~= "TRADE_SKILL_CLOSE" and C_TradeSkillUI.GetBaseProfessionInfo then
      local info = C_TradeSkillUI.GetBaseProfessionInfo()
      prof = info and (info.professionID or info.professionName)
    end
    if event == "TRADE_SKILL_CLOSE" or prof ~= ns.navProfession then
      wipe(history)
      UpdateBackButton()
    end
    ns.navProfession = prof
  end
  -- TRADE_SKILL_LIST_UPDATE fires on every selection: keep the cache (the
  -- set of learned recipes doesn't change by clicking around).
end)
pcall(ev.RegisterEvent, ev, "NEW_RECIPE_LEARNED")
ev:HookScript("OnEvent", function(_, event)
  if event == "NEW_RECIPE_LEARNED" then InvalidateCache() end
end)
