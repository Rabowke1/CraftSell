-- CraftSell: recipe scanning + events
local ADDON, ns = ...
local P = ns.Prices

-- Every adapter returns raw recipes in the same shape:
-- { id, name, kind, numAvailable, icon, output (itemID or link), made,
--   reagents = { { item, count, name, icon }, ... } }

local DIFFICULTY = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }

-- Output item, average amount made and mandatory reagents of a recipe (spell
-- ID) via C_TradeSkillUI; nil when the client has no schematic for it.
function ns.ReadSchematic(recipeID)
  if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic) then return nil end
  local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  local output = ok and schematic and schematic.outputItemID
  if not output then return nil end
  local lo = schematic.quantityMin or 1
  if lo < 1 then lo = 1 end
  local hi = schematic.quantityMax or lo
  if hi < lo then hi = lo end
  local isBasic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
  local reagents = {}
  for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
    local first = slot.reagents and slot.reagents[1]
    local mandatory = slot.required or (isBasic ~= nil and slot.reagentType == isBasic)
    if mandatory and first and first.itemID then
      reagents[#reagents + 1] = {
        item = first.itemID,
        count = slot.quantityRequired or 1,
        icon = C_Item.GetItemIconByID and C_Item.GetItemIconByID(first.itemID),
      }
    end
  end
  return output, (lo + hi) / 2, reagents
end

-- ---------------------------------------------------------------------------
-- Modern profession window (ProfessionsFrame / C_TradeSkillUI) – used by the
-- "Forever" client. Returns ALL learned recipes, regardless of collapsed
-- categories or list filters.
local ModernAdapter = {
  key = "modern",
  frameName = "ProfessionsFrame",
  anchor = { 0, -2, 0, 2 },
  Available = function()
    return C_TradeSkillUI ~= nil and C_TradeSkillUI.GetAllRecipeIDs ~= nil
      and C_TradeSkillUI.GetRecipeSchematic ~= nil
  end,
  GetRecipes = function()
    local out = {}
    if C_TradeSkillUI.IsTradeSkillReady and not C_TradeSkillUI.IsTradeSkillReady() then
      ns.pendingItemData = true
      return out
    end
    -- Not yet learned recipes (if the client lists them): their reagents are
    -- needed to rate recipes you could learn at the trainer (Learn.lua).
    local unlearned = {}
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
      local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
      if info and not info.isDummyRecipe and not info.isRecraft and not info.isSalvageRecipe then
        local output, made, reagents = ns.ReadSchematic(recipeID)
        if output then
          local rec = {
            id = recipeID,
            name = info.name,
            kind = DIFFICULTY[info.relativeDifficulty],
            numAvailable = info.numAvailable or 0,
            icon = info.icon,
            output = output,
            made = made,
            reagents = reagents,
          }
          if info.learned then
            out[#out + 1] = rec
          else
            unlearned[#unlearned + 1] = rec
          end
        end
      end
    end
    if ns.CacheRecipes then ns.CacheRecipes(out, unlearned) end
    return out
  end,
  Select = function(recipeID)
    -- fast local selection, OpenRecipe only as fallback (see Navigate.lua)
    if ns.OpenModernRecipe then
      ns.OpenModernRecipe(recipeID)
    elseif C_TradeSkillUI.OpenRecipe then
      pcall(C_TradeSkillUI.OpenRecipe, recipeID)
    end
  end,
}

-- ---------------------------------------------------------------------------
-- Classic windows (TradeSkillFrame / CraftFrame) – fallback for other clients.
local function ClassicRecipes(api)
  local out = {}
  for i = 1, api.Num() do
    local name, kind, numAvailable = api.Info(i)
    if name and kind ~= "header" and kind ~= "subheader" then
      local link = api.ItemLink(i)
      if link and link:find("item:") then
        local reagents = {}
        for r = 1, api.NumReagents(i) do
          local rName, rTex, rCount, rLink = api.Reagent(i, r)
          if rLink then
            reagents[#reagents + 1] = { item = rLink, count = rCount or 1, name = rName, icon = rTex }
          end
        end
        out[#out + 1] = {
          id = i, name = name, kind = kind, numAvailable = numAvailable or 0,
          icon = api.Icon(i), output = link, made = api.NumMade(i), reagents = reagents,
        }
      end
    end
  end
  return out
end

local TradeSkillAdapter = {
  key = "trade",
  frameName = "TradeSkillFrame",
  anchor = { -34, -12, -34, 72 },
  Available = function() return GetNumTradeSkills ~= nil end,
  GetRecipes = function()
    return ClassicRecipes({
      Num = GetNumTradeSkills,
      Info = function(i) local n, k, a = GetTradeSkillInfo(i); return n, k, a end,
      ItemLink = GetTradeSkillItemLink,
      NumMade = function(i)
        local lo, hi = GetTradeSkillNumMade(i)
        lo = lo or 1
        return (lo + (hi or lo)) / 2
      end,
      NumReagents = GetTradeSkillNumReagents,
      Reagent = function(i, r)
        local n, t, c = GetTradeSkillReagentInfo(i, r)
        return n, t, c, GetTradeSkillReagentItemLink(i, r)
      end,
      Icon = GetTradeSkillIcon,
    })
  end,
  ExpandAll = function()
    if not ExpandTradeSkillSubClass then return end
    local changed = false
    for i = GetNumTradeSkills(), 1, -1 do
      local _, kind, _, isExpanded = GetTradeSkillInfo(i)
      if kind == "header" and not isExpanded then
        ExpandTradeSkillSubClass(i)
        changed = true
      end
    end
    if changed and TradeSkillFrame_Update then pcall(TradeSkillFrame_Update) end
  end,
  Select = function(i)
    if TradeSkillFrame_SetSelection then
      TradeSkillFrame_SetSelection(i)
      if TradeSkillFrame_Update then TradeSkillFrame_Update() end
    end
  end,
}

local CraftAdapter = {
  key = "craft",
  frameName = "CraftFrame",
  anchor = { -34, -12, -34, 72 },
  Available = function() return GetNumCrafts ~= nil end,
  GetRecipes = function()
    return ClassicRecipes({
      Num = GetNumCrafts,
      Info = function(i) local n, _, k, a = GetCraftInfo(i); return n, k, a end,
      ItemLink = GetCraftItemLink,
      NumMade = function() return 1 end,
      NumReagents = GetCraftNumReagents,
      Reagent = function(i, r)
        local n, t, c = GetCraftReagentInfo(i, r)
        return n, t, c, GetCraftReagentItemLink(i, r)
      end,
      Icon = GetCraftIcon,
    })
  end,
  ExpandAll = function()
    if not ExpandCraftSkillLine then return end
    local changed = false
    for i = GetNumCrafts(), 1, -1 do
      local _, _, kind, _, isExpanded = GetCraftInfo(i)
      if kind == "header" and not isExpanded then
        ExpandCraftSkillLine(i)
        changed = true
      end
    end
    if changed and CraftFrame_Update then pcall(CraftFrame_Update) end
  end,
  Select = function(i)
    if CraftFrame_SetSelection then
      CraftFrame_SetSelection(i)
      if CraftFrame_Update then CraftFrame_Update() end
    end
  end,
}

local ADAPTERS = { ModernAdapter, TradeSkillAdapter, CraftAdapter }

-- ---------------------------------------------------------------------------
-- Recipe cache: lets the standalone window (minimap button) work without the
-- profession window being open. Stored per character and profession in
-- CraftSellDB.cache. Only static recipe data is stored; prices and the
-- craftable count are always computed live.
local function CurrentProfessionName()
  if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if ok and info and info.professionName and info.professionName ~= "" then
      return info.professionName
    end
  end
  local tc = ProfessionsFrame and ProfessionsFrame.TitleContainer and ProfessionsFrame.TitleContainer.TitleText
  local title = tc and tc:GetText()
  if title and title ~= "" then return title end
end
ns.CurrentProfessionName = CurrentProfessionName

local function CopyRecipes(list)
  local copy = {}
  for i, rec in ipairs(list) do
    local reagents = {}
    for j, r in ipairs(rec.reagents) do
      reagents[j] = { item = r.item, count = r.count, icon = r.icon }
    end
    copy[i] = {
      id = rec.id, name = rec.name, kind = rec.kind, icon = rec.icon,
      output = rec.output, made = rec.made, reagents = reagents,
    }
  end
  return copy
end

function ns.CacheRecipes(list, unlearned)
  if #list == 0 then return end
  local prof = CurrentProfessionName()
  if not prof then return end
  local char = ns.Ledger.CharKey()
  CraftSellDB.cache = CraftSellDB.cache or {}
  CraftSellDB.cache[char] = CraftSellDB.cache[char] or {}
  CraftSellDB.cache[char][prof] = {
    recipes = CopyRecipes(list),
    unlearned = unlearned and #unlearned > 0 and CopyRecipes(unlearned) or nil,
    time = time(),
  }
  CraftSellDB.cacheSelected = CraftSellDB.cacheSelected or {}
  CraftSellDB.cacheSelected[char] = prof
end

local function CachedProfessions()
  local data = CraftSellDB.cache and CraftSellDB.cache[ns.Ledger.CharKey()] or {}
  local list = {}
  for name in pairs(data) do list[#list + 1] = name end
  table.sort(list)
  return list, data
end

local function SelectedProfession()
  local list, data = CachedProfessions()
  local sel = CraftSellDB.cacheSelected and CraftSellDB.cacheSelected[ns.Ledger.CharKey()]
  if sel and data[sel] then return sel, list, data end
  return list[1], list, data
end

local GetCount = (C_Item and C_Item.GetItemCount) or GetItemCount

local CacheAdapter = {
  key = "cache",
  standalone = true,
  anchor = { 0, 0, 0, 0 },
  Available = function() return true end,
  Title = function()
    local prof = SelectedProfession()
    return "CraftSell – " .. (prof or "kein Beruf")
  end,
  Count = function() return #(CachedProfessions()) end,
  EmptyText = function()
    if SelectedProfession() then return "Kein passendes Rezept" end
    return "Öffne einmal deine Berufe"
  end,
  Cycle = function(dir)
    local sel, list = SelectedProfession()
    if #list == 0 then return end
    local idx = 1
    for i, name in ipairs(list) do
      if name == sel then idx = i end
    end
    idx = ((idx - 1 + dir) % #list) + 1
    CraftSellDB.cacheSelected = CraftSellDB.cacheSelected or {}
    CraftSellDB.cacheSelected[ns.Ledger.CharKey()] = list[idx]
  end,
  GetRecipes = function()
    local sel, _, data = SelectedProfession()
    local out = {}
    local entry = sel and data[sel]
    if not entry then return out end
    for i, rec in ipairs(entry.recipes) do
      -- fresh copies: the scan adds computed fields we must not save
      local reagents, avail = {}, nil
      for j, r in ipairs(rec.reagents) do
        reagents[j] = { item = r.item, count = r.count, icon = r.icon }
        local have = GetCount(r.item) or 0
        local n = math.floor(have / math.max(r.count or 1, 1))
        avail = avail and math.min(avail, n) or n
      end
      out[i] = {
        id = rec.id, name = rec.name, kind = rec.kind, icon = rec.icon,
        output = rec.output, made = rec.made, numAvailable = avail or 0,
        reagents = reagents,
      }
    end
    return out
  end,
  Select = function(recipeID)
    if ProfessionsFrame and ProfessionsFrame:IsShown() and ns.OpenModernRecipe then
      ns.OpenModernRecipe(recipeID)
    elseif C_TradeSkillUI and C_TradeSkillUI.OpenRecipe then
      pcall(C_TradeSkillUI.OpenRecipe, recipeID)
    end
  end,
}

-- ---------------------------------------------------------------------------
-- Cheapest way to get one unit of a reagent: buy it (vendor/AH) or craft it
-- yourself with one of the given (learned) recipes – recursive, cycle-safe.
-- Also used by Learn.lua to price recipes that are not learned yet.
function ns.NewCoster(recipes)
  local byOutput = {}
  for _, rec in ipairs(recipes) do
    rec.outputID = P.ItemIDFromLink(rec.output)
    if rec.outputID then
      byOutput[rec.outputID] = byOutput[rec.outputID] or {}
      table.insert(byOutput[rec.outputID], rec)
    end
    for _, r in ipairs(rec.reagents) do
      r.itemID = P.ItemIDFromLink(r.item)
    end
  end

  local memo = {}
  local RecipeCost
  local function ReagentUnit(itemID, visiting)
    local market, marketSrc = P.GetReagentPrice(itemID)
    if CraftSellDB.usePaid then
      -- rate with what was really paid (auction invoices from the mailbox)
      local paid = ns.Mail.PaidUnit(itemID)
      if paid then return paid, ns.Mail.SRC, nil, market, marketSrc end
    end
    local best, src, via = market, marketSrc, nil
    for _, sub in ipairs(byOutput[itemID] or {}) do
      if not visiting[sub] then
        local c, unk = RecipeCost(sub, visiting)
        if c and not unk then
          local u = c / sub.made
          if not best or u < best then best, src, via = u, "selbst herstellen", sub end
        end
      end
    end
    return best, src, via, market, marketSrc
  end
  RecipeCost = function(rec, visiting)
    if memo[rec] then return memo[rec][1], memo[rec][2] end
    visiting[rec] = true
    local cost, unknown = 0, false
    for _, r in ipairs(rec.reagents) do
      local u = r.itemID and ReagentUnit(r.itemID, visiting)
      if u then cost = cost + u * r.count else unknown = true end
    end
    visiting[rec] = nil
    memo[rec] = { cost, unknown }
    return cost, unknown
  end

  -- Prices a reagent list in place (unit, src, via, market, name) and
  -- returns the total cost and whether a price is missing.
  local function PriceReagents(reagents, visiting)
    local cost, unknown = 0, false
    for _, r in ipairs(reagents) do
      r.itemID = r.itemID or P.ItemIDFromLink(r.item)
      if r.itemID then
        r.unit, r.src, r.via, r.market, r.marketSrc = ReagentUnit(r.itemID, visiting)
        r.paid = ns.Mail.PaidUnit(r.itemID)
      end
      if r.unit then
        cost = cost + r.unit * r.count
      else
        unknown = true
      end
      if not r.name and r.itemID and C_Item and C_Item.GetItemNameByID then
        r.name = C_Item.GetItemNameByID(r.itemID)
      end
    end
    return cost, unknown
  end

  return { PriceReagents = PriceReagents }
end

-- Rank: complete prices first, then by profit per item (desc).
function ns.SortByProfit(results)
  local function tier(e)
    if e.profitItem and not e.unknownCost then return 0 end
    if e.profitItem then return 1 end
    return 2
  end
  table.sort(results, function(a, b)
    local ta, tb = tier(a), tier(b)
    if ta ~= tb then return ta < tb end
    local pa, pb = a.profitItem or -math.huge, b.profitItem or -math.huge
    if pa ~= pb then return pa > pb end
    return (a.name or "") < (b.name or "")
  end)
end

-- ---------------------------------------------------------------------------
-- Price every recipe and rank by profit per produced item.
function ns.Scan(adapter)
  ns.pendingItemData = false
  if CraftSellDB.autoExpand and adapter.ExpandAll then adapter.ExpandAll() end

  local recipes = adapter.GetRecipes()
  local coster = ns.NewCoster(recipes)

  -- Items used as reagents -> intermediate products like cured hides.
  local usedAsReagent = {}
  for _, rec in ipairs(recipes) do
    for _, r in ipairs(rec.reagents) do
      if r.itemID then usedAsReagent[r.itemID] = true end
    end
  end

  CraftSellDB.reagentIDs = CraftSellDB.reagentIDs or {}
  CraftSellDB.craftedIDs = CraftSellDB.craftedIDs or {}
  CraftSellDB.recipes = CraftSellDB.recipes or {}

  local results = {}
  for _, rec in ipairs(recipes) do
    local cost, unknown = coster.PriceReagents(rec.reagents, { [rec] = true })
    for _, r in ipairs(rec.reagents) do
      if r.itemID then CraftSellDB.reagentIDs[r.itemID] = true end
    end

    rec.cost = cost
    rec.unknownCost = unknown
    rec.isIntermediate = rec.outputID ~= nil and usedAsReagent[rec.outputID] == true
    if rec.outputID then CraftSellDB.craftedIDs[rec.outputID] = true end
    -- remember for the gold tracker (modern recipeID == spellID of the craft)
    -- (with the modern API recipe IDs are spell IDs – live and cached data)
    if ModernAdapter.Available() and not unknown then
      CraftSellDB.recipes[rec.id] = { cost = cost, made = rec.made, inter = rec.isIntermediate or nil }
    end
    rec.sellUnit = P.GetVendorSellPrice(rec.output)
    if rec.sellUnit then
      rec.sellTotal = rec.sellUnit * rec.made
      rec.profitCraft = rec.sellTotal - cost
      rec.profitItem = rec.sellUnit - cost / rec.made   -- main ranking metric
    end
    results[#results + 1] = rec
  end

  ns.SortByProfit(results)
  return results
end

-- ---------------------------------------------------------------------------
local panels = {}
local refreshPending = false

local function Report(msg)
  print("|cffffd200CraftSell|r: " .. msg)
end

local function RefreshAll()
  refreshPending = false
  for _, panel in pairs(panels) do
    if panel:IsShown() then
      local ok, err = pcall(panel.Refresh, panel)
      if not ok and not ns.reportedError then
        ns.reportedError = true
        Report("|cffff4040Fehler:|r " .. tostring(err))
      end
    end
  end
  if ns.pendingItemData then
    -- some item info still loading from the server; try again shortly
    ns.ScheduleRefresh(1.0)
  end
end

function ns.ApplyAlphaAll()
  for _, panel in pairs(panels) do
    if panel.ApplyAlpha then panel:ApplyAlpha() end
  end
end

function ns.OnLedgerChanged()
  for _, panel in pairs(panels) do
    if panel.UpdateLedger then pcall(panel.UpdateLedger, panel) end
  end
end

function ns.ScheduleRefresh(delay)
  if refreshPending then return end
  refreshPending = true
  C_Timer.After(delay or 0.15, RefreshAll)
end

local function InitDB()
  CraftSellDB = CraftSellDB or {}
  CraftSellDB.vendorBuy = CraftSellDB.vendorBuy or {}
  if CraftSellDB.onlyCraftable == nil then CraftSellDB.onlyCraftable = false end
  if CraftSellDB.onlyProfit == nil then CraftSellDB.onlyProfit = false end
  if CraftSellDB.autoExpand == nil then CraftSellDB.autoExpand = true end
end

-- The profession window that is currently open (adapter), if any.
local function OpenProfessionAdapter()
  for _, adapter in ipairs(ADAPTERS) do
    local frame = _G[adapter.frameName]
    if frame and frame:IsShown() and adapter.Available() then return adapter end
  end
end

-- ---------------------------------------------------------------------------
-- ONE window for everything:
--   profession window open  -> live data of that profession (and docks next
--                              to it, unless the user placed it elsewhere)
--   no profession window    -> cached recipes, arrows switch profession
local MainAdapter = {
  key = "main",
  standalone = true,
  Available = function() return true end,
  IsLive = function() return OpenProfessionAdapter() ~= nil end,
  DockFrame = function()
    local live = OpenProfessionAdapter()
    if live then return _G[live.frameName], live.anchor end
    if ns.Learn.TrainerOpen() and ClassTrainerFrame and ClassTrainerFrame:IsShown() then
      -- classic trainer frame has transparent margins like TradeSkillFrame
      local modern = ClassTrainerFrame.NineSlice ~= nil
      return ClassTrainerFrame, modern and { 0, -2, 0, 2 } or { -34, -12, -34, 72 }
    end
  end,
  -- Profession shown: open profession window > open trainer > cached choice.
  ProfessionName = function()
    if OpenProfessionAdapter() then return CurrentProfessionName() end
    if ns.Learn.TrainerOpen() then return ns.Learn.trainerProf end
    return (SelectedProfession())
  end,
  Title = function()
    if OpenProfessionAdapter() then
      return "CraftSell – " .. (CurrentProfessionName() or "Beruf")
    end
    if ns.Learn.TrainerOpen() then return "CraftSell – " .. ns.Learn.trainerProf end
    return CacheAdapter.Title()
  end,
  Count = function()
    -- no switching while a profession or trainer window is open
    if OpenProfessionAdapter() or ns.Learn.TrainerOpen() then return 1 end
    return CacheAdapter.Count()
  end,
  EmptyText = function()
    if OpenProfessionAdapter() then return "Kein passendes Rezept" end
    return CacheAdapter.EmptyText()
  end,
  Cycle = function(dir)
    if not (OpenProfessionAdapter() or ns.Learn.TrainerOpen()) then CacheAdapter.Cycle(dir) end
  end,
  GetRecipes = function()
    local live = OpenProfessionAdapter()
    if live then
      if CraftSellDB.autoExpand and live.ExpandAll then live.ExpandAll() end
      return live.GetRecipes()
    end
    -- at a trainer whose profession was never opened: nothing cached for it
    if ns.Learn.TrainerOpen() and SelectedProfession() ~= ns.Learn.trainerProf then return {} end
    return CacheAdapter.GetRecipes()
  end,
  Select = function(recipeID)
    local live = OpenProfessionAdapter()
    if live then live.Select(recipeID) else CacheAdapter.Select(recipeID) end
  end,
}

local mainPanel
local openedByProfession = false

local function GetPanel()
  if mainPanel then return mainPanel end
  InitDB()
  local ok, panelOrErr = pcall(ns.CreatePanel, UIParent, MainAdapter)
  if not ok then
    Report("|cffff4040Fehler beim Erstellen des Fensters:|r " .. tostring(panelOrErr))
    return
  end
  mainPanel = panelOrErr
  panels.main = mainPanel
  mainPanel:Hide()
  return mainPanel
end

-- Minimap button / "/cs" / "/cs fenster": show or hide the window.
function ns.ToggleStandalone(show)
  local panel = GetPanel()
  if not panel then return end
  if show == nil then show = not panel:IsShown() end
  openedByProfession = false          -- opened by the user: stays open
  panel:SetShown(show)
  if show then ns.ScheduleRefresh(0) end
end

local function OnProfessionShow()
  if not OpenProfessionAdapter() then return end
  local panel = GetPanel()
  if not panel then return end
  if not panel:IsShown() and CraftSellDB.autoOpen ~= false then
    openedByProfession = true
    panel:Show()
    -- opened automatically: do not reopen it on the next login
    CraftSellDB.standaloneShown = false
  end
  ns.ScheduleRefresh(0.05)
end

local function OnProfessionHide()
  if OpenProfessionAdapter() then return end
  if mainPanel and mainPanel:IsShown() then
    if openedByProfession then
      mainPanel:Hide()                  -- came with the profession window, goes with it
    else
      ns.ScheduleRefresh(0.05)          -- user's window: switch to cached data
    end
  end
  openedByProfession = false
end

-- Profession trainer opened: show what is worth learning there.
local modeBeforeTrainer
local function OnTrainerShow(prof)
  if OpenProfessionAdapter() then
    ns.ScheduleRefresh(0.05)
    return
  end
  local char = ns.Ledger.CharKey()
  local _, data = CachedProfessions()
  if data[prof] then
    CraftSellDB.cacheSelected = CraftSellDB.cacheSelected or {}
    CraftSellDB.cacheSelected[char] = prof
  end
  local panel = GetPanel()
  if not panel then return end
  if modeBeforeTrainer == nil then modeBeforeTrainer = CraftSellDB.learnMode or false end
  CraftSellDB.learnMode = true
  if not panel:IsShown() and CraftSellDB.autoOpen ~= false then
    openedByProfession = true
    panel:Show()
    CraftSellDB.standaloneShown = false
  end
  panel.anchoredExtra = nil
  ns.ScheduleRefresh(0.05)
end

local function OnTrainerHide()
  ns.Learn.trainerProf = nil
  if modeBeforeTrainer ~= nil then
    CraftSellDB.learnMode = modeBeforeTrainer
    modeBeforeTrainer = nil
  end
  if OpenProfessionAdapter() then return end
  if mainPanel and mainPanel:IsShown() then
    if openedByProfession then
      mainPanel:Hide()
    else
      mainPanel.anchoredExtra = nil
      ns.ScheduleRefresh(0.05)
    end
  end
  openedByProfession = false
end

-- The tab buttons in the panel: the user's choice outlives the trainer visit.
function ns.SetLearnMode(on)
  CraftSellDB.learnMode = on and true or false
  modeBeforeTrainer = nil
end

-- Hook the profession frames as soon as they exist.
local hooked = {}
local function TryHookFrames()
  for _, adapter in ipairs(ADAPTERS) do
    local frame = _G[adapter.frameName]
    if frame and not hooked[adapter.key] and adapter.Available() then
      hooked[adapter.key] = true
      frame:HookScript("OnShow", function() C_Timer.After(0, OnProfessionShow) end)
      frame:HookScript("OnHide", function() C_Timer.After(0, OnProfessionHide) end)
      if frame:IsShown() then C_Timer.After(0, OnProfessionShow) end
    end
  end
end

local ev = CreateFrame("Frame")
-- Register defensively: an event unknown to this client must not abort loading.
for _, e in ipairs({
  "ADDON_LOADED", "PLAYER_LOGIN",
  "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED",
  "CRAFT_SHOW", "CRAFT_UPDATE",
  "BAG_UPDATE_DELAYED", "GET_ITEM_INFO_RECEIVED",
  "MERCHANT_SHOW", "MERCHANT_UPDATE",
  "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED",
  -- auction house activity -> prices may have changed
  "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
  "AUCTION_ITEM_LIST_UPDATE", "REPLICATE_ITEM_LIST_UPDATE",
}) do
  pcall(ev.RegisterEvent, ev, e)
end

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON then
      InitDB()
      local api = Auctionator and Auctionator.API and Auctionator.API.v1
      if api and api.RegisterForDBUpdate then
        pcall(api.RegisterForDBUpdate, "CraftSell", function() ns.ScheduleRefresh(0.5) end)
      end
    end
    TryHookFrames()
  elseif event == "PLAYER_LOGIN" then
    InitDB()
    TryHookFrames()
    if CraftSellDB.standaloneShown then ns.ToggleStandalone(true) end
    Report("geladen – öffnet sich mit dem Berufsfenster, sonst Minimap-Symbol oder /cs.")
  elseif event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" then
    -- Blizzard may create the frame in this same event; check again next frame.
    C_Timer.After(0, function()
      TryHookFrames()
      OnProfessionShow()
    end)
  elseif event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
    InitDB()
    pcall(P.ScanMerchant)
  elseif event == "TRAINER_SHOW" then
    InitDB()
    -- the trainer frame (load on demand) may be created in this same event
    C_Timer.After(0, function()
      local ok, prof = pcall(ns.Learn.ReadTrainer, true)
      if ok and prof then OnTrainerShow(prof) end
    end)
  elseif event == "TRAINER_UPDATE" then
    if ns.Learn.trainerProf then
      pcall(ns.Learn.ReadTrainer, false)
      ns.ScheduleRefresh(0.3)
    end
  elseif event == "TRAINER_CLOSED" then
    if ns.Learn.trainerProf then OnTrainerHide() end
  elseif event:find("^AUCTION") or event:find("SEARCH_RESULTS") or event:find("^REPLICATE") then
    -- give Auctionator/Auctioneer a moment to store the new prices first
    ns.ScheduleRefresh(2)
  else
    -- list/bag/item-info updates come in bursts (e.g. on every recipe
    -- click): bundle them into one recalculation instead of reacting at once
    ns.ScheduleRefresh(0.5)
  end
end)

SLASH_CRAFTSELL1 = "/craftsell"
SLASH_CRAFTSELL2 = "/cs"
SlashCmdList.CRAFTSELL = function(msg)
  InitDB()
  local raw = msg or ""
  msg = raw:lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg:find("^behalten") then
    -- keep original case: the argument is an item link
    ns.Seller.ToggleKeep(raw:match("^%s*%S+%s*(.-)%s*$"))
    return
  end
  local alphaArg = msg:match("^transparenz%s*(%d*)$") or msg:match("^alpha%s*(%d*)$")
  if alphaArg then
    local v = tonumber(alphaArg)
    if v then
      -- value = how opaque the background is (0 = fully see-through, 100 = solid)
      CraftSellDB.bgAlpha = math.max(0, math.min(100, v)) / 100
      ns.ApplyAlphaAll()
    end
    Report("Hintergrund-Deckkraft: " .. math.floor((CraftSellDB.bgAlpha or 0.75) * 100 + 0.5)
      .. "%  (/cs transparenz 0-100, oder Strg + Mausrad auf der Titelleiste)")
    return
  end
  if msg == "fenster reset" then
    CraftSellDB.bgAlpha = nil
    if CraftSellDB.standalone then
      CraftSellDB.standalone.pos, CraftSellDB.standalone.width = nil, nil
    end
    for _, panel in pairs(panels) do
      panel:SetWidth(340)
      panel.anchoredExtra = nil
      panel.centered = nil
      panel:Reanchor()
      panel:ApplyAlpha()
    end
    Report("Fenstergröße, Position und Transparenz zurückgesetzt.")
    return
  end
  if msg == "" or msg == "fenster" then
    ns.ToggleStandalone()
    return
  end
  if msg == "lernen" or msg == "lehrer" then
    -- show the "learnable at the trainer" list (toggles back if already shown)
    local panel = GetPanel()
    if not panel then return end
    if panel:IsShown() and CraftSellDB.learnMode then
      ns.SetLearnMode(false)
    else
      ns.SetLearnMode(true)
      if not panel:IsShown() then ns.ToggleStandalone(true) end
    end
    ns.ScheduleRefresh(0)
    return
  end
  if msg == "auto" then
    CraftSellDB.autoOpen = (CraftSellDB.autoOpen == false)
    Report("Automatisch mit dem Berufsfenster öffnen: " .. (CraftSellDB.autoOpen and "an" or "aus") .. ".")
    return
  end
  if msg == "minimap" then
    CraftSellDB.minimapHide = not CraftSellDB.minimapHide
    if ns.UpdateMinimapButton then ns.UpdateMinimapButton() end
    Report("Minimap-Symbol " .. (CraftSellDB.minimapHide and "ausgeblendet" or "eingeblendet") .. ".")
    return
  end
  if msg == "verkaufen" then
    if MerchantFrame and MerchantFrame:IsShown() then
      ns.Seller.SellAll()
    else
      Report("Bitte zuerst einen Händler öffnen.")
    end
    return
  end
  local word, rest = msg:match("^(%S+)%s*(.-)$")
  -- ("Käufe": string.lower does not touch the UTF-8 umlaut)
  if word == "käufe" or word == "Käufe" or word == "kaeufe" or word == "kauf" or word == "einkauf" or word == "post" then
    if rest == "reset" then
      ns.Mail.Reset()
      Report("erfasste Käufe aus dem Postfach gelöscht.")
    elseif rest == "an" or rest == "aus" or rest == "preis" then
      if rest == "preis" then
        CraftSellDB.usePaid = not CraftSellDB.usePaid
      else
        CraftSellDB.usePaid = (rest == "an")
      end
      Report("Rezepte bewerten mit: " .. (CraftSellDB.usePaid and "deinen Kaufpreisen (Postfach)" or "aktuellen Marktpreisen") .. ".")
      ns.ScheduleRefresh(0)
    else
      ns.Mail.PrintSummary()
    end
    return
  end
  if msg == "reset" then
    CraftSellDB.vendorBuy = {}
    Report("gespeicherte Händler-Einkaufspreise gelöscht.")
  elseif msg == "bilanz" or msg == "gold" then
    ns.Ledger.PrintSummary()
  elseif msg == "bilanz reset" then
    local d = ns.Ledger.Day()
    for k in pairs(d) do d[k] = 0 end
    ns.OnLedgerChanged()
    Report("Tages-Bilanz von heute zurückgesetzt.")
  elseif msg == "dock" then
    if CraftSellDB.standalone then CraftSellDB.standalone.pos = nil end
    for _, panel in pairs(panels) do
      panel.anchoredExtra = nil
      panel.centered = nil
      panel:Reanchor()
    end
    Report("Fenster dockt wieder am Berufsfenster an (ohne Beruf: Bildschirmmitte).")
  elseif msg == "debug" then
    local recipes = "-"
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
      recipes = tostring(#(C_TradeSkillUI.GetAllRecipeIDs() or {}))
    end
    Report("ProfessionsFrame: " .. tostring(_G.ProfessionsFrame ~= nil)
      .. ", Beruf offen: " .. tostring(OpenProfessionAdapter() ~= nil)
      .. ", Rezept-IDs: " .. recipes
      .. ", Auctionator: " .. tostring(Auctionator ~= nil)
      .. ", Auctioneer: " .. tostring(AucAdvanced ~= nil))
    if mainPanel then
      Report("Fenster: sichtbar=" .. tostring(mainPanel:IsVisible()) .. ", Einträge=" .. #(mainPanel.list or {}))
    end
  else
    Report("Befehle: /cs (Fenster), /cs lernen (Lehrer-Rezepte), /cs auto, /cs bilanz, /cs käufe [an|aus|reset], /cs verkaufen, /cs behalten [Item], "
      .. "/cs transparenz 0-100, /cs dock, /cs fenster reset, /cs minimap, /cs reset")
  end
end
