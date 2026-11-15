-- CraftSell: "sell crafted items" button on the merchant window.
-- Sells only items in your bags (never equipped or bank items) that are
-- products of your learned recipes, are NOT used as a reagent by any of
-- your recipes, have a vendor value and are not on the keep list.
local ADDON, ns = ...
local P = ns.Prices

ns.Seller = {}
local S = ns.Seller

local NUM_BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local BACKPACK = BACKPACK_CONTAINER or 0

local function NumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function SlotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount or 1, info.isLocked, info.hasNoValue, info.hyperlink end
  elseif GetContainerItemInfo then
    local _, count, locked, _, _, _, link, _, noValue, itemID = GetContainerItemInfo(bag, slot)
    return itemID, count or 1, locked, noValue, link
  end
end

local function UseItem(bag, slot)
  if C_Container and C_Container.UseContainerItem then
    C_Container.UseContainerItem(bag, slot)
  else
    UseContainerItem(bag, slot)
  end
end

local function Sellable(itemID, locked, noValue)
  if not itemID or locked or noValue then return false end
  local db = CraftSellDB
  if not (db.craftedIDs and db.craftedIDs[itemID]) then return false end
  if db.reagentIDs and db.reagentIDs[itemID] then return false end   -- material / intermediate
  if db.keep and db.keep[itemID] then return false end
  local sell = P.GetVendorSellPrice(itemID)
  return sell and sell > 0, sell
end

-- Returns list of { bag, slot, itemID, count, value, link }, total value, total count
function S.Collect()
  local list, total, count = {}, 0, 0
  if not CraftSellDB then return list, 0, 0 end
  for bag = BACKPACK, NUM_BAGS do
    for slot = 1, NumSlots(bag) do
      local itemID, stack, locked, noValue, link = SlotInfo(bag, slot)
      local ok, sell = Sellable(itemID, locked, noValue)
      if ok then
        list[#list + 1] = { bag = bag, slot = slot, itemID = itemID, count = stack, value = sell * stack, link = link }
        total = total + sell * stack
        count = count + stack
      end
    end
  end
  return list, total, count
end

-- Sells at most 12 stacks per call: the merchant's buyback list holds the
-- last 12 sales, so everything sold with one click can be bought back.
local MAX_PER_CLICK = 12

function S.SellAll()
  if not (MerchantFrame and MerchantFrame:IsShown()) then return end
  local list = S.Collect()
  local sold, value = 0, 0
  for _, e in ipairs(list) do
    if sold >= MAX_PER_CLICK then break end
    -- re-check the slot right before selling (bags may have changed)
    local itemID, _, locked = SlotInfo(e.bag, e.slot)
    if itemID == e.itemID and not locked then
      UseItem(e.bag, e.slot)
      sold = sold + 1
      value = value + e.value
    end
  end
  if sold > 0 then
    local rest = #list - sold
    print("|cffffd200CraftSell|r: " .. sold .. " Stapel für ca. " .. P.FormatMoney(value)
      .. " verkauft (zurückkaufbar unter \"Rückkauf\")."
      .. (rest > 0 and (" Noch " .. rest .. " Stapel übrig – erneut klicken.") or ""))
  end
end

-- ---------------------------------------------------------------------------
local button
local function UpdateButton()
  if not button then return end
  local _, total, count = S.Collect()
  if count > 0 then
    button:SetText("Hergestelltes verkaufen (" .. count .. ")")
    button:Enable()
  else
    button:SetText("Nichts Hergestelltes")
    button:Disable()
  end
  button.total, button.count = total, count
end
S.UpdateButton = UpdateButton

local function CreateButton()
  if button or not MerchantFrame then return end
  button = CreateFrame("Button", "CraftSellSellButton", MerchantFrame, "UIPanelButtonTemplate")
  button:SetSize(210, 22)
  -- Top right, in the grey area below the merchant's name (right of the
  -- portrait, above the item grid).
  button:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -10, -32)
  button:SetFrameLevel(MerchantFrame:GetFrameLevel() + 5)
  button:SetMotionScriptsWhileDisabled(true)
  button:SetScript("OnClick", function(self)
    S.SellAll()
    -- bag contents update a moment later; refresh the label then
    C_Timer.After(0.5, UpdateButton)
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("CraftSell – hergestellte Gegenstände verkaufen")
    GameTooltip:AddLine("Nur Gegenstände aus deinen Taschen (nicht angelegt, nicht Bank), die deine Rezepte herstellen. Materialien und Zwischenprodukte bleiben liegen.", 1, 1, 1, true)
    GameTooltip:AddLine("Pro Klick max. 12 Stapel – alles bleibt über \"Rückkauf\" zurückkaufbar.", 0.6, 1, 0.6, true)
    local list, total = S.Collect()
    if #list > 0 then
      GameTooltip:AddLine(" ")
      local shown = 0
      for _, e in ipairs(list) do
        shown = shown + 1
        if shown > 15 then
          GameTooltip:AddLine("… und " .. (#list - 15) .. " weitere Stapel", 0.7, 0.7, 0.7)
          break
        end
        GameTooltip:AddDoubleLine((e.link or ("item:" .. e.itemID)) .. " x" .. e.count, P.FormatMoney(e.value), 1, 1, 1, 1, 1, 1)
      end
      GameTooltip:AddDoubleLine("Gesamt", P.FormatMoney(total), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Etwas behalten: /cs behalten [Gegenstand per Shift-Klick]", 0.5, 0.8, 1, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)
  UpdateButton()
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_SHOW", "BAG_UPDATE_DELAYED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if not CraftSellDB then return end
  if event == "MERCHANT_SHOW" then
    CreateButton()
    UpdateButton()
  elseif button and MerchantFrame and MerchantFrame:IsShown() then
    UpdateButton()
  end
end)

-- /cs behalten <itemlink>  – toggle keep list
function S.ToggleKeep(arg)
  local itemID = tonumber(arg and arg:match("item:(%d+)") or arg)
  CraftSellDB.keep = CraftSellDB.keep or {}
  if not itemID then
    local any = false
    print("|cffffd200CraftSell|r: Behalten-Liste:")
    for id in pairs(CraftSellDB.keep) do
      any = true
      print("   " .. (select(2, (C_Item and C_Item.GetItemInfo or GetItemInfo)(id)) or ("item:" .. id)))
    end
    if not any then print("   (leer) – /cs behalten [Gegenstand per Shift-Klick]") end
    return
  end
  if CraftSellDB.keep[itemID] then
    CraftSellDB.keep[itemID] = nil
    print("|cffffd200CraftSell|r: wird wieder verkauft: " .. (arg or itemID))
  else
    CraftSellDB.keep[itemID] = true
    print("|cffffd200CraftSell|r: wird nie verkauft: " .. (arg or itemID))
  end
  UpdateButton()
end
