-- exchange.lua :: multiplayer client for the AURA stock exchange (CC: Graphics neon terminal).
--   everyone running this trades on the SAME live market hosted by exchange_server.lua:
--   shared prices and candles, breaking news, a feed of everyone's trades, and a leaderboard.
--
-- needs: a modem (wireless / ender / wired) + ccgraphics, and exchange_server running somewhere.
-- first run asks for a player name + PIN (saved in exchange.login; delete it to switch player).
-- controls:
--   tap/click a stock to chart it.  BUY / SELL.  QTY cycles 1/10/100/MAX.  TOP = leaderboard,
--   where DEPOSIT / WITHDRAW move 100 credits between your casino balance (slots.db) and the exchange.
--   keyboard: up/down pick stock, b buy, s sell, x quantity, t leaderboard, d deposit, w withdraw, q quit

local lib = require("auralib")
math.randomseed(os.epoch("utc"))
local PROTO = "aura_exchange"

-- all state lives in G and palette indices in C (CC's Lua caps upvalues at 60 / locals at 200)
local G = { sel = 1, qtyIdx = 1, coins = {}, showerUntil = 0, news = nil, flashT = -100, flashKind = "up",
  tapeX = 0, feedQ = {}, view = "chart", board = {}, lastTick = 0, req = 0, msg = "" }
local C = {}
local QTYS = { 1, 10, 100, "MAX" }
local CREDITS_FILE, LOGIN_FILE = "slots.db", "exchange.login"
local STOCKS = {}

lib.font["%"] = { "#.#", "..#", ".#.", "#..", "#.#" }
lib.font["/"] = { "..#", "..#", ".#.", "#..", "#.." }
lib.font["@"] = { ".#.", "#.#", "###", "#..", ".##" }

local function now() return os.epoch("utc") / 1000 end
local function beep(sound, pitch, vol) if G.speaker then pcall(G.speaker.playSound, sound, vol or 2, pitch or 1) end end

---------------------------------------------------------------- connect + log in (text mode)
local function send(msg)
  G.req = G.req + 1
  msg.req = G.req
  rednet.send(G.server, msg, PROTO)
  return msg.req
end
-- send a request and wait for the matching reply (used before the graphics loop starts)
local function request(msg, timeout)
  local id = send(msg)
  local deadline = now() + (timeout or 4)
  while true do
    local left = deadline - now()
    if left <= 0 then return nil end
    local from, r = rednet.receive(PROTO, left)
    if not from then return nil end
    if from == G.server and type(r) == "table" and r.re == id then return r end
  end
end

do
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.magenta)
  print("AURA EXCHANGE")
  term.setTextColor(colors.white)
  local opened = 0
  for _, m in ipairs({ peripheral.find("modem") }) do rednet.open(peripheral.getName(m)) opened = opened + 1 end
  if opened == 0 then
    printError("attach a modem (wireless, ender or wired) first.")
    return
  end
  print("looking for the exchange server...")
  G.server = rednet.lookup(PROTO)
  if not G.server then
    printError("no exchange server found.")
    print("run exchange_server on another computer with a modem, in range of this one.")
    return
  end
  print("found it on computer " .. G.server)
  local saved
  if fs.exists(LOGIN_FILE) then
    local f = fs.open(LOGIN_FILE, "r")
    saved = textutils.unserialize(f.readAll())
    f.close()
  end
  while not G.acc do
    local name, pin
    if type(saved) == "table" and saved.name then
      name, pin = saved.name, saved.pin
    else
      write("player name: ")
      name = read()
      write("PIN (pick one, you'll need it again): ")
      pin = read("*")
    end
    local r = request({ type = "login", name = name, pin = pin }, 5)
    if not r then
      printError("the server didn't answer. is it running?")
      return
    elseif r.type == "err" then
      printError(r.msg)
      saved = nil
      if fs.exists(LOGIN_FILE) then fs.delete(LOGIN_FILE) end
    else
      G.acc = r.account
      G.login = { name = name, pin = pin }
      local f = fs.open(LOGIN_FILE, "w")
      f.write(textutils.serialize(G.login))
      f.close()
    end
  end
  print("logged in as " .. G.acc.name)
  local w = request({ type = "hello" }, 5)
  if not w or w.type ~= "welcome" then printError("couldn't get the market from the server") return end
  for _, s in ipairs(w.stocks) do
    local h = request({ type = "history", tk = s.tk }, 5)
    if not h or h.type ~= "history" then printError("couldn't load " .. s.tk) return end
    local st = { tk = s.tk, name = s.name, candles = h.candles, n = h.n, price = h.price }
    st.cur = st.candles[#st.candles]
    STOCKS[#STOCKS + 1] = st
    print("  loaded " .. s.tk)
  end
  G.lastTick = now()
end

---------------------------------------------------------------- screen
local t = peripheral.find("monitor")
if not (t and type(t.setGraphicsMode) == "function") then
  t = nil
  if type(term.setGraphicsMode) == "function" then t = term end
end
if not t then
  printError("no CC: Graphics graphics mode on this screen.")
  print("needs the ccgraphics mod + an advanced computer or advanced monitor.")
  return
end
G.isMon = (t ~= term)
if G.isMon then
  local chosen = 5
  for s = 0.5, 5, 0.5 do
    t.setTextScale(s)
    local w, h = t.getSize()
    if w * 6 * h * 9 <= 175000 then chosen = s break end
  end
  t.setTextScale(chosen)
end
do
  local ok, err = pcall(t.setGraphicsMode, 2)
  if not ok then printError("couldn't enter 256-colour graphics mode: " .. tostring(err)) return end
  local ok2, w, h = pcall(t.getSize, 2)
  if ok2 and type(w) == "number" and type(h) == "number" then G.PW, G.PH = w, h
  else local cw, ch = t.getSize() G.PW, G.PH = cw * 6, ch * 9 end
end
local PW, PH = G.PW, G.PH
G.speaker = peripheral.find("speaker")
G.chat = lib.findAny("chatBox", "chat_box")

---------------------------------------------------------------- palette
local palCache = {}
local function setPal(i, c)
  if palCache[i] == c then return end
  palCache[i] = c
  pcall(t.setPaletteColor, i, c)
end
local function mix(a, b, f)
  local ar, ag, ab = math.floor(a / 65536) % 256, math.floor(a / 256) % 256, a % 256
  local br, bg, bb = math.floor(b / 65536) % 256, math.floor(b / 256) % 256, b % 256
  return math.floor(ar + (br - ar) * f + 0.5) * 65536 + math.floor(ag + (bg - ag) * f + 0.5) * 256
    + math.floor(ab + (bb - ab) * f + 0.5)
end
local function ramp(stops, n)
  local out = {}
  for k = 0, n - 1 do
    local f = (n == 1) and 0 or k / (n - 1) * (#stops - 1)
    local s = math.floor(f)
    out[k + 1] = mix(stops[math.min(s + 1, #stops)], stops[math.min(s + 2, #stops)], f - s)
  end
  return out
end
G.nextIdx = 16
local function family(list)
  local base = G.nextIdx
  for k, c in ipairs(list) do setPal(base + k - 1, c) end
  G.nextIdx = G.nextIdx + #list
  return base
end
C.BG      = family(ramp({ 0x04050d, 0x0a0f24, 0x111838 }, 16))
C.PANEL   = family({ 0x0b1030 })
C.PANEL2  = family({ 0x10173e })
C.GRID    = family({ 0x182250 })
C.GRID2   = family({ 0x22306a })
C.UP      = family({ 0x0a3a24, 0x10804a, 0x20e080, 0x9affc8 })
C.DN      = family({ 0x4a0a18, 0x9a1830, 0xff3b5c, 0xffa0b0 })
C.MA      = family({ 0xffc830 })
C.TEXT    = family({ 0xe8f0ff })
C.DIM     = family({ 0x7080b0 })
C.YELLOW  = family({ 0xffe040 })
C.CYAN    = family({ 0x40e8ff, 0x1a6a90, 0x0d3048 })
C.OUTLINE = family({ 0x02030a })
C.WHITE   = family({ 0xffffff })
C.GLOW    = family({ 0x1f6f9f })     -- animated panel border
C.LIVEUP  = family({ 0x20e080 })     -- animated latest-candle colours
C.LIVEDN  = family({ 0xff3b5c })
C.NEWS    = family({ 0xffe040 })     -- animated news text
C.FLASH   = family({ 0x0b1030 })     -- animated trade flash border
C.AREAUP  = family({ 0x0c3a2a })
C.AREADN  = family({ 0x3a0c1c })
C.BUY     = family({ 0x06301a, 0x0e8a46, 0x40f090 })
C.SELL    = family({ 0x30060e, 0x9a1830, 0xff6080 })
C.QTY     = family({ 0x0c2440, 0x1a5a9a, 0x60c0ff })
C.GOLD    = family({ 0x5c3a0c, 0xbf8a1b, 0xf2c33a, 0xfff0a0 })

---------------------------------------------------------------- framebuffer + helpers
local fb = {}
for y = 1, PH do
  local r = {}
  for x = 1, PW do r[x] = C.BG end
  fb[y] = r
end
local function put(x, y, c)
  local r = fb[y + 1]
  if r and x >= 0 and x < PW then r[x + 1] = c end
end
local function push(x, y, w, h)
  x, y, w, h = math.floor(x), math.floor(y), math.ceil(w), math.ceil(h)
  if x < 0 then w = w + x x = 0 end
  if y < 0 then h = h + y y = 0 end
  if x + w > PW then w = PW - x end
  if y + h > PH then h = PH - y end
  if w <= 0 or h <= 0 then return end
  local rows = {}
  for j = 1, h do
    local row, parts, i = fb[y + j], {}, x + 1
    while i <= x + w do
      local k = math.min(i + 199, x + w)
      parts[#parts + 1] = string.char(table.unpack(row, i, k))
      i = k + 1
    end
    rows[j] = table.concat(parts)
  end
  t.drawPixels(x, y, rows)
end
local function freeze(b) if type(t.setFrozen) == "function" then pcall(t.setFrozen, b) end end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function rect(x, y, w, h, c)
  for yy = math.max(0, y), math.min(PH - 1, y + h - 1) do
    local row = fb[yy + 1]
    for xx = math.max(0, x), math.min(PW - 1, x + w - 1) do row[xx + 1] = c end
  end
end
local function frame(x, y, w, h, c)
  rect(x, y, w, 1, c) rect(x, y + h - 1, w, 1, c) rect(x, y, 1, h, c) rect(x + w - 1, y, 1, h, c)
end
local function disk(cx, cy, r, fn)
  for y = math.floor(cy - r), math.ceil(cy + r) do
    for x = math.floor(cx - r), math.ceil(cx + r) do
      local a, b = (x - cx) / r, (y - cy) / r
      if a * a + b * b <= 1 then local c = fn(a, b) if c then put(x, y, c) end end
    end
  end
end
local function textW(s, sc) return (#s * 4 - 1) * sc end
local function text(x, y, s, sc, col, outline)
  s = s:upper()
  local passes = outline and { { outline, 1 }, { col, 0 } } or { { col, 0 } }
  for _, pass in ipairs(passes) do
    local color, grow = pass[1], pass[2]
    for ci = 1, #s do
      local g = lib.font[s:sub(ci, ci)] or lib.font[" "]
      for gy = 1, 5 do
        local row = g[gy]
        for gx = 1, 3 do
          if row:sub(gx, gx) == "#" then
            local px, py = x + (ci - 1) * 4 * sc + (gx - 1) * sc, y + (gy - 1) * sc
            for yy = py - grow, py + sc - 1 + grow do
              for xx = px - grow, px + sc - 1 + grow do put(xx, yy, color) end
            end
          end
        end
      end
    end
  end
end
local function fitScale(s, w, h, maxSc)
  return clamp(math.min(math.floor((w - 2) / math.max(1, textW(s, 1))), math.floor((h - 2) / 5)), 1, maxSc or 99)
end
-- align: "l", "c", "r"
local function textIn(x, y, w, h, s, col, outline, maxSc, align)
  local sc = fitScale(s, w, h, maxSc)
  local tw = textW(s, sc)
  local tx = x + math.floor((w - tw) / 2)
  if align == "l" then tx = x + 1 elseif align == "r" then tx = x + w - tw - 1 end
  text(tx, y + math.floor((h - 5 * sc) / 2), s, sc, col, outline)
  return sc
end
local function fmtPrice(p)
  if p < 10 then return string.format("%.2f", p) end
  if p < 1000 then return string.format("%.1f", p) end
  return tostring(math.floor(p + 0.5))
end
local function short(n)
  local neg = n < 0
  n = math.abs(n)
  local s
  if n >= 1000000 then s = string.format("%.1fM", n / 1000000)
  elseif n >= 10000 then s = math.floor(n / 1000) .. "K"
  elseif n >= 1000 then s = string.format("%.1fK", n / 1000)
  else s = tostring(math.floor(n + 0.5)) end
  return (neg and "-" or "") .. s
end
local function pctStr(p) return string.format("%+.1f%%", p) end

C.TOPB    = family({ 0x2a0c40, 0x7a2ac0, 0xd090ff })
C.ME      = family({ 0x1a2a5a })

---------------------------------------------------------------- layout
local function computeLayout()
  local m = math.max(2, math.floor(math.min(PW, PH) * 0.015))
  local gap = m
  G.gap = gap
  local tapeH = (PH >= 300) and 15 or 9
  G.tape = { x = 0, y = PH - tapeH, w = PW, h = tapeH }
  if PW >= PH * 1.15 then
    local headH = math.max(20, math.floor(PH * 0.14))
    local rw = math.floor(PW * 0.33)
    G.head = { x = m, y = m, w = PW - rw - 3 * m, h = headH }
    G.chart = { x = m, y = m + headH + gap, w = PW - rw - 3 * m, h = PH - tapeH - headH - 2 * gap - m }
    local rx = PW - rw - m
    local avail = PH - tapeH - 2 * m
    local btnH = math.max(12, math.floor(avail * 0.14))
    local posH = math.max(26, math.floor(avail * 0.26))
    G.list = { x = rx, y = m, w = rw, h = avail - btnH - posH - 2 * gap, cols = 1 }
    G.pos = { x = rx, y = G.list.y + G.list.h + gap, w = rw, h = posH }
    G.btnRow = { x = rx, y = G.pos.y + posH + gap, w = rw, h = btnH }
  else
    local w = PW - 2 * m
    local avail = PH - tapeH - 2 * m
    local headH = math.max(22, math.floor(avail * 0.1))
    local listH = math.floor(avail * 0.2)
    local posH = math.floor(avail * 0.12)
    local btnH = math.floor(avail * 0.08)
    local chartH = avail - headH - listH - posH - btnH - 4 * gap
    G.head = { x = m, y = m, w = w, h = headH }
    G.chart = { x = m, y = m + headH + gap, w = w, h = chartH }
    G.list = { x = m, y = G.chart.y + chartH + gap, w = w, h = listH, cols = 2 }
    G.pos = { x = m, y = G.list.y + listH + gap, w = w, h = posH }
    G.btnRow = { x = m, y = G.pos.y + posH + gap, w = w, h = btnH }
  end
  G.rows = {}
  local L = G.list
  local per = math.ceil(#STOCKS / L.cols)
  local rh = math.floor((L.h - 2) / per)
  local cw = math.floor((L.w - 2) / L.cols)
  for i = 1, #STOCKS do
    local col, row = math.floor((i - 1) / per), (i - 1) % per
    G.rows[i] = { x = L.x + 1 + col * cw, y = L.y + 1 + row * rh, w = cw - 1, h = rh - 1 }
  end
  local B = G.btnRow
  local bw = math.floor((B.w - 3 * gap) / 4)
  G.buttons = {}
  for k, id in ipairs({ "buy", "qty", "sell", "top" }) do
    local x = B.x + (k - 1) * (bw + gap)
    G.buttons[k] = { id = id, x = x, y = B.y, w = (k == 4) and (B.x + B.w - x) or bw, h = B.h }
  end
  -- deposit / withdraw buttons live at the bottom of the leaderboard panel
  local R = G.chart
  local bh = math.max(12, math.floor(R.h * 0.13))
  local hw = math.floor((R.w - 6 - gap) / 2)
  G.bankButtons = {
    { id = "deposit", x = R.x + 3, y = R.y + R.h - bh - 3, w = hw, h = bh },
    { id = "withdraw", x = R.x + 3 + hw + gap, y = R.y + R.h - bh - 3, w = R.w - 6 - hw - gap, h = bh },
  }
end

---------------------------------------------------------------- drawing
local function panelBox(r, fill)
  rect(r.x, r.y, r.w, r.h, fill or C.PANEL)
  frame(r.x, r.y, r.w, r.h, C.GLOW)
end

local function drawBackground()
  for y = 0, PH - 1 do
    local c = C.BG + clamp(math.floor(y / PH * 16), 0, 15)
    local row = fb[y + 1]
    for x = 1, PW do row[x] = c end
  end
  for y = 0, PH - 1, 12 do for x = 0, PW - 1, 2 do put(x, y, C.GRID) end end
end

local function openPrice(s)
  local first = s.candles[math.max(1, #s.candles - 59)]
  return first.o
end

local function offline() return now() - G.lastTick > 3 end

local function drawHeader()
  local H, s = G.head, STOCKS[G.sel]
  panelBox(H, C.PANEL)
  local chg = (s.price / openPrice(s) - 1) * 100
  local up = chg >= 0
  local half = math.floor(H.w * 0.42)
  local sc = textIn(H.x + 3, H.y + 2, half, math.floor(H.h * 0.62), s.tk, C.WHITE, C.OUTLINE, 5, "l")
  textIn(H.x + 3, H.y + math.floor(H.h * 0.62), half, H.h - math.floor(H.h * 0.62) - 2, s.name, C.DIM, nil, 2, "l")
  local px = H.x + half
  local pw = H.w - half - 4
  textIn(px, H.y + 2, pw, math.floor(H.h * 0.62), fmtPrice(s.price), up and C.LIVEUP or C.LIVEDN, C.OUTLINE, math.max(1, sc), "r")
  local sub = offline() and "OFFLINE - RECONNECTING" or (pctStr(chg) .. " TODAY  LIVE")
  textIn(px, H.y + math.floor(H.h * 0.62), pw, H.h - math.floor(H.h * 0.62) - 2, sub,
    offline() and C.DN + 2 or (up and C.UP + 2 or C.DN + 2), nil, 2, "r")
  push(H.x, H.y, H.w, H.h)
end

local BAYER = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }

local function drawChart()
  local R, s = G.chart, STOCKS[G.sel]
  panelBox(R, C.PANEL)
  local axisW = math.max(22, textW("0000.0", 1) + 6)
  local cx0, cy0 = R.x + 2, R.y + 3
  local cw, ch = R.w - axisW - 4, R.h - 6
  local candleW = (cw >= 220) and 5 or ((cw >= 120) and 4 or 3)
  local n = math.min(#s.candles, math.floor(cw / candleW))
  local first = #s.candles - n + 1
  local lo, hi = math.huge, -math.huge
  for i = first, #s.candles do
    local c = s.candles[i]
    if c.l < lo then lo = c.l end
    if c.h > hi then hi = c.h end
  end
  local padP = (hi - lo) * 0.08 + hi * 0.002
  lo, hi = lo - padP, hi + padP
  local function Y(p) return math.floor(cy0 + (hi - p) / (hi - lo) * (ch - 1) + 0.5) end

  -- horizontal grid + price axis labels
  local nLines = (ch > 120) and 6 or 4
  for k = 0, nLines do
    local p = lo + (hi - lo) * k / nLines
    local y = Y(p)
    for x = cx0, cx0 + cw - 1, 3 do put(x, y, C.GRID2) end
    text(cx0 + cw + 3, y - 2, fmtPrice(p), 1, C.DIM)
  end
  -- vertical grid every 10 candles
  for i = first, #s.candles do
    if i % 10 == 0 then
      local x = cx0 + (i - first) * candleW + math.floor(candleW / 2)
      for y = cy0, cy0 + ch - 1, 3 do put(x, y, C.GRID) end
    end
  end

  -- trend glow: dithered area under the close line
  local trendUp = s.price >= s.candles[first].o
  local area = trendUp and C.AREAUP or C.AREADN
  local band = math.max(6, math.floor(ch * 0.35))
  for i = first, #s.candles do
    local c = s.candles[i]
    local x0 = cx0 + (i - first) * candleW
    local yc = Y(c.c)
    for y = yc, math.min(cy0 + ch - 1, yc + band) do
      local th = (1 - (y - yc) / band) * 9
      local br = BAYER[(y % 4) + 1]
      for x = x0, x0 + candleW - 1 do
        if br[(x % 4) + 1] < th then put(x, y, area) end
      end
    end
  end

  -- candles
  for i = first, #s.candles do
    local c = s.candles[i]
    local live = (i == #s.candles)
    local up = c.c >= c.o
    local fam = up and C.UP or C.DN
    local x0 = cx0 + (i - first) * candleW
    local mid = x0 + math.floor((candleW - 1) / 2)
    local yh, yl = Y(c.h), Y(c.l)
    local yo, yc = Y(c.o), Y(c.c)
    local top, bot = math.min(yo, yc), math.max(yo, yc)
    for y = yh, yl do put(mid, y, fam + 1) end
    local body = live and (up and C.LIVEUP or C.LIVEDN) or fam + 2
    for y = top, bot do
      for x = x0, x0 + candleW - 2 do
        local edge = (x == x0 or x == x0 + candleW - 2 or y == top or y == bot)
        put(x, y, (edge or live) and body or fam + 1)
      end
    end
  end

  -- 10-candle moving average
  local prevY
  for i = first, #s.candles do
    local sum, k = 0, 0
    for j = math.max(1, i - 9), i do sum = sum + s.candles[j].c k = k + 1 end
    local y = Y(sum / k)
    local x = cx0 + (i - first) * candleW + math.floor((candleW - 1) / 2)
    if prevY then
      for yy = math.min(prevY, y), math.max(prevY, y) do put(x, yy, C.MA) end
    end
    put(x, y, C.MA)
    if candleW > 3 then put(x + 1, y, C.MA) end
    prevY = y
  end

  -- live price line + tag
  local py = Y(s.price)
  local up = s.price >= s.candles[#s.candles].o
  local col = up and C.LIVEUP or C.LIVEDN
  for x = cx0, cx0 + cw - 1 do if x % 4 < 2 then put(x, py, col) end end
  local tag = fmtPrice(s.price)
  local tw = textW(tag, 1) + 4
  rect(cx0 + cw, py - 4, tw, 9, col)
  text(cx0 + cw + 2, py - 2, tag, 1, C.OUTLINE)

  -- legend
  text(cx0 + 2, cy0 + 1, "MA10", 1, C.MA)
  text(cx0 + 22, cy0 + 1, "1S CANDLES", 1, C.DIM)
  push(R.x, R.y, R.w, R.h)
end

local function drawList()
  local L = G.list
  panelBox(L, C.PANEL)
  for i, s in ipairs(STOCKS) do
    local r = G.rows[i]
    local chg = (s.price / openPrice(s) - 1) * 100
    local up = chg >= 0
    if i == G.sel then
      rect(r.x, r.y, r.w, r.h, C.PANEL2)
      frame(r.x, r.y, r.w, r.h, C.CYAN)
    end
    local th = math.min(r.h - 2, 13)
    local ty = r.y + math.floor((r.h - th) / 2)
    local third = math.floor(r.w / 3)
    textIn(r.x + 2, ty, third - 2, th, s.tk, (i == G.sel) and C.WHITE or C.TEXT, nil, 2, "l")
    -- sparkline of the last 20 closes
    local sx, sw = r.x + third, math.floor(third * 0.95)
    local n = math.min(20, #s.candles)
    local lo, hi = math.huge, -math.huge
    for j = #s.candles - n + 1, #s.candles do
      local c = s.candles[j].c
      if c < lo then lo = c end
      if c > hi then hi = c end
    end
    local sh = r.h - 4
    local prev
    for k = 0, sw - 1 do
      local j = #s.candles - n + 1 + math.floor(k / sw * n)
      local v = s.candles[j].c
      local y = r.y + 2 + math.floor((hi - v) / math.max(hi - lo, 1e-9) * (sh - 1))
      if prev then for yy = math.min(prev, y), math.max(prev, y) do put(sx + k, yy, up and C.UP + 2 or C.DN + 2) end end
      prev = y
    end
    local right = r.x + 2 * third
    textIn(right, r.y + 1, r.w - 2 * third - 2, math.floor(r.h / 2), fmtPrice(s.price), C.TEXT, nil, 2, "r")
    textIn(right, r.y + math.floor(r.h / 2), r.w - 2 * third - 2, r.h - math.floor(r.h / 2) - 1, pctStr(chg),
      up and C.UP + 2 or C.DN + 2, nil, 2, "r")
  end
  push(L.x, L.y, L.w, L.h)
end

local function holdings() return (G.acc and G.acc.holdings) or {} end
local function cash() return (G.acc and G.acc.cash) or 0 end
local function worth()
  local v = cash()
  for _, s in ipairs(STOCKS) do
    local h = holdings()[s.tk]
    if h then v = v + h.qty * s.price end
  end
  return v
end

local function drawPosition()
  local P, s = G.pos, STOCKS[G.sel]
  panelBox(P, C.PANEL)
  frame(P.x + 1, P.y + 1, P.w - 2, P.h - 2, C.FLASH)
  local h = holdings()[s.tk]
  local lh = math.floor((P.h - 4) / 3)
  local y = P.y + 2
  -- longest version of the summary line that fits
  local top
  for _, cand in ipairs({ G.acc.name .. "  CASH " .. short(cash()) .. "  NET " .. short(worth()),
    G.acc.name .. " " .. short(cash()) .. " / " .. short(worth()), "CASH " .. short(cash()) .. " NET " .. short(worth()),
    short(cash()) .. " / " .. short(worth()) }) do
    if textW(cand, 1) <= P.w - 8 then top = cand break end
  end
  textIn(P.x + 3, y, P.w - 6, lh, top or short(cash()), C.YELLOW, nil, 2, "l")
  y = y + lh
  if h and h.qty > 0 then
    local pnl = (s.price - h.avg) * h.qty
    local pct = (s.price / h.avg - 1) * 100
    textIn(P.x + 3, y, P.w - 6, lh, h.qty .. " " .. s.tk .. " @ " .. fmtPrice(h.avg), C.TEXT, nil, 2, "l")
    y = y + lh
    textIn(P.x + 3, y, P.w - 6, lh, "P/L " .. (pnl >= 0 and "+" or "") .. short(pnl) .. "  " .. pctStr(pct),
      (pnl >= 0) and C.LIVEUP or C.LIVEDN, C.OUTLINE, 3, "l")
  else
    textIn(P.x + 3, y, P.w - 6, lh, "NO " .. s.tk .. " POSITION", C.DIM, nil, 2, "l")
    y = y + lh
    textIn(P.x + 3, y, P.w - 6, lh, G.msg or "", C.DIM, nil, 2, "l")
  end
  push(P.x, P.y, P.w, P.h)
end

local function qtyFor(isBuy)
  local q = QTYS[G.qtyIdx]
  local s = STOCKS[G.sel]
  if q == "MAX" then
    if isBuy then return math.floor(cash() / s.price) end
    local h = holdings()[s.tk]
    return h and h.qty or 0
  end
  return q
end

local BTNFAM = { buy = "BUY", sell = "SELL", qty = "QTY", top = "TOPB", deposit = "BUY", withdraw = "QTY" }
local function drawButton(b, sc)
  local fam = C[BTNFAM[b.id]]
  if b.id == "top" and G.view == "board" then fam = C.QTY end
  for yy = b.y, b.y + b.h - 1 do
    for xx = b.x, b.x + b.w - 1 do
      local e = math.min(xx - b.x, b.x + b.w - 1 - xx, yy - b.y, b.y + b.h - 1 - yy)
      local c
      if e < 1 then c = fam + 2
      elseif e < 2 then c = C.OUTLINE
      else c = (yy - b.y < b.h * 0.45) and fam + 1 or fam end
      put(xx, yy, c)
    end
  end
  local label
  if b.id == "qty" then
    local q = QTYS[G.qtyIdx]
    label = (q == "MAX") and "MAX" or ("X" .. q)
  elseif b.id == "top" then label = (G.view == "board") and "CHART" or "TOP"
  elseif b.id == "deposit" then label = "DEPOSIT 100"
  elseif b.id == "withdraw" then label = "WITHDRAW 100"
  else label = (b.id == "buy") and "BUY" or "SELL" end
  textIn(b.x + 2, b.y + 2, b.w - 4, b.h - 4, label, C.WHITE, C.OUTLINE, sc or 4)
end

local function drawButtons()
  local b1 = G.buttons[1]
  local sc = math.min(fitScale("CHART", b1.w - 4, b1.h - 4, 4), fitScale("X100", b1.w - 4, b1.h - 4, 4))
  for _, b in ipairs(G.buttons) do drawButton(b, sc) end
  local B = G.btnRow
  push(B.x, B.y, B.w, B.h)
end

local function localCredits()
  if not fs.exists(CREDITS_FILE) then return 500 end
  local f = fs.open(CREDITS_FILE, "r")
  local v = tonumber(f.readLine()) or 500
  f.close()
  return v
end
local function setLocalCredits(v)
  local f = fs.open(CREDITS_FILE, "w")
  f.write(tostring(math.floor(v)))
  f.close()
end

local function drawBoard()
  local R = G.chart
  panelBox(R, C.PANEL)
  local titleH = math.max(10, math.floor(R.h * 0.12))
  textIn(R.x + 3, R.y + 2, R.w - 6, titleH, "TOP TRADERS", C.YELLOW, C.OUTLINE, 3)
  local bankTop = G.bankButtons[1].y
  local infoH = math.max(8, math.floor(R.h * 0.08))
  local listTop, listBot = R.y + titleH + 4, bankTop - infoH - 4
  local rows = G.board
  local n = math.max(1, math.min(#rows, 10))
  local rh = math.max(7, math.min(math.floor((listBot - listTop) / n), math.floor(R.h * 0.1)))
  for i = 1, math.min(#rows, math.floor((listBot - listTop) / rh)) do
    local r = rows[i]
    local y = listTop + (i - 1) * rh
    local me = G.acc and r.name == G.acc.name
    if me then rect(R.x + 2, y, R.w - 4, rh - 1, C.ME) end
    local col = (i == 1) and C.YELLOW or ((i <= 3) and C.MA or C.TEXT)
    textIn(R.x + 4, y, math.floor(R.w * 0.6), rh - 1, "#" .. i .. " " .. r.name, col, nil, 3, "l")
    textIn(R.x + math.floor(R.w * 0.6), y, math.floor(R.w * 0.4) - 6, rh - 1, short(r.worth),
      (r.worth >= 1000) and C.UP + 2 or C.DN + 2, nil, 3, "r")
  end
  if #rows == 0 then textIn(R.x + 3, listTop, R.w - 6, rh, "LOADING...", C.DIM, nil, 2) end
  textIn(R.x + 3, bankTop - infoH - 2, R.w - 6, infoH, "CASINO CREDITS ON THIS COMPUTER: " .. short(localCredits()), C.DIM, nil, 2)
  local sc = math.min(fitScale("WITHDRAW 100", G.bankButtons[2].w - 4, G.bankButtons[2].h - 4, 3), 3)
  for _, b in ipairs(G.bankButtons) do drawButton(b, sc) end
  push(R.x, R.y, R.w, R.h)
end

-- The tape text is rendered once into an off-screen strip (rebuilt once a second, or when news
-- breaks); each frame just copies a sliding window of it. Far cheaper than redrawing letters.
local function buildStrip(parts, sc, h, pad)
  local w = pad
  for _, p in ipairs(parts) do w = w + textW(p[1], sc) + sc end
  local rows = {}
  for j = 1, h do local r = {} for i = 1, w do r[i] = C.OUTLINE end rows[j] = r end
  local x = pad
  local ty = math.floor((h - 5 * sc) / 2)
  for _, p in ipairs(parts) do
    local s = p[1]:upper()
    for ci = 1, #s do
      local g = lib.font[s:sub(ci, ci)] or lib.font[" "]
      for gy = 1, 5 do
        for gx = 1, 3 do
          if g[gy]:sub(gx, gx) == "#" then
            for yy = 0, sc - 1 do
              local r = rows[ty + (gy - 1) * sc + yy + 1]
              for xx = 0, sc - 1 do r[x + (ci - 1) * 4 * sc + (gx - 1) * sc + xx + 1] = p[2] end
            end
          end
        end
      end
    end
    x = x + textW(s, sc) + sc
  end
  return { w = w, rows = rows }
end

local FEEDCOL = { good = "NEWS", bad = "NEWS", buy = "CYAN", win = "LIVEUP", loss = "LIVEDN", join = "YELLOW", trade = "TEXT" }

local function rebuildTape()
  local T = G.tape
  local sc = (T.h >= 15) and 2 or 1
  local h = T.h - 1
  if G.news then
    G.strip = buildStrip({ { G.news.text, C[FEEDCOL[G.news.kind] or "TEXT"] } }, sc, h, T.w)
  else
    local parts = {}
    for _, s in ipairs(STOCKS) do
      local chg = (s.price / openPrice(s) - 1) * 100
      parts[#parts + 1] = { s.tk .. " " .. fmtPrice(s.price) .. " ", C.TEXT }
      parts[#parts + 1] = { pctStr(chg) .. "    ", chg >= 0 and C.UP + 2 or C.DN + 2 }
    end
    G.strip = buildStrip(parts, sc, h, 0)
  end
end

local function drawTape()
  local T = G.tape
  if G.news and now() >= G.news.untilT then G.news = nil G.strip = nil end
  if not G.news and #G.feedQ > 0 then
    local item = table.remove(G.feedQ, 1)
    local news = (item.kind == "good" or item.kind == "bad")
    G.news = { text = item.text, kind = item.kind, good = item.kind ~= "bad", untilT = now() + (news and 7 or 4.5) }
    G.tapeX = 0
    G.strip = nil
  end
  if not G.strip then rebuildTape() end
  local st = G.strip
  rect(T.x, T.y, T.w, 1, C.GLOW)
  local off = G.tapeX % st.w
  for j = 1, T.h - 1 do
    local dst, src = fb[T.y + j + 1], st.rows[j]
    for x = 1, T.w do dst[x] = src[((off + x - 1) % st.w) + 1] end
  end
  push(T.x, T.y, T.w, T.h)
end

---------------------------------------------------------------- coins (big profits)
G.CS = math.max(4, math.floor(math.min(PW, PH) / 26))
G.coinSprites = {}
for k, fw in ipairs({ 1, 0.66, 0.22, 0.66 }) do
  local spr, r, cs = {}, G.CS / 2, G.CS
  for j = 1, cs do
    local row = {}
    for q = 1, cs do
      local a, b = (q - 0.5 - r) / (r * fw), (j - 0.5 - r) / r
      local d = a * a + b * b
      if d <= 1 then
        if fw < 0.4 or d > 0.62 then row[q] = C.GOLD + 1
        elseif (a + 0.35) ^ 2 + (b + 0.35) ^ 2 < 0.06 then row[q] = C.WHITE
        else row[q] = C.GOLD + ((a + b < 0) and 3 or 2) end
      else row[q] = false end
    end
    spr[j] = row
  end
  G.coinSprites[k] = spr
end
local function updateCoins(tm)
  local coins, CS = G.coins, G.CS
  if #coins == 0 and tm > G.showerUntil then return end
  for _, cn in ipairs(coins) do if cn.px then push(cn.px, cn.py, CS, CS) end end
  if tm < G.showerUntil and #coins < 40 then
    coins[#coins + 1] = { x = math.random(0, PW - CS), y = -CS, vx = (math.random() - 0.5) * 1.5,
      vy = math.random() * 2, f = math.random(0, 3) }
  end
  for k = #coins, 1, -1 do
    local cn = coins[k]
    cn.vy = cn.vy + PH * 0.004
    cn.x, cn.y, cn.f = cn.x + cn.vx, cn.y + cn.vy, cn.f + 1
    if cn.y > PH then table.remove(coins, k) end
  end
  for _, cn in ipairs(coins) do
    local x, y = math.floor(cn.x), math.floor(cn.y)
    cn.px, cn.py = x, y
    local spr = G.coinSprites[(cn.f % 4) + 1]
    local xa, xb = math.max(0, x), math.min(PW - 1, x + CS - 1)
    local rows, firstY = {}, nil
    if xa <= xb then
      for j = 1, CS do
        local yy = y + j - 1
        if yy >= 0 and yy < PH then
          firstY = firstY or yy
          local src, row, tmp = spr[j], fb[yy + 1], {}
          for xx = xa, xb do tmp[#tmp + 1] = src[xx - x + 1] or row[xx + 1] end
          rows[#rows + 1] = string.char(table.unpack(tmp))
        end
      end
      if firstY then t.drawPixels(xa, firstY, rows) end
    end
  end
end

---------------------------------------------------------------- palette animation
local function updatePalettes(tm)
  local p = 0.5 + 0.5 * math.sin(tm * 5)
  setPal(C.LIVEUP, mix(0x20e080, 0xb0ffd8, p))
  setPal(C.LIVEDN, mix(0xff3b5c, 0xffb0c0, p))
  setPal(C.GLOW, mix(0x123a5a, 0x2aa0d0, 0.5 + 0.5 * math.sin(tm * 1.6)))
  if G.news then
    setPal(C.NEWS, (math.floor(tm * 4) % 2 == 0) and (G.news.good and 0x60ff90 or 0xff5070) or 0xffe040)
  end
  local f = clamp(1 - (tm - G.flashT) / 0.8, 0, 1)
  setPal(C.FLASH, mix(0x0b1030, (G.flashKind == "up") and 0x40ff90 or 0xff4060, f))
end

---------------------------------------------------------------- networking
local function redrawAll()
  if G.view == "board" then drawBoard() else drawChart() end
  drawHeader() drawList() drawPosition() drawButtons()
end

local function flash(kind) G.flashT, G.flashKind = now(), kind end

local function onTick(m)
  G.lastTick = now()
  for _, s in ipairs(STOCKS) do
    local q = m.q[s.tk]
    if q then
      if q.n and s.n and (q.n < s.n or q.n > s.n + 1) then
        send({ type = "history", tk = s.tk })       -- server restarted or we missed candles: resync
      elseif q.n and s.n and q.n == s.n + 1 then
        s.cur = { o = q.o, h = q.h, l = q.l, c = q.c }
        s.candles[#s.candles + 1] = s.cur
        if #s.candles > 120 then table.remove(s.candles, 1) end
        s.n = q.n
      else
        s.cur.o, s.cur.h, s.cur.l, s.cur.c = q.o, q.h, q.l, q.c
      end
      s.price = q.p
    end
  end
end

local function onAccount(m)
  G.acc = m.account
  G.pending = nil
  local tr = m.trade
  if tr then
    if tr.side == "buy" then
      G.msg = "BOUGHT " .. tr.qty .. " " .. tr.tk
      flash("up")
      beep("minecraft:block.note_block.pling", 1.4)
    elseif tr.side == "sell" then
      G.msg = "SOLD " .. tr.qty .. " " .. tr.tk .. " " .. ((tr.pnl >= 0) and "+" or "") .. short(tr.pnl)
      flash(tr.pnl >= 0 and "up" or "down")
      if tr.pnl >= 200 then
        G.showerUntil = now() + 2.5
        beep("minecraft:ui.toast.challenge_complete", 1, 3)
      else
        beep(tr.pnl >= 0 and "minecraft:entity.experience_orb.pickup" or "minecraft:block.note_block.bass", 1)
      end
    elseif tr.side == "deposit" then
      setLocalCredits(localCredits() - tr.amount)
      G.msg = "DEPOSITED " .. tr.amount
      flash("up")
      beep("minecraft:block.chain.place", 1.2)
    elseif tr.side == "withdraw" then
      setLocalCredits(localCredits() + tr.amount)
      G.msg = "WITHDREW " .. tr.amount
      flash("up")
      beep("minecraft:block.chain.place", 0.9)
    end
  end
  drawPosition()
  drawButtons()
  if G.view == "board" then drawBoard() end
end

local function handle(m)
  if type(m) ~= "table" then return end
  if m.type == "tick" then onTick(m)
  elseif m.type == "account" then onAccount(m)
  elseif m.type == "login_ok" then G.acc = m.account
  elseif m.type == "feed" then
    if #G.feedQ < 8 then G.feedQ[#G.feedQ + 1] = { text = m.text, kind = m.kind } end
    if m.kind == "good" or m.kind == "bad" then
      beep(m.kind == "good" and "minecraft:block.note_block.chime" or "minecraft:block.note_block.didgeridoo", 1.2)
    end
  elseif m.type == "board" then
    G.board = m.rows
    if G.view == "board" then drawBoard() end
  elseif m.type == "history" then
    for _, s in ipairs(STOCKS) do
      if s.tk == m.tk then s.candles, s.n, s.price = m.candles, m.n, m.price s.cur = s.candles[#s.candles] end
    end
  elseif m.type == "err" then
    G.pending = nil
    G.msg = m.msg
    flash("down")
    beep("minecraft:entity.villager.no", 1)
    if m.msg == "NOT LOGGED IN" then send({ type = "login", name = G.login.name, pin = G.login.pin }) end
    drawPosition()
  end
end

---------------------------------------------------------------- actions
local function order(side)
  if G.pending and now() - G.pending < 1.5 then return end
  local s = STOCKS[G.sel]
  local q = qtyFor(side == "buy")
  if q <= 0 then
    G.msg = (side == "buy") and "NOT ENOUGH CASH" or "NOTHING TO SELL"
    flash("down")
    beep("minecraft:entity.villager.no", 1)
    drawPosition()
    return
  end
  G.pending = now()
  G.msg = "SENDING ORDER..."
  send({ type = side, tk = s.tk, qty = q })
  drawPosition()
end

local function bank(kind)
  if G.pending and now() - G.pending < 1.5 then return end
  if kind == "deposit" and localCredits() < 100 then
    G.msg = "NEED 100 CASINO CREDITS" flash("down") drawPosition() return
  end
  G.pending = now()
  send({ type = kind, amount = 100 })
end

local function selectStock(i)
  if i == G.sel then return end
  G.sel = i
  beep("minecraft:block.stone_button.click_on", 1.6)
  redrawAll()
end

local function toggleBoard()
  G.view = (G.view == "board") and "chart" or "board"
  if G.view == "board" then send({ type = "board" }) G.boardAsk = now() end
  beep("minecraft:block.stone_button.click_on", 1.2)
  redrawAll()
end

local function hit(px, py)
  for i, r in ipairs(G.rows) do
    if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then return "stock", i end
  end
  local list = G.buttons
  for _, b in ipairs(list) do
    if px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h then return b.id end
  end
  if G.view == "board" then
    for _, b in ipairs(G.bankButtons) do
      if px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h then return b.id end
    end
  end
end
local function press(kind, i)
  if kind == "stock" then selectStock(i)
  elseif kind == "buy" or kind == "sell" then order(kind)
  elseif kind == "qty" then
    G.qtyIdx = (G.qtyIdx % #QTYS) + 1
    beep("minecraft:block.stone_button.click_on", 1.2)
    drawButtons()
  elseif kind == "top" then toggleBoard()
  elseif kind == "deposit" or kind == "withdraw" then if G.view == "board" then bank(kind) end end
end

---------------------------------------------------------------- run
computeLayout()
if CC_SIM then CC_SIM.stocks = { rows = G.rows, buttons = G.buttons, bank = G.bankButtons } end -- test hook
G.msg = G.isMon and "TAP A STOCK, THEN BUY" or "CLICK OR B/S/X/T + ARROWS"
drawBackground()
redrawAll()
drawTape()
push(0, 0, PW, PH)

local monName = G.isMon and peripheral.getName(t) or nil
local ok, err = pcall(function()
  local timer = os.startTimer(0.05)
  local n = 0
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      local tm = now()
      n = n + 1
      freeze(true)
      updatePalettes(tm)
      G.tapeX = G.tapeX + ((G.tape.h >= 15) and 2 or 1)
      if n % 20 == 0 and not G.news then G.strip = nil end
      drawTape()
      if n % 4 == 0 then
        if G.view == "board" then
          if tm - (G.boardAsk or 0) > 2 then send({ type = "board" }) G.boardAsk = tm end
        else drawChart() end
        drawHeader()
      end
      if n % 5 == 0 then drawPosition() end
      if n % 10 == 0 then drawList() end
      if offline() and tm - (G.retryT or 0) > 5 then
        G.retryT = tm
        send({ type = "login", name = G.login.name, pin = G.login.pin })
      end
      updateCoins(tm)
      freeze(false)
      timer = os.startTimer(0.05)
    elseif e == "rednet_message" and a == G.server and c == PROTO then
      freeze(true)
      handle(b)
      freeze(false)
    elseif e == "monitor_touch" and a == monName then
      press(hit((b - 1) * 6 + 3, (c - 1) * 9 + 4))
    elseif e == "mouse_click" and not G.isMon then
      press(hit(b, c))
    elseif e == "key" then
      if a == keys.q then break
      elseif a == keys.up then selectStock((G.sel - 2) % #STOCKS + 1)
      elseif a == keys.down then selectStock(G.sel % #STOCKS + 1)
      elseif a == keys.b then press("buy")
      elseif a == keys.s then press("sell")
      elseif a == keys.x then press("qty")
      elseif a == keys.t then press("top")
      elseif a == keys.d then press("deposit")
      elseif a == keys.w then press("withdraw") end
    end
  end
end)

pcall(t.setGraphicsMode, 0)
lib.resetPalette(t)
t.setBackgroundColor(colors.black)
t.setTextColor(colors.white)
t.clear()
t.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("logged off. your account stays on the exchange.")
