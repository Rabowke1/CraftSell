-- CraftSell: what did the materials really cost?
-- Reads the auction house invoices ("Auktion gewonnen") in the mailbox and
-- remembers what was paid per item. With the "Kaufpreis" switch in the panel
-- recipes are rated with these real purchase prices instead of the current
-- market price.
--
--   CraftSellDB.bought[realm][itemID] = {
--     n = total amount ever bought, c = total copper ever paid,
--     lots = { { t = time, n = amount, c = copper }, ... }   -- oldest first
--   }
--   CraftSellDB.mailSeen[char] = { { k = key, t = sent time, live = in inbox }, ... }
--
-- Mails have no ID. A mail is recognised by item name + price + the time it
-- was sent (derived from its remaining lifetime), so an invoice that stays in
-- the inbox is counted only once – also across sessions.
local ADDON, ns = ...
local P = ns.Prices

ns.Mail = {}
local M = ns.Mail

M.SRC = "gekauft"              -- price source label of a purchase price

local MAIL_DAYS = 30           -- lifetime of an auction mail
local MAX_LOTS = 40            -- purchases remembered per item
-- The remaining lifetime is only refreshed when the inbox is re-read, so the
-- computed send time drifts while the mailbox stays open.
local LIVE_TOLERANCE = 900     -- mail was in the inbox at the last scan
local GONE_TOLERANCE = 30      -- mail was gone (taken) at the last scan

local GetCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function Store()
  local realm = GetRealmName() or "?"
  CraftSellDB.bought = CraftSellDB.bought or {}
  local s = CraftSellDB.bought[realm]
  if not s then
    s = {}
    CraftSellDB.bought[realm] = s
  end
  return s
end

local function AddLot(itemID, qty, cost, t)
  local s = Store()
  local e = s[itemID]
  if not e then
    e = { n = 0, c = 0, lots = {} }
    s[itemID] = e
  end
  e.n = e.n + qty
  e.c = e.c + cost
  e.lots[#e.lots + 1] = { t = t, n = qty, c = cost }
  while #e.lots > MAX_LOTS do table.remove(e.lots, 1) end
end

-- Average price paid per unit for what you currently own (bags + bank):
-- the newest purchases are added up until they cover your stock, so older,
-- already used up purchases do not count. Without stock: the last purchase.
-- Returns unitPrice, amountTheAverageIsBasedOn (nil when never bought).
function M.PaidUnit(itemID)
  local realm = CraftSellDB.bought and CraftSellDB.bought[GetRealmName() or "?"]
  local e = realm and itemID and realm[itemID]
  if not e or #e.lots == 0 then return nil end
  local need = (GetCount and GetCount(itemID, true)) or 0
  local qty, cost = 0, 0
  for i = #e.lots, 1, -1 do
    local lot = e.lots[i]
    local take = lot.n
    if need > 0 and qty + take > need then take = need - qty end
    qty = qty + take
    cost = cost + lot.c * take / lot.n
    if qty >= need then break end
  end
  if qty <= 0 then return nil end
  return cost / qty, qty
end

-- ---------------------------------------------------------------------------
-- Item and amount of an invoice mail. The attachment may already be taken;
-- then the item is looked up by name among the known materials.
local function ItemIDByName(name)
  if not name then return nil end
  for _, set in ipairs({ CraftSellDB.reagentIDs or {}, CraftSellDB.craftedIDs or {} }) do
    for id in pairs(set) do
      if (GetItemInfoFn(id)) == name then return id end
    end
  end
end

local function ResolveItem(index, itemName, subject, invoiceCount)
  local itemID, attached = nil, 0
  for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
    local name, id, _, count = GetInboxItem(index, a)
    if name then
      if type(id) ~= "number" then
        id = GetInboxItemLink and P.ItemIDFromLink(GetInboxItemLink(index, a))
      end
      if id then
        itemID = itemID or id
        if id == itemID then attached = attached + (count or 1) end
      end
    end
  end
  itemID = itemID or ItemIDByName(itemName)
  if not itemID then return nil end
  local qty = (type(invoiceCount) == "number" and invoiceCount > 0) and invoiceCount or nil
  if not qty and attached > 0 then qty = attached end
  if not qty and subject then qty = tonumber(subject:match("%((%d+)%)%s*$")) end
  return itemID, qty or 1
end

local function Report(fresh)
  local byItem, order, total = {}, {}, 0
  for _, f in ipairs(fresh) do
    local e = byItem[f.itemID]
    if not e then
      e = { itemID = f.itemID, n = 0, c = 0 }
      byItem[f.itemID] = e
      order[#order + 1] = e
    end
    e.n, e.c = e.n + f.qty, e.c + f.cost
    total = total + f.cost
  end
  print("|cffffd200CraftSell|r: Postfach – " .. #fresh .. (#fresh == 1 and " Kauf" or " Käufe")
    .. " erfasst, zusammen " .. P.FormatMoney(total))
  for i, e in ipairs(order) do
    if i > 6 then
      print("   … und " .. (#order - 6) .. " weitere Gegenstände (/cs käufe)")
      break
    end
    print("   " .. e.n .. "x " .. (P.GetItemLink(e.itemID) or ("item:" .. e.itemID))
      .. "  für " .. P.FormatMoney(e.c) .. "  (" .. P.FormatMoney(e.c / e.n) .. " pro Stück)")
  end
end

local function Scan()
  if not (CraftSellDB and GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo and GetInboxItem) then
    return
  end
  local now = time()
  local char = ns.Ledger.CharKey()
  CraftSellDB.mailSeen = CraftSellDB.mailSeen or {}
  local seen = CraftSellDB.mailSeen[char] or {}
  local byKey = {}
  for _, s in ipairs(seen) do
    s.used = nil
    byKey[s.k] = byKey[s.k] or {}
    table.insert(byKey[s.k], s)
  end

  local fresh = {}
  for i = 1, GetInboxNumItems() or 0 do
    -- "buyer" = invoice of an auction you won; bid = what you paid in total
    local invoiceType, itemName, _, bid, _, _, _, _, _, _, invoiceCount = GetInboxInvoiceInfo(i)
    if invoiceType == "buyer" and bid and bid > 0 then
      local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
      local t = math.floor(now + ((daysLeft or MAIL_DAYS) - MAIL_DAYS) * 86400)
      local k = (itemName or subject or "?") .. "#" .. bid
      local match, bestDt
      for _, s in ipairs(byKey[k] or {}) do
        if not s.used then
          local dt = math.abs(s.t - t)
          if dt <= (s.live and LIVE_TOLERANCE or GONE_TOLERANCE) and (not bestDt or dt < bestDt) then
            match, bestDt = s, dt
          end
        end
      end
      if match then
        match.used = true
        if t < match.t then match.t = t end      -- drift only makes it later
      else
        local itemID, qty = ResolveItem(i, itemName, subject, invoiceCount)
        if itemID then
          seen[#seen + 1] = { k = k, t = t, used = true }
          fresh[#fresh + 1] = { itemID = itemID, qty = qty, cost = bid, t = t }
        end
        -- unknown item: not remembered, so it is tried again on the next scan
      end
    end
  end

  local keep = {}
  for _, s in ipairs(seen) do
    if s.t > now - (MAIL_DAYS + 2) * 86400 then
      s.live = s.used or nil
      s.used = nil
      keep[#keep + 1] = s
    end
  end
  CraftSellDB.mailSeen[char] = keep

  if #fresh > 0 then
    table.sort(fresh, function(a, b) return a.t < b.t end)
    for _, f in ipairs(fresh) do AddLot(f.itemID, f.qty, f.cost, f.t) end
    Report(fresh)
    if ns.ScheduleRefresh then ns.ScheduleRefresh(0.2) end
  end
end

-- ---------------------------------------------------------------------------
local mailOpen = false
local ev = CreateFrame("Frame")
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
  if event == "MAIL_SHOW" then
    mailOpen = true
  elseif event == "MAIL_CLOSED" then
    mailOpen = false
  elseif mailOpen or (MailFrame and MailFrame:IsShown()) then
    -- scan at once: the invoice must be read before the item is taken out
    local ok, err = pcall(Scan)
    if not ok and not M.reportedError then
      M.reportedError = true
      print("|cffffd200CraftSell|r: |cffff4040Fehler beim Lesen des Postfachs:|r " .. tostring(err))
    end
  end
end)

-- ---------------------------------------------------------------------------
-- /cs käufe
function M.PrintSummary()
  local list = {}
  for itemID, e in pairs(Store()) do
    if e.n > 0 then list[#list + 1] = { itemID = itemID, e = e } end
  end
  if #list == 0 then
    print("|cffffd200CraftSell|r: Noch keine Käufe erfasst – öffne das Postfach, solange die "
      .. "\"Auktion gewonnen\"-Briefe noch drin liegen.")
    return
  end
  table.sort(list, function(a, b) return a.e.c > b.e.c end)
  print("|cffffd200CraftSell|r – Käufe laut Postfach (" .. (GetRealmName() or "?") .. "):")
  for i, x in ipairs(list) do
    if i > 20 then
      print("   … und " .. (#list - 20) .. " weitere")
      break
    end
    local e = x.e
    local unit, basis = M.PaidUnit(x.itemID)
    print(string.format("   %s:  %dx für %s  ·  Ø %s  ·  aktueller Bestand Ø %s (%d Stk.)",
      P.GetItemLink(x.itemID) or ("item:" .. x.itemID), e.n, P.FormatMoney(e.c),
      P.FormatMoney(e.c / e.n), P.FormatMoney(unit), basis or 0))
  end
end

-- Forgets the purchases; mails still in the inbox stay marked as counted.
function M.Reset()
  CraftSellDB.bought = CraftSellDB.bought or {}
  CraftSellDB.bought[GetRealmName() or "?"] = {}
  if ns.ScheduleRefresh then ns.ScheduleRefresh(0) end
end
