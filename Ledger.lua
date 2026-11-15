-- CraftSell: daily gold tracker (per character)
--   Einkauf  = gold actually paid for reagents (vendor + auction house)
--   Verkauf  = gold actually received for selling crafted items to vendors
--   Bilanz   = Verkauf - Einkauf
--   Hergestellt / Materialwert = crafts and estimated value of the
--   materials used (intermediate products are not counted twice)
local ADDON, ns = ...
local P = ns.Prices

ns.Ledger = {}
local L = ns.Ledger

local function CharKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

L.CharKey = CharKey

local function NewDay()
  return { spentVendor = 0, spentAH = 0, earned = 0, crafted = 0, matValue = 0, soldItems = 0 }
end

function L.Day(dayKey)
  CraftSellDB.ledger = CraftSellDB.ledger or {}
  local key = CharKey()
  local char = CraftSellDB.ledger[key]
  if not char then
    char = {}
    CraftSellDB.ledger[key] = char
  end
  dayKey = dayKey or date("%Y-%m-%d")
  local d = char[dayKey]
  if not d then
    d = NewDay()
    char[dayKey] = d
  end
  return d
end

-- Days of the current character, newest first: { {key=..., data=...}, ... }
function L.RecentDays(n)
  local char = CraftSellDB.ledger and CraftSellDB.ledger[CharKey()] or {}
  local keys = {}
  for k in pairs(char) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return a > b end)
  local out = {}
  for i = 1, math.min(n or 7, #keys) do out[i] = { key = keys[i], data = char[keys[i]] } end
  return out
end

function L.Balance(d)
  return d.earned - d.spentVendor - d.spentAH
end

local session = { spent = 0, earned = 0 }

local function Changed()
  if ns.OnLedgerChanged then ns.OnLedgerChanged() end
end

local function IsReagent(itemID)
  return itemID and CraftSellDB.reagentIDs and CraftSellDB.reagentIDs[itemID]
end

local function IsCrafted(itemID)
  return itemID and CraftSellDB.craftedIDs and CraftSellDB.craftedIDs[itemID]
end

function L.AddSpent(kind, amount)
  if not amount or amount <= 0 then return end
  local d = L.Day()
  if kind == "ah" then d.spentAH = d.spentAH + amount else d.spentVendor = d.spentVendor + amount end
  session.spent = session.spent + amount
  Changed()
end

function L.AddEarned(amount, count)
  if not amount or amount <= 0 then return end
  local d = L.Day()
  d.earned = d.earned + amount
  d.soldItems = (d.soldItems or 0) + (count or 1)
  session.earned = session.earned + amount
  Changed()
end

-- ---------------------------------------------------------------------------
-- Vendor: buying reagents
local function MerchantUnitPrice(index)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local info = C_MerchantFrame.GetItemInfo(index)
    if info and not info.hasExtendedCost and info.price and info.price > 0 then
      return info.price / math.max(info.stackCount or 1, 1), info.stackCount or 1
    end
  elseif GetMerchantItemInfo then
    local _, _, price, stack, _, _, _, ext = GetMerchantItemInfo(index)
    if price and price > 0 and not ext then
      return price / math.max(stack or 1, 1), stack or 1
    end
  end
end

if BuyMerchantItem then
  hooksecurefunc("BuyMerchantItem", function(index, quantity)
    local itemID = P.ItemIDFromLink(GetMerchantItemLink(index))
    if not IsReagent(itemID) then return end
    local unit, stack = MerchantUnitPrice(index)
    if unit then
      L.AddSpent("vendor", math.floor(unit * (quantity or stack) + 0.5))
    end
  end)
end

-- Vendor: selling crafted items (right-click while a merchant is open)
local function ContainerItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount, info.hasNoValue end
  elseif GetContainerItemInfo then
    local _, count, _, _, _, _, _, _, noValue, itemID = GetContainerItemInfo(bag, slot)
    return itemID, count, noValue
  end
end

local function OnUseContainerItem(bag, slot)
  if not (MerchantFrame and MerchantFrame:IsShown()) then return end
  local itemID, count, noValue = ContainerItem(bag, slot)
  if noValue or not IsCrafted(itemID) then return end
  local sell = P.GetVendorSellPrice(itemID)
  if sell and sell > 0 then
    L.AddEarned(sell * (count or 1), count or 1)
  end
end

if C_Container and C_Container.UseContainerItem then
  hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
elseif UseContainerItem then
  hooksecurefunc("UseContainerItem", OnUseContainerItem)
end

-- ---------------------------------------------------------------------------
-- Auction house (modern): commodity purchases (leather, hides, cloth, ...)
local pending
if C_AuctionHouse then
  if C_AuctionHouse.StartCommoditiesPurchase then
    hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function(itemID, quantity)
      pending = { itemID = itemID, qty = quantity }
    end)
  end
  if C_AuctionHouse.ConfirmCommoditiesPurchase then
    hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
      if pending and pending.itemID == itemID then
        pending.qty = quantity or pending.qty
        pending.confirmed = true
      else
        pending = { itemID = itemID, qty = quantity, confirmed = true }
      end
    end)
  end
  -- Single (non-stackable) auctions: only counted if the item can be resolved.
  if C_AuctionHouse.PlaceBid then
    hooksecurefunc(C_AuctionHouse, "PlaceBid", function(auctionID, amount)
      local itemID
      if C_AuctionHouse.GetAuctionInfoByID then
        local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
        if ok and info and info.itemKey then itemID = info.itemKey.itemID end
      end
      if IsReagent(itemID) then L.AddSpent("ah", amount) end
    end)
  end
end

-- ---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({
  "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
  "UNIT_SPELLCAST_SUCCEEDED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
}) do
  pcall(ev.RegisterEvent, ev, e)
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if not CraftSellDB then return end
  if event == "COMMODITY_PRICE_UPDATED" then
    if pending then pending.total = a2 end
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    if pending and pending.confirmed and IsReagent(pending.itemID) then
      local total = pending.total
      if not total then
        local unit = P.GetReagentPrice(pending.itemID)
        total = unit and unit * (pending.qty or 1)
      end
      L.AddSpent("ah", total)
    end
    pending = nil
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    pending = nil
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    -- a1 = unit, a3 = spellID (== recipeID in the modern profession API)
    if a1 == "player" and CraftSellDB.recipes then
      local meta = CraftSellDB.recipes[a3]
      if meta then
        local d = L.Day()
        d.crafted = d.crafted + (meta.made or 1)
        if not meta.inter then d.matValue = d.matValue + (meta.cost or 0) end
        Changed()
      end
    end
  elseif event == "MERCHANT_SHOW" then
    session.spent, session.earned = 0, 0
  elseif event == "MERCHANT_CLOSED" then
    if session.spent > 0 or session.earned > 0 then
      local d = L.Day()
      print("|cffffd200CraftSell|r: Händler – verkauft " .. P.FormatMoney(session.earned)
        .. ", Material gekauft " .. P.FormatMoney(session.spent)
        .. "  ·  Bilanz heute: " .. P.FormatMoney(L.Balance(d)))
    end
    session.spent, session.earned = 0, 0
  end
end)

-- ---------------------------------------------------------------------------
-- Text helpers for the panel and /cs bilanz
function L.TodayLine()
  local d = L.Day()
  local bal = L.Balance(d)
  return "Heute:  |cffff7070-|r" .. P.FormatMoney(d.spentVendor + d.spentAH)
    .. "   |cff70ff70+|r" .. P.FormatMoney(d.earned)
    .. "   = " .. (bal >= 0 and "|cff70ff70" or "|cffff7070") .. "Bilanz|r " .. P.FormatMoney(bal)
end

function L.FillTooltip(tt)
  tt:AddLine("CraftSell – Gold-Tracker (" .. CharKey() .. ")")
  tt:AddLine("Einkauf = Materialkäufe bei Händler + AH, Verkauf = hergestellte Gegenstände an Händler.", 0.7, 0.7, 0.7, true)
  local sumBal = 0
  for _, day in ipairs(L.RecentDays(7)) do
    local d = day.data
    local bal = L.Balance(d)
    sumBal = sumBal + bal
    tt:AddLine(" ")
    tt:AddDoubleLine(day.key, (bal >= 0 and "|cff70ff70" or "|cffff7070") .. "Bilanz|r " .. P.FormatMoney(bal), 1, 0.82, 0, 1, 1, 1)
    tt:AddDoubleLine("  Einkauf Händler / AH", P.FormatMoney(d.spentVendor) .. " / " .. P.FormatMoney(d.spentAH), 0.9, 0.9, 0.9, 1, 1, 1)
    tt:AddDoubleLine("  Verkauf an Händler (" .. (d.soldItems or 0) .. " Stk.)", P.FormatMoney(d.earned), 0.9, 0.9, 0.9, 1, 1, 1)
    tt:AddDoubleLine("  Hergestellt / Materialwert", (d.crafted or 0) .. " Stk. / " .. P.FormatMoney(d.matValue or 0), 0.9, 0.9, 0.9, 1, 1, 1)
  end
  tt:AddLine(" ")
  tt:AddDoubleLine("Summe (bis 7 Tage)", P.FormatMoney(sumBal), 1, 0.82, 0, 1, 1, 1)
end

function L.PrintSummary()
  print("|cffffd200CraftSell|r – Gold-Tracker:")
  for _, day in ipairs(L.RecentDays(7)) do
    local d = day.data
    print(string.format("  %s:  Einkauf %s (Händler %s, AH %s)  ·  Verkauf %s  ·  Bilanz %s  ·  %d hergestellt",
      day.key, P.FormatMoney(d.spentVendor + d.spentAH), P.FormatMoney(d.spentVendor),
      P.FormatMoney(d.spentAH), P.FormatMoney(d.earned), P.FormatMoney(L.Balance(d)), d.crafted or 0))
  end
end
