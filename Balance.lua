-- CraftSell: "Bilanz" page – what does my material bring?
-- Takes the materials you own (bags + what lay in the mailbox when it was last opened),
-- crafts the most profitable recipes of the shown profession from them and
-- compares what the material cost (purchase price from the mailbox, otherwise
-- the current market price) with what the vendor pays for the result.
local ADDON, ns = ...
local P = ns.Prices
local Money = P.FormatMoney

ns.Balance = {}
local B = ns.Balance

local GetCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local MAX_CRAFTS = 4096

-- Takes the material for `n` crafts of `rec` out of `stock`. What is missing
-- is bought when a vendor sells it (ctx.buy), otherwise crafted from the stock
-- when it is an intermediate product. Returns false when the stock does not
-- suffice (ctx.missing; `stock` is then left half used: pass a copy).
local function Consume(rec, n, stock, ctx, visiting)
  visiting[rec] = true
  local ok = true
  for _, r in ipairs(rec.reagents) do
    local id = r.itemID
    if not id then ok = false break end
    local need = (r.count or 1) * n
    local take = math.min(stock[id] or 0, need)
    if take > 0 then
      stock[id] = stock[id] - take
      ctx.taken = ctx.taken + take
    end
    need = need - take
    if need > 0.0001 then
      local sub
      for _, s in ipairs(ctx.byOutput[id] or {}) do
        if not visiting[s] then sub = s break end
      end
      if ctx.vendor[id] then
        ctx.buy[id] = (ctx.buy[id] or 0) + need
      elseif sub then
        local made = math.max(sub.made or 1, 0.01)
        local crafts = math.ceil(need / made - 0.0001)
        if not Consume(sub, crafts, stock, ctx, visiting) then ok = false break end
        stock[id] = (stock[id] or 0) + crafts * made - need
      else
        ctx.missing[id] = (ctx.missing[id] or 0) + need
        ok = false
      end
    end
  end
  visiting[rec] = nil
  return ok
end

local function Head(text)
  return { balance = "head", title = "|cffffd200" .. text .. "|r" }
end

local function Note(text)
  return { balance = "note", title = "|cff888888" .. text .. "|r" }
end

-- Returns the rows of the page and the totals
-- { spend, income, profit, crafts, restValue }.
function B.Build(adapter)
  local all = ns.Scan(adapter, true)        -- rated with the purchase prices

  local byOutput = {}
  for _, rec in ipairs(all) do
    if rec.outputID then
      byOutput[rec.outputID] = byOutput[rec.outputID] or {}
      table.insert(byOutput[rec.outputID], rec)
    end
  end

  -- every material of this profession that you own; vendor goods (thread,
  -- dye, salt ...) need not be in stock: they are bought as needed
  local stock, mats, seen, names, icons = {}, {}, {}, {}, {}
  local vendor = {}
  for _, rec in ipairs(all) do
    for _, r in ipairs(rec.reagents) do
      local id = r.itemID
      if id and not seen[id] then
        seen[id] = true
        names[id], icons[id] = r.name, r.icon
        vendor[id] = P.VendorBuyPrice(id)
        local mail = ns.Mail.InboxCount(id)
        local have = ((GetCount and GetCount(id)) or 0) + mail
        stock[id] = have
        if have > 0 then
          mats[#mats + 1] = {
            balance = "mat", itemID = id, name = r.name, icon = r.icon,
            have = have, mail = mail, unit = r.unit, src = r.src, paid = r.paid, market = r.market,
          }
        end
      end
    end
  end

  local function ItemList(set)
    local parts = {}
    for id, n in pairs(set) do
      parts[#parts + 1] = math.ceil(n - 0.0001) .. "x " .. (names[id] or ("item:" .. id))
    end
    table.sort(parts)
    return table.concat(parts, ", ")
  end

  -- best recipe first (ns.Scan sorts by profit per item): craft as many as
  -- the remaining stock allows
  local plan, why, buy = {}, {}, {}
  local t = { spend = 0, income = 0, profit = 0, crafts = 0, restValue = 0 }
  for _, rec in ipairs(all) do
    if not rec.isIntermediate and #rec.reagents > 0 and rec.sellUnit then
      local function Fits(n)
        local copy = {}
        for k, v in pairs(stock) do copy[k] = v end
        local ctx = { byOutput = byOutput, vendor = vendor, buy = {}, missing = {}, taken = 0 }
        return Consume(rec, n, copy, ctx, {}), copy, ctx
      end
      local reason
      if rec.unknownCost then
        local unpriced = {}
        for _, r in ipairs(rec.reagents) do
          if r.itemID and not r.unit then unpriced[r.itemID] = r.count or 1 end
        end
        reason = "|cffff8000Preis fehlt:|r " .. ItemList(unpriced)
      elseif not (rec.profitItem and rec.profitItem > 0) then
        reason = "|cffff6060Kein Gewinn:|r " .. Money(rec.profitItem) .. " pro Stück"
      else
        local ok, _, ctx = Fits(1)
        if not ok then
          reason = "|cffff8000Fehlt:|r " .. ItemList(ctx.missing)
        elseif ctx.taken > 0 then       -- (made of vendor goods only: not planned)
          local lo, hi = 1, 2
          while hi <= MAX_CRAFTS and Fits(hi) do lo, hi = hi, hi * 2 end
          while hi - lo > 1 do
            local mid = math.floor((lo + hi) / 2)
            if Fits(mid) then lo = mid else hi = mid end
          end
          local _, rest, used = Fits(lo)
          stock = rest
          for id, n in pairs(used.buy) do buy[id] = (buy[id] or 0) + n end
          local cost, sell = rec.cost * lo, rec.sellTotal * lo
          plan[#plan + 1] = {
            balance = "plan", rec = rec, n = lo, icon = rec.icon,
            title = lo .. "x " .. (rec.name or "?"),
            detail = "|cffaaaaaaEinkauf:|r " .. Money(cost) .. "   |cffaaaaaaVerkauf:|r " .. Money(sell),
            right = "|cff40ff40+|r" .. Money(sell - cost),
          }
          t.spend, t.income, t.crafts = t.spend + cost, t.income + sell, t.crafts + lo
        end
      end
      -- nothing planned at all: say why for the best recipes
      if reason and #why < 4 then
        why[#why + 1] = {
          balance = "why", rec = rec, icon = rec.icon,
          title = "|cff9d9d9d" .. (rec.name or "?") .. "|r", detail = reason,
        }
      end
    end
  end
  t.profit = t.income - t.spend

  local buys = {}
  for id, n in pairs(buy) do
    n = math.ceil(n - 0.0001)
    buys[#buys + 1] = {
      balance = "buy", icon = icons[id], cost = vendor[id] * n,
      title = n .. "x " .. (names[id] or ("item:" .. id)),
      detail = "|cffaaaaaaØ|r " .. Money(vendor[id]) .. " |cff888888(Händler, im Einkauf enthalten)|r",
      right = Money(vendor[id] * n),
    }
  end
  table.sort(buys, function(a, b) return a.cost > b.cost end)

  for _, m in ipairs(mats) do
    m.rest = math.floor((stock[m.itemID] or 0) + 0.0001)
    m.value = m.unit and m.unit * m.have
    if m.unit then t.restValue = t.restValue + m.unit * m.rest end
    m.title = m.have .. "x " .. (m.name or ("item:" .. m.itemID))
    local parts = {}
    if m.unit then
      parts[#parts + 1] = "|cffaaaaaaØ|r " .. Money(m.unit) .. " |cff888888(" .. (m.src or "?") .. ")|r"
    else
      parts[#parts + 1] = "|cffff8000kein Preis|r"
    end
    if m.mail > 0 then parts[#parts + 1] = "|cff80c0ff" .. m.mail .. " im Postfach|r" end
    if m.rest > 0 then parts[#parts + 1] = "|cffaaaaaaRest|r " .. m.rest end
    m.detail = table.concat(parts, "   ")
    m.right = m.value and Money(m.value) or ""
  end
  table.sort(mats, function(a, b)
    if (a.value or 0) ~= (b.value or 0) then return (a.value or 0) > (b.value or 0) end
    return (a.name or "") < (b.name or "")
  end)

  local list = { Head("Herstellen und beim Händler verkaufen") }
  if #plan == 0 then
    if #mats == 0 then
      list[#list + 1] = Note("Kein Material dieses Berufs im Bestand")
    elseif #why == 0 then
      list[#list + 1] = Note("Kein Rezept für dieses Material bekannt")
    else
      list[#list + 1] = Note("Nichts herstellbar – die besten Rezepte:")
      for _, e in ipairs(why) do list[#list + 1] = e end
    end
  end
  for _, e in ipairs(plan) do list[#list + 1] = e end
  if #buys > 0 then
    list[#list + 1] = Head("Beim Händler dazukaufen")
    for _, e in ipairs(buys) do list[#list + 1] = e end
  end
  list[#list + 1] = Head("Material im Bestand (Einkaufswert)")
  if #mats == 0 then list[#list + 1] = Note("Nichts in den Taschen oder im Postfach") end
  for _, m in ipairs(mats) do list[#list + 1] = m end
  return list, t
end

-- Tooltip of a material row.
function B.MaterialTooltip(tt, m)
  tt:AddLine(" ")
  tt:AddLine("|cffffd200CraftSell – Bilanz|r")
  tt:AddDoubleLine("Bestand", m.have .. (m.mail > 0 and ("  (davon " .. m.mail .. " im Postfach)") or ""), 1, 1, 1, 1, 1, 1)
  if m.unit then
    tt:AddDoubleLine("Preis pro Stück (" .. (m.src or "?") .. ")", Money(m.unit), 1, 1, 1, 1, 1, 1)
    tt:AddDoubleLine("Wert des Bestands", Money(m.value), 1, 1, 1, 1, 1, 1)
  else
    tt:AddLine("Kein Preis bekannt – einmal im AH scannen.", 1, 0.5, 0, true)
  end
  if m.paid and m.market then
    tt:AddDoubleLine("Aktueller Marktpreis pro Stück", Money(m.market), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
  end
  tt:AddDoubleLine("Bleibt nach dem Herstellen übrig", tostring(m.rest), 1, 1, 1, 1, 1, 1)
end

-- Tooltip of the summary box.
function B.SummaryTooltip(tt)
  tt:AddLine("CraftSell – Bilanz")
  tt:AddLine("Rechnet aus, was dein Material bringt, wenn du es herstellst und beim Händler verkaufst.", 1, 1, 1, true)
  tt:AddLine(" ")
  tt:AddLine("Bestand = Taschen + alles, was im Postfach liegt (Stand: letztes Öffnen der Post).", 0.8, 0.8, 0.8, true)
  tt:AddLine("Einkauf = was du im Auktionshaus bezahlt hast (\"Auktion gewonnen\"-Briefe). Für nicht gekauftes Material zählt der aktuelle Marktpreis.", 0.8, 0.8, 0.8, true)
  tt:AddLine("Verkauf = Händlerpreis der hergestellten Gegenstände.", 0.8, 0.8, 0.8, true)
  tt:AddLine("Händlerware (Faden, Farbe, Salz ...) muss nicht vorrätig sein: sie wird als Zukauf eingerechnet. Dafür muss CraftSell den Händlerpreis kennen – den Händler einmal öffnen.", 0.8, 0.8, 0.8, true)
  tt:AddLine("Das beste Rezept kommt zuerst dran, dann das nächste mit dem restlichen Material. Rezepte ohne Gewinn werden nicht eingeplant.", 0.8, 0.8, 0.8, true)
end
