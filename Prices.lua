-- CraftSell: price sources
-- Reagent cost  = cheapest known of: vendor buy price (seen at a merchant),
--                 Auctioneer market value, Auctionator AH price.
-- Output value  = vendor SELL price of the crafted item (never AH).
local ADDON, ns = ...

ns.Prices = {}
local P = ns.Prices
local CALLER = "CraftSell"

local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

local function ItemIDFromLink(link)
  if type(link) == "number" then return link end
  if not link then return nil end
  local id = link:match("item:(%d+)")
  return id and tonumber(id)
end
P.ItemIDFromLink = ItemIDFromLink

local function AuctionatorAPI()
  return Auctionator and Auctionator.API and Auctionator.API.v1
end

-- Returns vendor sell price per unit, or nil when item data is not cached yet.
-- `item` may be an itemID or an item link.
function P.GetVendorSellPrice(item)
  local itemID = ItemIDFromLink(item)
  if not itemID then return nil end
  local sell = select(11, GetItemInfoFn(item))
  if sell == nil then
    if RequestLoad then RequestLoad(itemID) end
    ns.pendingItemData = true
    return nil
  end
  return sell
end

function P.GetItemLink(item)
  if type(item) == "string" then return item end
  local link = select(2, GetItemInfoFn(item))
  return link
end

-- Vendor BUY price per unit (only for items sold by NPCs).
local function VendorBuyPrice(itemID)
  local best = CraftSellDB and CraftSellDB.vendorBuy and CraftSellDB.vendorBuy[itemID]
  local api = AuctionatorAPI()
  if api and api.GetVendorPriceByItemID then
    local ok, v = pcall(api.GetVendorPriceByItemID, CALLER, itemID)
    if ok and v and v > 0 and (not best or v < best) then best = v end
  end
  return best
end
P.VendorBuyPrice = VendorBuyPrice

local function AuctioneerPrice(itemID)
  if AucAdvanced and AucAdvanced.API and AucAdvanced.API.GetMarketValue then
    local link = P.GetItemLink(itemID)
    if link then
      local ok, v = pcall(AucAdvanced.API.GetMarketValue, link)
      if ok and v and v > 0 then return v end
    end
  end
  return nil
end

local function AuctionatorPrice(itemID)
  local api = AuctionatorAPI()
  if api and api.GetAuctionPriceByItemID then
    local ok, v = pcall(api.GetAuctionPriceByItemID, CALLER, itemID)
    if ok and v and v > 0 then return v end
  end
  return nil
end

-- Returns unitPrice, sourceLabel  (nil when unknown). `item` = itemID or link.
function P.GetReagentPrice(item)
  local itemID = ItemIDFromLink(item)
  if not itemID then return nil end

  local best, src
  local function consider(v, label)
    if v and (not best or v < best) then best, src = v, label end
  end
  consider(VendorBuyPrice(itemID), "Händler")
  consider(AuctioneerPrice(itemID), "Auctioneer")
  consider(AuctionatorPrice(itemID), "Auctionator")
  return best, src
end

function P.HasPriceAddon()
  return AuctionatorAPI() ~= nil or (AucAdvanced and AucAdvanced.API) ~= nil
end

-- Remember merchant buy prices so vendor-bought reagents (thread, vials,
-- flux, ...) are priced at what they really cost.
function P.ScanMerchant()
  CraftSellDB.vendorBuy = CraftSellDB.vendorBuy or {}
  local num = (GetMerchantNumItems and GetMerchantNumItems())
    or (C_MerchantFrame and C_MerchantFrame.GetNumItems and C_MerchantFrame.GetNumItems()) or 0
  for i = 1, num do
    local itemID = ItemIDFromLink(GetMerchantItemLink(i))
    if itemID then
      local _, price, quantity, extendedCost
      if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if info then price, quantity, extendedCost = info.price, info.stackCount, info.hasExtendedCost end
      elseif GetMerchantItemInfo then
        _, _, price, quantity, _, _, _, extendedCost = GetMerchantItemInfo(i)
      end
      if price and price > 0 and not extendedCost then
        CraftSellDB.vendorBuy[itemID] = math.floor(price / math.max(quantity or 1, 1) + 0.5)
      end
    end
  end
end

-- Own formatter: does not depend on GetCoinTextureString/GetMoneyString,
-- which behave differently (or are missing) on some clients.
local GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t"

function P.FormatMoney(amount)
  if amount == nil then return "|cff888888?|r" end
  local neg = amount < 0
  local v = math.floor(math.abs(amount) + 0.5)
  local g = math.floor(v / 10000)
  local s = math.floor((v % 10000) / 100)
  local c = v % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. GOLD end
  if s > 0 or (g > 0 and c > 0) then parts[#parts + 1] = s .. SILVER end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER end
  local str = table.concat(parts, " ")
  if neg then return "|cffff4040-|r" .. str end
  return str
end
