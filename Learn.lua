-- CraftSell: recipes you could learn at the trainer – would they earn more
-- than what you already know?
--
-- The trainer API only gives name, cost, required skill and the crafted
-- item, not the reagents. They are taken from (first match wins):
--   1. the recipe spell itself (C_TradeSkillUI.GetRecipeSchematic),
--   2. unlearned recipes listed in the profession window (cached in Core.lua),
--   3. Crafter's Journal's recipe database, if that addon is loaded.
-- Trainer services seen in game are stored per profession in
-- CraftSellDB.trainer[profession][key] = { name, spell, item, cost, skill, icon, time }.
local ADDON, ns = ...
local P = ns.Prices

ns.Learn = {}
local L = ns.Learn

local function SpellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  return GetSpellInfo and (GetSpellInfo(id))
end

local function ItemIcon(itemID)
  if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
  return GetItemIcon and GetItemIcon(itemID)
end

-- Current skill and skill line ID of a profession (by localized name).
local function PlayerSkill(prof)
  if not prof then return nil end
  if GetProfessions and GetProfessionInfo then
    -- GetProfessions returns nil gaps (no second profession): walk by position
    local slots = { GetProfessions() }
    for i = 1, select("#", GetProfessions()) do
      local index = slots[i]
      if index then
        local name, _, rank, _, _, _, line = GetProfessionInfo(index)
        if name == prof then return rank, line end
      end
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, rank = GetSkillLineInfo(i)
      if not isHeader and name == prof then return rank end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Trainer window
local function LinkIDs(link)
  if type(link) ~= "string" then return nil end
  local spell = tonumber(link:match("spell:(%d+)") or link:match("enchant:(%d+)"))
  local item = tonumber(link:match("item:(%d+)"))
  return spell, item
end

local function TrainerProfession()
  for i = 1, GetNumTrainerServices() or 0 do
    local line = GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)
    if line and line ~= "" then return line end
  end
  if GetTrainerServiceSkillReq then
    for i = 1, GetNumTrainerServices() or 0 do
      local name = GetTrainerServiceSkillReq(i)
      if name and name ~= "" then return name end
    end
  end
end

local function ReadServices()
  local prof = TrainerProfession()
  if not prof then return nil end
  CraftSellDB.trainer = CraftSellDB.trainer or {}
  local db = CraftSellDB.trainer[prof] or {}
  CraftSellDB.trainer[prof] = db
  for i = 1, GetNumTrainerServices() or 0 do
    local name, _, category = GetTrainerServiceInfo(i)
    if name and category ~= "header" then
      local spell, item = LinkIDs(GetTrainerServiceItemLink and GetTrainerServiceItemLink(i))
      local key = (spell and "s" .. spell) or (item and "i" .. item) or ("n" .. name)
      if category == "used" then
        db[key] = nil                       -- already learned
      else
        local e = db[key] or {}
        e.name, e.spell, e.item = name, spell, item or e.item
        e.cost = GetTrainerServiceCost(i)
        if GetTrainerServiceSkillReq then e.skill = select(2, GetTrainerServiceSkillReq(i)) end
        e.icon = (GetTrainerServiceIcon and GetTrainerServiceIcon(i)) or e.icon
        e.time = time()
        db[key] = e
      end
    end
  end
  return prof
end

-- Reads the open trainer. `showAll`: briefly switch on the "available" and
-- "unavailable" filters to see every recipe, then restore them (only on
-- TRAINER_SHOW: changing a filter fires TRAINER_UPDATE, which reads without
-- touching them, so this does not loop).
function L.ReadTrainer(showAll)
  if not (GetNumTrainerServices and GetTrainerServiceInfo and GetTrainerServiceCost) then return nil end
  if IsTradeskillTrainer and not IsTradeskillTrainer() then return nil end
  local hidden = {}
  if showAll and GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
    for _, f in ipairs({ "available", "unavailable" }) do
      if not GetTrainerServiceTypeFilter(f) then
        hidden[#hidden + 1] = f
        SetTrainerServiceTypeFilter(f, 1)
      end
    end
  end
  local ok, prof = pcall(ReadServices)
  for _, f in ipairs(hidden) do SetTrainerServiceTypeFilter(f, 0) end
  if not ok then error(prof, 0) end
  L.trainerProf = prof
  return prof
end

-- (trainerProf is cleared on TRAINER_CLOSED)
function L.TrainerOpen()
  return L.trainerProf ~= nil
end

-- Click on a row: select that recipe in the open trainer window.
function L.SelectAtTrainer(name)
  if not (L.TrainerOpen() and name) then return end
  for i = 1, GetNumTrainerServices() or 0 do
    if GetTrainerServiceInfo(i) == name then
      if ClassTrainer_SetSelection then
        pcall(ClassTrainer_SetSelection, i)
      elseif SelectTrainerService then
        SelectTrainerService(i)
      end
      if ClassTrainerFrame_Update then pcall(ClassTrainerFrame_Update) end
      return
    end
  end
end

-- ---------------------------------------------------------------------------
-- Crafter's Journal data (optional): ES.Data[key] = { skillLine, recipes =
-- { [spellID] = { name, fee, train, trainer, basic, faction, r = {{item, n}},
-- out = {item, n} } } }, real trainer prices in ES.db.trainerFees[spellID].
local CJ_SPELLS = { Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036,
  Leatherworking = 2108, Tailoring = 3908, Cooking = 2550, FirstAid = 3273 }

local function CJProfession(prof, skillLine)
  local cj = _G.CraftersJournal
  if type(cj) ~= "table" or type(cj.Data) ~= "table" then return nil end
  for key, data in pairs(cj.Data) do
    if type(data) == "table" and type(data.recipes) == "table" then
      if (skillLine and data.skillLine == skillLine) or key == prof
        or (CJ_SPELLS[key] and SpellName(CJ_SPELLS[key]) == prof) then
        return cj, data
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Collect all trainer recipes of `prof` that are not learned yet.
local function Candidates(prof, learned)
  local knownIDs, knownItems, knownNames = {}, {}, {}
  for _, rec in ipairs(learned) do
    if type(rec.id) == "number" then knownIDs[rec.id] = true end
    local item = P.ItemIDFromLink(rec.output)
    if item then knownItems[item] = true end
    if rec.name then knownNames[rec.name] = true end
  end

  local list, index = {}, {}
  local function Find(c)
    return (c.spell and index["s" .. c.spell]) or (c.item and index["i" .. c.item])
      or (c.name and index["n" .. c.name])
  end
  local function Add(c, isNew)
    if c.spell and knownIDs[c.spell] then return end
    if not c.spell and ((c.item and knownItems[c.item]) or (c.name and knownNames[c.name])) then return end
    local e = Find(c)
    if not e then
      if not isNew then return end
      e = {}
      list[#list + 1] = e
    end
    for k, v in pairs(c) do
      if e[k] == nil then e[k] = v end
    end
    if e.spell then index["s" .. e.spell] = e end
    if e.item then index["i" .. e.item] = e end
    if e.name then index["n" .. e.name] = e end
  end

  local sources = {}
  -- 1. seen at the trainer (real cost and skill)
  local seen = CraftSellDB.trainer and CraftSellDB.trainer[prof]
  for _, s in pairs(seen or {}) do
    sources.trainer = true
    Add({ name = s.name, spell = s.spell, item = s.item, cost = s.cost, skill = s.skill,
      icon = s.icon, source = "Lehrer" }, true)
  end

  -- 2. Crafter's Journal: every trainer recipe of the profession
  local _, skillLine = PlayerSkill(prof)
  local cj, data = CJProfession(prof, skillLine)
  if data then
    local fees = type(cj.db) == "table" and type(cj.db.trainerFees) == "table" and cj.db.trainerFees or {}
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    for id, r in pairs(data.recipes) do
      if type(r) == "table" and (r.fee or r.trainer) and not r.basic and r.out and r.out[1]
        and (not r.faction or r.faction == faction) then
        sources.cj = true
        local fee = type(fees[id]) == "table" and fees[id] or {}
        local reagents
        if r.r and #r.r > 0 then
          reagents = {}
          for j, rq in ipairs(r.r) do reagents[j] = { item = rq[1], count = rq[2] or 1 } end
        end
        Add({ spell = id, item = r.out[1], made = r.out[2] or 1,
          name = SpellName(id) or r.name, cost = fee.cost or r.fee, skill = fee.skill or r.train,
          reagents = reagents, source = "Crafter's Journal" }, true)
      end
    end
  end

  -- 3. reagents of unlearned recipes from the profession window
  local char = ns.Ledger.CharKey()
  local cache = CraftSellDB.cache and CraftSellDB.cache[char] and CraftSellDB.cache[char][prof]
  for _, u in ipairs(cache and cache.unlearned or {}) do
    Add({ spell = u.id, item = P.ItemIDFromLink(u.output), name = u.name, made = u.made,
      reagents = u.reagents, icon = u.icon }, false)
  end

  -- 4. still missing: ask the client for the recipe spell
  for _, e in ipairs(list) do
    if e.spell and (not e.reagents or not e.item) then
      local output, made, reagents = ns.ReadSchematic(e.spell)
      if output then
        e.item = e.item or output
        e.made = e.made or made
        e.reagents = e.reagents or reagents
      end
    end
  end
  sources.learned = #learned > 0
  return list, sources
end

-- Rate every learnable recipe like the learned ones (Core.lua ns.Scan) and
-- compare it with the best learned recipe `best` (may be nil).
-- Returns entries in the panel's format plus learn fields:
--   fee, skill, playerSkill, canLearn, gain, better, payback, noReagents, source
function L.Scan(prof, learned, best)
  local results = {}
  if not prof then return results, {} end
  local playerSkill = PlayerSkill(prof)
  local list, sources = Candidates(prof, learned)
  local coster = ns.NewCoster(learned)
  for _, c in ipairs(list) do
    if c.item then
      local e = {
        learn = true,
        id = c.spell or c.item,
        name = c.name or (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(c.item)) or "?",
        icon = c.icon or ItemIcon(c.item),
        output = c.item,
        made = c.made or 1,
        numAvailable = 0,
        reagents = {},
        fee = c.cost,
        skill = (c.skill and c.skill > 0) and c.skill or nil,
        playerSkill = playerSkill,
        source = c.source,
      }
      e.canLearn = not (e.skill and playerSkill and playerSkill < e.skill)
      -- fresh reagent tables: pricing writes into them
      for j, r in ipairs(c.reagents or {}) do
        e.reagents[j] = { item = r.item, count = r.count, icon = r.icon }
      end
      if #e.reagents == 0 then
        e.noReagents = true
        e.unknownCost = true
      else
        e.cost, e.unknownCost = coster.PriceReagents(e.reagents, {})
      end
      e.sellUnit = P.GetVendorSellPrice(e.output)
      if e.sellUnit and not e.noReagents then
        e.sellTotal = e.sellUnit * e.made
        e.profitCraft = e.sellTotal - e.cost
        e.profitItem = e.sellUnit - e.cost / e.made
        if best and best.profitItem then
          e.gain = e.profitItem - best.profitItem
          e.bestName = best.name
        end
        e.better = not e.unknownCost and e.profitItem > 0 and (e.gain == nil or e.gain > 0)
        if e.fee and e.fee > 0 and e.profitCraft > 0 then
          e.payback = math.ceil(e.fee / e.profitCraft)
        end
      end
      results[#results + 1] = e
    end
  end
  ns.SortByProfit(results)
  return results, sources
end
