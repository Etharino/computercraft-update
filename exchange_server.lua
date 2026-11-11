-- exchange_server.lua :: the shared AURA stock exchange. run this on ONE computer with a modem.
--   runs the market (6 made-up stocks, 1-second candles, breaking news), keeps every player's
--   account (cash + shares) and saves it all in exchange.db. players connect with exchange.lua.
--
-- needs: a modem (wireless or ender modem, or wired to the client computers).
-- optional: a monitor (shows the live leaderboard), a chat box (announces big trades + news).
-- the terminal shows a live log of logins, trades and news. ctrl+T stops the server.

local PROTO = "aura_exchange"
local SAVE = "exchange.db"
local START_CASH = 1000
local CANDLE_TICKS = 20

local G = { tick = 0, acc = {}, sessions = {}, dirty = false, lastSave = 0, log = {} }

local STOCKS = {
  { tk = "AURA", name = "AURA CORP",       base = 120, vol = 0.010 },
  { tk = "RIZZ", name = "RIZZ INDUSTRIES", base = 45,  vol = 0.014 },
  { tk = "MOGG", name = "MOGG MOTORS",     base = 300, vol = 0.008 },
  { tk = "NUKE", name = "NUKE ENERGY",     base = 80,  vol = 0.012 },
  { tk = "LAVA", name = "LAVA LAMP INC",   base = 12,  vol = 0.018 },
  { tk = "OHIO", name = "OHIO COIN",       base = 3,   vol = 0.030 },
}
local BYTK = {}
for _, s in ipairs(STOCKS) do BYTK[s.tk] = s end
local GOOD_NEWS = { "%s CEO MOGS RIVAL ON LIVE TV", "%s SIGNS DEAL WITH THE CREEPER UNION",
  "%s ANNOUNCES AURA FARMING DIVISION", "ANALYSTS: %s IS LOWKEY HIM", "%s TO THE MOON",
  "%s FACTORY SURVIVES ANOTHER EXPLOSION", "%s ADDED TO THE INDEX" }
local BAD_NEWS = { "%s CEO CAUGHT LACKING", "%s FACTORY EXPLODES AGAIN", "ANALYSTS: %s IS MID",
  "%s RUG PULL RUMOURS", "%s FINED FOR TOO MUCH RIZZ", "%s WAREHOUSE STOLEN BY ENDERMEN",
  "%s RECALLS 10K FAULTY CANNONS" }

---------------------------------------------------------------- peripherals
local opened = 0
for _, m in ipairs({ peripheral.find("modem") }) do
  rednet.open(peripheral.getName(m))
  opened = opened + 1
end
if opened == 0 then
  printError("attach a modem (wireless, ender or wired) to this computer.")
  return
end
rednet.host(PROTO, "exchange-" .. os.getComputerID())
local chat = peripheral.find("chatBox") or peripheral.find("chat_box")
local mon = peripheral.find("monitor")
local function now() return os.epoch("utc") / 1000 end

local function log(s, col)
  G.log[#G.log + 1] = { os.date and os.date("%H:%M:%S") or "", s, col or colors.white }
  if #G.log > 200 then table.remove(G.log, 1) end
  G.logDirty = true
end
local function announce(s)
  if chat then pcall(chat.sendMessage, s, "EXCHANGE") end
end
local function fmt(p)
  if p < 10 then return string.format("%.2f", p) end
  if p < 1000 then return string.format("%.1f", p) end
  return tostring(math.floor(p + 0.5))
end

---------------------------------------------------------------- market
local function gauss()
  local u1, u2 = math.max(1e-9, math.random()), math.random()
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end
local function newCandle(s)
  s.cur = { o = s.price, h = s.price, l = s.price, c = s.price }
  s.candles[#s.candles + 1] = s.cur
  s.n = (s.n or 0) + 1
  if #s.candles > 120 then table.remove(s.candles, 1) end
end
local function stepStock(s)
  local perTick = s.vol / math.sqrt(CANDLE_TICKS)
  local drift = -0.002 * math.log(s.price / s.base) + (s.push or 0)
  s.price = math.max(0.05, s.price * math.exp(drift + perTick * gauss()))
  if s.pushLeft then
    s.pushLeft = s.pushLeft - 1
    if s.pushLeft <= 0 then s.push, s.pushLeft = nil, nil end
  end
  local c = s.cur
  c.c = s.price
  if s.price > c.h then c.h = s.price end
  if s.price < c.l then c.l = s.price end
end
local function marketTick()
  G.tick = G.tick + 1
  for _, s in ipairs(STOCKS) do
    stepStock(s)
    if G.tick % CANDLE_TICKS == 0 then newCandle(s) end
  end
end
local function maybeNews()
  local forced = CC_SIM and CC_SIM.forceNews
  if forced then CC_SIM.forceNews = nil end
  if not forced and math.random() >= 1 / 500 then return end
  local s = STOCKS[math.random(#STOCKS)]
  local good = math.random() < 0.5
  local mag = 0.08 + math.random() * 0.25
  if math.random() < 0.12 then mag = mag * 3 end
  if forced then s, good, mag = BYTK[forced] or STOCKS[1], true, 0.6 end
  local list = good and GOOD_NEWS or BAD_NEWS
  local headline = string.format(list[math.random(#list)], s.tk)
  local dur = math.random(40, 100)
  s.push = (good and 1 or -1) * math.log(1 + mag) / dur
  s.pushLeft = dur
  rednet.broadcast({ type = "feed", kind = good and "good" or "bad", text = "BREAKING: " .. headline }, PROTO)
  log("NEWS " .. headline, good and colors.lime or colors.red)
  if mag >= 0.5 then announce(headline .. (good and " (+" or " (-") .. math.floor(mag * 100) .. "%)") end
end
local function broadcastTick()
  local q = {}
  for _, s in ipairs(STOCKS) do
    local c = s.cur
    q[s.tk] = { p = s.price, n = s.n, o = c.o, h = c.h, l = c.l, c = c.c }
  end
  rednet.broadcast({ type = "tick", q = q, t = G.tick }, PROTO)
end

---------------------------------------------------------------- accounts
local function netWorth(a)
  local v = a.cash
  for tk, h in pairs(a.holdings) do if BYTK[tk] then v = v + h.qty * BYTK[tk].price end end
  return v
end
local function view(a) return { name = a.name, cash = a.cash, holdings = a.holdings, worth = netWorth(a) } end

local function save()
  local d = { acc = G.acc, prices = {} }
  for _, s in ipairs(STOCKS) do d.prices[s.tk] = s.price end
  local f = fs.open(SAVE, "w")
  f.write(textutils.serialize(d))
  f.close()
  G.dirty, G.lastSave = false, now()
end
local function load()
  if not fs.exists(SAVE) then return end
  local f = fs.open(SAVE, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) ~= "table" then return end
  if type(d.acc) == "table" then G.acc = d.acc end
  if type(d.prices) == "table" then
    for _, s in ipairs(STOCKS) do if tonumber(d.prices[s.tk]) then s.price = tonumber(d.prices[s.tk]) end end
  end
end

local function feed(text, kind) rednet.broadcast({ type = "feed", kind = kind or "trade", text = text }, PROTO) end
local function session(id)
  local key = G.sessions[id]
  return key and G.acc[key]
end

local H = {}
function H.hello()
  local list = {}
  for _, s in ipairs(STOCKS) do list[#list + 1] = { tk = s.tk, name = s.name } end
  return { type = "welcome", stocks = list, candleTicks = CANDLE_TICKS }
end
function H.history(_, m)
  local s = BYTK[m.tk]
  if not s then return { type = "err", msg = "UNKNOWN STOCK" } end
  return { type = "history", tk = s.tk, n = s.n, price = s.price, candles = s.candles }
end
function H.login(id, m)
  local name = tostring(m.name or ""):gsub("[^%w_]", ""):sub(1, 12)
  local pin = tostring(m.pin or "")
  if #name < 2 then return { type = "err", msg = "NAME MUST BE 2-12 LETTERS" } end
  local key = name:lower()
  local a = G.acc[key]
  if not a then
    a = { name = name:upper(), pin = pin, cash = START_CASH, holdings = {} }
    G.acc[key] = a
    G.dirty = true
    log("NEW ACCOUNT " .. a.name, colors.cyan)
    feed(a.name .. " JOINED THE EXCHANGE", "join")
  elseif a.pin ~= pin then
    log("WRONG PIN FOR " .. a.name .. " (computer " .. id .. ")", colors.orange)
    return { type = "err", msg = "WRONG PIN FOR " .. a.name }
  else
    log(a.name .. " LOGGED IN (computer " .. id .. ")", colors.cyan)
  end
  G.sessions[id] = key
  return { type = "login_ok", account = view(a) }
end
local function trade(id, m, isBuy)
  local a = session(id)
  if not a then return { type = "err", msg = "NOT LOGGED IN" } end
  local s = BYTK[m.tk]
  local q = math.floor(tonumber(m.qty) or 0)
  if not s or q <= 0 then return { type = "err", msg = "BAD ORDER" } end
  local p = s.price
  if isBuy then
    local cost = math.ceil(p * q)
    if cost > a.cash then return { type = "err", msg = "NOT ENOUGH CASH" } end
    a.cash = a.cash - cost
    local h = a.holdings[s.tk] or { qty = 0, avg = 0 }
    h.avg = (h.avg * h.qty + p * q) / (h.qty + q)
    h.qty = h.qty + q
    a.holdings[s.tk] = h
    G.dirty = true
    feed(a.name .. " BOUGHT " .. q .. " " .. s.tk .. " @ " .. fmt(p), "buy")
    log(a.name .. " BUY " .. q .. " " .. s.tk .. " @ " .. fmt(p), colors.lime)
    if cost >= 2000 then announce(a.name .. " just bought " .. q .. " " .. s.tk .. " (" .. cost .. " credits)") end
    return { type = "account", account = view(a), trade = { side = "buy", tk = s.tk, qty = q, price = p } }
  end
  local h = a.holdings[s.tk]
  q = math.min(q, h and h.qty or 0)
  if q <= 0 then return { type = "err", msg = "NOTHING TO SELL" } end
  local proceeds = math.floor(p * q)
  local pnl = (p - h.avg) * q
  a.cash = a.cash + proceeds
  h.qty = h.qty - q
  if h.qty <= 0 then a.holdings[s.tk] = nil end
  G.dirty = true
  feed(a.name .. " SOLD " .. q .. " " .. s.tk .. " " .. ((pnl >= 0) and "+" or "") .. math.floor(pnl), pnl >= 0 and "win" or "loss")
  log(a.name .. " SELL " .. q .. " " .. s.tk .. " @ " .. fmt(p) .. " pnl " .. math.floor(pnl), colors.orange)
  if pnl >= 1000 then announce(a.name .. " took +" .. math.floor(pnl) .. " profit on " .. s.tk) end
  return { type = "account", account = view(a), trade = { side = "sell", tk = s.tk, qty = q, price = p, pnl = pnl } }
end
function H.buy(id, m) return trade(id, m, true) end
function H.sell(id, m) return trade(id, m, false) end
function H.account(id)
  local a = session(id)
  if not a then return { type = "err", msg = "NOT LOGGED IN" } end
  return { type = "account", account = view(a) }
end
-- moving credits between a player's casino balance (slots.db on their computer) and the exchange
function H.deposit(id, m)
  local a = session(id)
  local amt = math.floor(tonumber(m.amount) or 0)
  if not a or amt <= 0 or amt > 100000 then return { type = "err", msg = "BAD DEPOSIT" } end
  a.cash = a.cash + amt
  G.dirty = true
  log(a.name .. " DEPOSIT " .. amt, colors.yellow)
  return { type = "account", account = view(a), trade = { side = "deposit", amount = amt } }
end
function H.withdraw(id, m)
  local a = session(id)
  local amt = math.floor(tonumber(m.amount) or 0)
  if not a or amt <= 0 then return { type = "err", msg = "BAD WITHDRAW" } end
  if amt > a.cash then return { type = "err", msg = "NOT ENOUGH CASH" } end
  a.cash = a.cash - amt
  G.dirty = true
  log(a.name .. " WITHDRAW " .. amt, colors.yellow)
  return { type = "account", account = view(a), trade = { side = "withdraw", amount = amt } }
end
local function leaderboard()
  local rows = {}
  for _, a in pairs(G.acc) do rows[#rows + 1] = { name = a.name, worth = netWorth(a) } end
  table.sort(rows, function(x, y) return x.worth > y.worth end)
  return rows
end
function H.board()
  local rows = leaderboard()
  local top = {}
  for i = 1, math.min(10, #rows) do top[i] = rows[i] end
  return { type = "board", rows = top }
end

---------------------------------------------------------------- server screens
local function drawTerminal()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setBackgroundColor(colors.blue)
  term.clearLine()
  local online = 0
  for _ in pairs(G.sessions) do online = online + 1 end
  term.setTextColor(colors.white)
  term.write((" AURA EXCHANGE  id %d  online %d  ctrl+T stops"):format(os.getComputerID(), online):sub(1, w))
  term.setBackgroundColor(colors.black)
  local lines = h - 1
  local first = math.max(1, #G.log - lines + 1)
  for i = first, #G.log do
    local e = G.log[i]
    term.setCursorPos(1, 2 + i - first)
    term.setTextColor(colors.gray)
    term.write(e[1] .. " ")
    term.setTextColor(e[3])
    term.write(e[2]:sub(1, w - #e[1] - 1))
  end
end
local function drawMonitor()
  if not mon then return end
  mon.setTextScale(1)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  mon.setCursorPos(1, 1)
  mon.setBackgroundColor(colors.purple)
  mon.setTextColor(colors.white)
  mon.clearLine()
  local title = "AURA EXCHANGE - TOP TRADERS"
  mon.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), 1)
  mon.write(title)
  mon.setBackgroundColor(colors.black)
  local rows = leaderboard()
  for i = 1, math.min(#rows, h - 3) do
    local r = rows[i]
    mon.setCursorPos(2, i + 2)
    mon.setTextColor(i == 1 and colors.yellow or (i <= 3 and colors.orange or colors.lightGray))
    mon.write(("#%d %s"):format(i, r.name))
    local v = tostring(math.floor(r.worth))
    mon.setCursorPos(w - #v, i + 2)
    mon.setTextColor(r.worth >= START_CASH and colors.lime or colors.red)
    mon.write(v)
  end
  local line = ""
  for _, s in ipairs(STOCKS) do line = line .. s.tk .. " " .. fmt(s.price) .. "  " end
  mon.setCursorPos(1, h)
  mon.setTextColor(colors.cyan)
  mon.write(line:sub(1, w))
end

---------------------------------------------------------------- run
for _, s in ipairs(STOCKS) do s.price = s.base s.candles = {} end
load()
for _, s in ipairs(STOCKS) do newCandle(s) end
for _ = 1, CANDLE_TICKS * 60 do marketTick() end   -- pre-roll some history
log("exchange online on computer " .. os.getComputerID(), colors.lime)
local nAcc = 0
for _ in pairs(G.acc) do nAcc = nAcc + 1 end
log(nAcc .. " saved accounts", colors.lightGray)

local function marketLoop()
  while true do
    sleep(0.05)
    marketTick()
    maybeNews()
    if G.tick % 4 == 0 then broadcastTick() end
    if G.dirty and now() - G.lastSave > 2 then save() end
  end
end
local function netLoop()
  while true do
    local id, msg = rednet.receive(PROTO)
    if type(msg) == "table" and type(msg.type) == "string" and H[msg.type] then
      local ok, reply = pcall(H[msg.type], id, msg)
      if not ok then
        log("error handling " .. msg.type .. ": " .. tostring(reply), colors.red)
        reply = { type = "err", msg = "SERVER ERROR" }
      end
      if reply then
        reply.re = msg.req
        rednet.send(id, reply, PROTO)
      end
    end
  end
end
local function screenLoop()
  while true do
    if G.logDirty then drawTerminal() G.logDirty = false end
    drawMonitor()
    sleep(1)
  end
end

local ok, err = pcall(parallel.waitForAny, marketLoop, netLoop, screenLoop)
save()
rednet.unhost(PROTO)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("exchange stopped. accounts saved.")
