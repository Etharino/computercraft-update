-- crash.lua :: server-wide CRASH, played in chat. one computer runs it; everyone bets from chat.
--   a pixel rocket climbs a glowing curve while the multiplier rises. cash out before it explodes.
--   each round: 10s of betting, then liftoff, then (eventually) CRASH. 3% house edge.
--
-- needs: a chat box (Advanced Peripherals). best with an advanced monitor + CC: Graphics for the
--        big screen (falls back to the computer's own screen).  optional: speaker.
-- chat commands (use $ instead of ! to keep your message hidden):
--   !bet 100        bet 100 on the next round        !bet 100 2.5   ...auto cash out at 2.5x
--   !bet all        bet everything                   !cashout (!co) cash out right now
--   !bal            your balance                     !top           richest players
--   !daily          free 500 credits every 20 hours  !crash         how to play
-- wallets are saved in crash.db (new players start with 1000).

local lib = require("auralib")
math.randomseed(os.epoch("utc"))
lib.font["@"] = { ".#.", "#.#", "###", "#..", ".##" }

local CFG = {
  bettingTime = 10,     -- seconds to place bets
  pauseTime = 4,        -- seconds showing the explosion
  growth = 0.075,       -- multiplier = e^(growth * seconds): 2x ~9s, 10x ~31s
  startBalance = 1000,
  daily = 500,
  dailyHours = 20,
  maxBet = 100000,
  prefix = "&c&lCRASH",
  saveFile = "crash.db",
}

-- all state in G, palette in C (CC's Lua caps upvalues at 60 / locals at 200)
local G = { state = "betting", bets = {}, order = {}, history = {}, wallets = {}, outbox = {}, cashLines = {},
  particles = {}, roundsSinceBets = 0, round = 0 }
local C = {}

---------------------------------------------------------------- peripherals + screen
G.chat = lib.findAny("chatBox", "chat_box")
G.speaker = peripheral.find("speaker")
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
local function now() return os.epoch("utc") / 1000 end
local function beep(sound, pitch, vol) if G.speaker then pcall(G.speaker.playSound, sound, vol or 2, pitch or 1) end end

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
G.BGCOLS  = ramp({ 0x05030f, 0x0d0826, 0x1a0c38 }, 16)
C.BG      = family(G.BGCOLS)
C.STAR    = family({ 0xffffff, 0x9a8ac8 })
C.PANEL   = family({ 0x100a2a })
C.PANEL2  = family({ 0x1a1240 })
C.GRID    = family({ 0x2a2058 })
C.BORDER  = family({ 0x5a3ab0 })
C.TEXT    = family({ 0xf0eaff })
C.DIM     = family({ 0x8a80b8 })
C.OUTLINE = family({ 0x04020c })
C.CURVE   = family(ramp({ 0x30f080, 0xf0e040, 0xff8a20, 0xff3a8a, 0xc060ff }, 8))
C.AREA    = family(ramp({ 0x0c3a28, 0x3a3410, 0x3a1c08, 0x3a0c22, 0x2a1240 }, 8))
C.ROCKET  = family({ 0x5a6078, 0xb8c0d8, 0xffffff })    -- body shades
C.NOSE    = family({ 0x9a1420, 0xff3a48 })
C.WINDOW  = family({ 0x30d0ff })
C.FLAME   = family({ 0xff4a10, 0xffa020, 0xfff080 })
C.BIG     = family({ 0xffffff })                       -- animated multiplier colour
C.RED     = family({ 0x8a1020, 0xff3048, 0xff90a0 })
C.GREEN   = family({ 0x0e6a30, 0x30e070, 0xa0ffc0 })
C.GOLD    = family({ 0x8a5a08, 0xffc830, 0xfff0a0 })
C.FLASH   = family({ 0x05030f })

---------------------------------------------------------------- framebuffer + drawing helpers
local fb = {}
for y = 1, PH do local r = {} for x = 1, PW do r[x] = C.BG end fb[y] = r end
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
local function textW(s, sc) return (#s * 4 - 1) * sc end
local function text(x, y, s, sc, col, outline, grow)
  s = s:upper()
  local passes = outline and { { outline, grow or 1 }, { col, 0 } } or { { col, 0 } }
  for _, pass in ipairs(passes) do
    local color, gr = pass[1], pass[2]
    for ci = 1, #s do
      local g = lib.font[s:sub(ci, ci)] or lib.font[" "]
      for gy = 1, 5 do
        local row = g[gy]
        for gx = 1, 3 do
          if row:sub(gx, gx) == "#" then
            local px, py = x + (ci - 1) * 4 * sc + (gx - 1) * sc, y + (gy - 1) * sc
            for yy = py - gr, py + sc - 1 + gr do
              for xx = px - gr, px + sc - 1 + gr do put(xx, yy, color) end
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
local function textIn(x, y, w, h, s, col, outline, maxSc, align)
  local sc = fitScale(s, w, h, maxSc)
  local tw = textW(s, sc)
  local tx = x + math.floor((w - tw) / 2)
  if align == "l" then tx = x + 1 elseif align == "r" then tx = x + w - tw - 1 end
  text(tx, y + math.floor((h - 5 * sc) / 2), s, sc, col, outline, math.max(1, math.floor(sc / 3)))
  return sc
end
local function fmtX(m) return string.format("%.2fX", m) end
local function short(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return math.floor(n / 1000) .. "K" end
  return tostring(math.floor(n))
end

---------------------------------------------------------------- wallets
local function save()
  local f = fs.open(CFG.saveFile, "w")
  f.write(textutils.serialize({ wallets = G.wallets, history = G.history }))
  f.close()
end
local function load()
  if not fs.exists(CFG.saveFile) then return end
  local f = fs.open(CFG.saveFile, "r")
  local d = textutils.unserialize(f.readAll())
  f.close()
  if type(d) == "table" then
    if type(d.wallets) == "table" then G.wallets = d.wallets end
    if type(d.history) == "table" then G.history = d.history end
  end
end
local function wallet(name)
  local w = G.wallets[name]
  if not w then
    w = { bal = CFG.startBalance, lastDaily = 0, best = 0 }
    G.wallets[name] = w
  end
  return w
end

---------------------------------------------------------------- chat (handles both AP chat box API styles)
local function say(text_, target, color)
  G.outbox[#G.outbox + 1] = { text = text_, target = target, color = color or "yellow" }
end
local function trySend(item)
  local chat = G.chat
  if not chat then return true end
  local json = textutils.serializeJSON({ { text = "" }, { text = item.text, color = item.color } })
  local P, BR, BC = CFG.prefix, "[]", "&4"
  local order = (G.chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res, err = pcall(function()
      local o = { prefix = P, brackets = BR, bracketColor = BC }
      if item.target then
        if style == "new" then return chat.sendFormattedMessageToPlayer(json, item.target, o) end
        return chat.sendFormattedMessageToPlayer(json, item.target, P, BR, BC)
      end
      if style == "new" then return chat.sendFormattedMessage(json, o) end
      return chat.sendFormattedMessage(json, P, BR, BC)
    end)
    if ok and res then G.chatStyle = style return true end
    if ok and tostring(err):lower():find("cool") then return false end
  end
  if item.target then pcall(chat.sendMessageToPlayer, item.text, item.target, P)
  else pcall(chat.sendMessage, item.text, P) end
  return true
end
local function pumpChat(tm)
  -- batch cash-out shouts so a crowd cashing out doesn't hit the chat box cooldown
  if #G.cashLines > 0 and tm - (G.lastCashFlush or 0) > 1.2 then
    say(table.concat(G.cashLines, "  |  "), nil, "green")
    G.cashLines = {}
    G.lastCashFlush = tm
  end
  if #G.outbox > 0 and tm - (G.lastSend or 0) >= 1.1 then
    G.lastSend = tm
    local item = G.outbox[1]
    if trySend(item) then table.remove(G.outbox, 1)
    else
      item.tries = (item.tries or 0) + 1
      if item.tries > 6 then table.remove(G.outbox, 1) end
    end
  end
end

---------------------------------------------------------------- game logic
local function rollCrash()
  if CC_SIM and CC_SIM.crashAt and #CC_SIM.crashAt > 0 then return table.remove(CC_SIM.crashAt, 1) end
  local c = 0.97 / (1 - math.random())       -- P(crash >= x) = 0.97 / x  -> 3% house edge
  if c < 1 then c = 1 end
  return math.floor(c * 100) / 100
end

local function multAt(tm) return math.exp(CFG.growth * (tm - G.startT)) end

local function startBetting(tm)
  G.state = "betting"
  G.justChanged = true
  G.bets, G.order = {}, {}
  G.endT = tm + CFG.bettingTime
  G.round = G.round + 1
  G.particles = {}
  -- don't spam chat with "new round" when nobody is playing
  if G.roundsSinceBets < 2 or G.round % 6 == 1 then
    say("NEW ROUND! type !bet <amount> in the next " .. CFG.bettingTime .. "s  (!crash for help)", nil, "aqua")
  end
end

local function cashOut(name, m, auto)
  local b = G.bets[name]
  if not b or b.cashed then return end
  m = math.floor(m * 100) / 100
  b.cashed = m
  local win = math.floor(b.amt * m)
  local w = wallet(name)
  w.bal = w.bal + win
  if m > (w.best or 0) then w.best = m end
  G.cashLines[#G.cashLines + 1] = name .. " cashed out @ " .. string.format("%.2fx", m) .. " (+" .. (win - b.amt) .. ")"
    .. (auto and " [auto]" or "")
  G.dirty = true
  beep("minecraft:entity.experience_orb.pickup", 1 + math.min(1, m / 10))
end

local function liftoff(tm)
  G.state = "running"
  G.justChanged = true
  G.startT = tm
  G.crashAt = rollCrash()
  G.mult = 1
  local n, pot = 0, 0
  for _, name in ipairs(G.order) do n = n + 1 pot = pot + G.bets[name].amt end
  if n > 0 then
    G.roundsSinceBets = 0
    say("LIFTOFF! " .. n .. " player" .. (n == 1 and "" or "s") .. ", " .. pot .. " credits riding. type !cashout to bail", nil, "gold")
  else
    G.roundsSinceBets = G.roundsSinceBets + 1
  end
  beep("minecraft:entity.firework_rocket.launch", 0.8, 3)
end

local function explode(tm)
  G.state = "crashed"
  G.justChanged = true
  G.mult = G.crashAt
  G.endT = tm + CFG.pauseTime
  table.insert(G.history, 1, G.crashAt)
  if #G.history > 14 then table.remove(G.history) end
  local losers, lost = {}, 0
  for _, name in ipairs(G.order) do
    local b = G.bets[name]
    if not b.cashed then losers[#losers + 1] = name .. " (-" .. b.amt .. ")" lost = lost + b.amt end
  end
  G.flashT = tm
  -- particles for the explosion, from the rocket's last position
  local px, py = G.rocketX or PW / 2, G.rocketY or PH / 2
  for k = 1, 46 do
    local a = math.random() * math.pi * 2
    local sp = (0.6 + math.random() * 3.2) * math.max(1, math.min(PW, PH) / 200)
    G.particles[k] = { x = px, y = py, vx = math.cos(a) * sp, vy = math.sin(a) * sp - 0.8, life = 18 + math.random(0, 16) }
  end
  -- flush pending cash-outs first so chat reads in order
  if #G.cashLines > 0 then say(table.concat(G.cashLines, "  |  "), nil, "green") G.cashLines = {} end
  local msg = "CRASHED @ " .. string.format("%.2fx", G.crashAt) .. "!"
  if #losers > 0 then msg = msg .. "  busted: " .. table.concat(losers, ", ") end
  if #G.order > 0 or G.crashAt >= 10 then say(msg, nil, "red") end
  beep("minecraft:entity.generic.explode", 1, 3)
  G.dirty = true
end

---------------------------------------------------------------- chat commands
local function placeBet(name, args)
  if G.state ~= "betting" then say("betting is closed - wait for the next round", name, "gray") return end
  local w = wallet(name)
  local amtStr, autoStr = args:match("^(%S+)%s*(%S*)")
  if not amtStr then say("usage: !bet <amount> [auto cash-out, e.g. 2.5]", name, "gray") return end
  local amt = (amtStr:lower() == "all") and w.bal or math.floor(tonumber(amtStr) or 0)
  if amt <= 0 then say("bet must be a positive number", name, "gray") return end
  if amt > CFG.maxBet then amt = CFG.maxBet end
  local prev = G.bets[name]
  local have = w.bal + (prev and prev.amt or 0)
  if amt > have then say("you only have " .. have .. " credits (!daily for free ones)", name, "red") return end
  local autoClean = (autoStr or ""):lower():gsub("x$", "")
  local auto = tonumber(autoClean)
  if auto and auto < 1.01 then auto = nil end
  if prev then w.bal = w.bal + prev.amt else G.order[#G.order + 1] = name end
  w.bal = w.bal - amt
  G.bets[name] = { amt = amt, auto = auto }
  G.dirty = true
  say("bet " .. amt .. " placed" .. (auto and (" (auto cash-out @ " .. auto .. "x)") or "") .. ". balance " .. w.bal, name, "green")
  beep("minecraft:block.stone_button.click_on", 1.5)
end

local function onCommand(name, cmd, args)
  if cmd == "bet" or cmd == "b" then placeBet(name, args)
  elseif cmd == "cashout" or cmd == "co" or cmd == "c" or cmd == "cash" then
    if G.state ~= "running" then say("nothing to cash out right now", name, "gray")
    elseif not G.bets[name] then say("you're not in this round", name, "gray")
    else cashOut(name, multAt(now()), false) end
  elseif cmd == "bal" or cmd == "balance" then
    local w = wallet(name)
    say(name .. ": " .. w.bal .. " credits (best cash-out " .. string.format("%.2fx", w.best or 0) .. ")", name, "aqua")
  elseif cmd == "top" then
    local rows = {}
    for n, w in pairs(G.wallets) do rows[#rows + 1] = { n, w.bal } end
    table.sort(rows, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for i = 1, math.min(5, #rows) do parts[#parts + 1] = "#" .. i .. " " .. rows[i][1] .. " " .. rows[i][2] end
    say("richest: " .. table.concat(parts, "  "), nil, "gold")
  elseif cmd == "daily" then
    local w = wallet(name)
    local last = w.lastDaily or 0
    local wait = CFG.dailyHours * 3600 - (now() - last)
    if last > 0 and wait > 0 then
      say("daily already claimed. come back in " .. math.ceil(wait / 3600) .. "h", name, "gray")
    else
      w.lastDaily = now()
      w.bal = w.bal + CFG.daily
      G.dirty = true
      say("+" .. CFG.daily .. " daily credits! balance " .. w.bal, name, "green")
    end
  elseif cmd == "crash" or cmd == "help" then
    say("CRASH: !bet <amt> [auto-x] during the countdown, then !cashout before the rocket explodes. "
      .. "!bal !top !daily. use $ instead of ! to hide your message.", name, "aqua")
  end
end

local function isUUID(s) return type(s) == "string" and s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil end
local function onChatEvent(a, b, c)
  -- new AP: uuid, username, message   old AP: username, message, uuid
  local user, msg
  if a == nil or isUUID(a) then user, msg = b, c else user, msg = a, b end
  if type(user) ~= "string" or type(msg) ~= "string" or user == "[say]" then return end
  local cmd, args = msg:match("^[!$](%a+)%s*(.-)%s*$")
  if cmd then onCommand(user, cmd:lower(), args or "") end
end

---------------------------------------------------------------- layout
local function computeLayout()
  local m = math.max(3, math.floor(math.min(PW, PH) * 0.02))
  G.m = m
  G.headH = math.max(14, math.floor(PH * 0.09))
  G.footH = math.max(9, math.floor(PH * 0.05))
  local top, bottom = G.headH + m, PH - G.footH - m
  if PW >= PH * 1.15 then
    local pw = math.floor(PW * 0.3)
    G.graph = { x = m, y = top, w = PW - pw - 3 * m, h = bottom - top }
    G.panel = { x = PW - pw - m, y = top, w = pw, h = bottom - top }
  else
    local ph = math.floor((bottom - top) * 0.3)
    G.graph = { x = m, y = top, w = PW - 2 * m, h = bottom - top - ph - m }
    G.panel = { x = m, y = bottom - ph, w = PW - 2 * m, h = ph }
  end
end

---------------------------------------------------------------- drawing
local function drawStarfield()
  for y = 0, PH - 1 do
    local c = C.BG + clamp(math.floor(y / PH * 16), 0, 15)
    local row = fb[y + 1]
    for x = 1, PW do row[x] = c end
  end
  for _ = 1, math.floor(PW * PH / 300) do put(math.random(0, PW - 1), math.random(0, PH - 1), C.STAR + math.random(0, 1)) end
  G.bg = {}
  for y = 1, PH do local r, s = {}, fb[y] for x = 1, PW do r[x] = s[x] end G.bg[y] = r end
end
-- copy the saved starfield back over a region. table.move does it natively when available.
local tmove = table.move
local function restoreBg(x, y, w, h)
  local a, b = math.max(0, x) + 1, math.min(PW - 1, x + w - 1) + 1
  if b < a then return end
  for yy = math.max(0, y), math.min(PH - 1, y + h - 1) do
    local d, s = fb[yy + 1], G.bg[yy + 1]
    if tmove then tmove(s, a, b, a, d)
    else for i = a, b do d[i] = s[i] end end
  end
end

local function pillColor(v) return (v >= 10) and C.GOLD or ((v >= 2) and C.GREEN or C.RED) end

local function drawHeader()
  restoreBg(0, 0, PW, G.headH + G.m)
  rect(0, 0, PW, G.headH, C.PANEL)
  rect(0, G.headH - 1, PW, 1, C.BORDER)
  local sc = math.max(1, math.floor((G.headH - 4) / 6))
  text(G.m, math.floor((G.headH - 5 * sc) / 2), "CRASH", sc, C.RED + 1, C.OUTLINE, 1)
  local x = G.m + textW("CRASH", sc) + 3 * G.m
  local psc = math.max(1, sc - 1)
  for _, v in ipairs(G.history) do
    local s = string.format("%.2f", v)
    local w = textW(s, psc) + 6
    if x + w > PW - G.m then break end
    local fam = pillColor(v)
    rect(x, 2, w, G.headH - 5, fam)
    rect(x + 1, 3, w - 2, G.headH - 7, fam + 1)
    text(x + 3, math.floor((G.headH - 1 - 5 * psc) / 2), s, psc, C.OUTLINE)
    x = x + w + 2
  end
  push(0, 0, PW, G.headH)
end

local function drawFooter()
  local y = PH - G.footH
  rect(0, y, PW, G.footH, C.PANEL)
  rect(0, y, PW, 1, C.BORDER)
  local s = G.chat and "!BET 100   !BET 100 2X   !CASHOUT   !BAL   !TOP   !DAILY" or "NO CHAT BOX ATTACHED - ATTACH ONE TO TAKE BETS"
  textIn(G.m, y + 1, PW - 2 * G.m, G.footH - 1, s, G.chat and C.DIM or C.RED + 1, nil, 2)
  push(0, y, PW, G.footH)
end

local function drawPanel()
  local P = G.panel
  rect(P.x, P.y, P.w, P.h, C.PANEL)
  frame(P.x, P.y, P.w, P.h, C.BORDER)
  local lh = math.max(8, math.min(14, math.floor(P.h / 9)))
  local hdr = (G.state == "betting") and "BETS" or "PLAYERS"
  local pot = 0
  for _, name in ipairs(G.order) do pot = pot + G.bets[name].amt end
  textIn(P.x + 3, P.y + 2, P.w - 6, lh, hdr .. " " .. #G.order .. "  POT " .. short(pot), C.TEXT, nil, 2, "l")
  local y = P.y + lh + 4
  local rowsPer = math.max(1, math.floor((P.y + P.h - y - 2) / lh))
  -- a second column only when the first one is full and the panel is wide enough
  local cols = (#G.order > rowsPer and P.w > P.h * 1.6 and P.w > 200) and 2 or 1
  local cw = math.floor((P.w - 6) / cols)
  -- one text size for every row: as big as the row height allows, small enough for the widest status
  local nwCol = math.floor(cw * 0.55) - 4
  G.rowSc = clamp(math.floor((lh - 2) / 5), 1, 2)
  while G.rowSc > 1 and textW("12.34X +99999", G.rowSc) > nwCol do G.rowSc = G.rowSc - 1 end
  for i, name in ipairs(G.order) do
    if i > rowsPer * cols then break end
    local col, row = math.floor((i - 1) / rowsPer), (i - 1) % rowsPer
    local x, yy = P.x + 3 + col * cw, y + row * lh
    local b = G.bets[name]
    local status, color
    if b.cashed then status, color = string.format("%.2fX +%d", b.cashed, math.floor(b.amt * b.cashed) - b.amt), C.GREEN + 1
    elseif G.state == "crashed" then status, color = "BUST -" .. b.amt, C.RED + 1
    elseif G.state == "running" then status, color = short(b.amt) .. (b.auto and (" @" .. b.auto .. "X") or ""), C.TEXT
    else status, color = short(b.amt) .. (b.auto and (" @" .. b.auto .. "X") or ""), C.DIM end
    local nw = math.floor(cw * 0.45)
    local sc = G.rowSc
    local nm = name
    while #nm > 1 and textW(nm, sc) > nw - 2 do nm = nm:sub(1, -2) end
    text(x + 1, yy + math.floor((lh - 5 * sc) / 2), nm, sc, C.TEXT)
    text(x + cw - 2 - textW(status, sc), yy + math.floor((lh - 5 * sc) / 2), status, sc, color)
  end
  if #G.order == 0 then
    textIn(P.x + 3, y, P.w - 6, lh, (G.state == "betting") and "TYPE !BET 100 IN CHAT" or "NOBODY ON BOARD", C.DIM, nil, 2)
  end
  push(P.x, P.y, P.w, P.h)
end

-- graph scaling
local function scales(tNow, m)
  local xmax = math.max(10, tNow * 1.25)
  local ymax = math.max(2, m * 1.25)
  return xmax, ymax
end

local BAYER = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }

-- rocket drawn in its own frame: u along its heading, v across
local function rocketPixel(u, v, L, flick)
  local half = L / 2
  if u > half * 0.35 then
    local w = (half - u) / (half * 0.65) * L * 0.2
    if math.abs(v) <= w then return (v < 0) and C.NOSE + 1 or C.NOSE end
  elseif u >= -half then
    if math.abs(v) <= L * 0.2 then
      if (u - half * 0.05) ^ 2 + v * v <= (L * 0.09) ^ 2 then return C.WINDOW end
      return (v < -L * 0.07) and C.ROCKET + 2 or ((v > L * 0.08) and C.ROCKET or C.ROCKET + 1)
    end
    if u < -half * 0.35 and math.abs(v) <= L * 0.2 + (-half * 0.35 - u) * 0.9 then return C.NOSE end
  end
  if u < -half and u > -half - L * (0.45 + flick * 0.25) then
    local f = (-half - u) / (L * 0.6)
    if math.abs(v) <= L * 0.16 * (1 - f) then return C.FLAME + ((f < 0.3) and 2 or ((f < 0.6) and 1 or 0)) end
  end
end

local function drawRocket(cx, cy, dirx, diry, L)
  local R = math.ceil(L * 1.2)
  local flick = math.random()
  for y = math.floor(cy - R), math.ceil(cy + R) do
    for x = math.floor(cx - R), math.ceil(cx + R) do
      local dx, dy = x - cx, y - cy
      local u = dx * dirx + dy * diry
      local v = -dx * diry + dy * dirx
      local c = rocketPixel(u, v, L, flick)
      if c then put(x, y, c) end
    end
  end
end

local function drawGraph(tm)
  local Gr = G.graph
  restoreBg(Gr.x, Gr.y, Gr.w, Gr.h)
  frame(Gr.x, Gr.y, Gr.w, Gr.h, C.BORDER)
  local x0, y0, w, h = Gr.x + 2, Gr.y + 2, Gr.w - 4, Gr.h - 4
  local tNow = 0
  if G.state == "running" then tNow = tm - G.startT
  elseif G.state == "crashed" then tNow = math.log(G.crashAt) / CFG.growth end
  local m = (G.state == "betting") and 1 or G.mult
  local xmax, ymax = scales(tNow, m)
  local function X(tt) return x0 + tt / xmax * (w - 1) end
  local function Y(mm) return y0 + h - 1 - (mm - 1) / (ymax - 1) * (h - 1) end

  -- grid lines at friendly multipliers
  local steps = { 1.5, 2, 3, 5, 10, 20, 50, 100, 200, 500, 1000 }
  local shown = 0
  for _, s in ipairs(steps) do
    if s < ymax and shown < 6 then
      local yy = math.floor(Y(s))
      if yy > y0 + 8 then
        for xx = x0, x0 + w - 1, 3 do put(xx, yy, C.GRID) end
        text(x0 + 2, yy - 6, string.format("%gX", s), 1, C.DIM)
        shown = shown + 1
      end
    end
  end

  if G.state ~= "betting" then
    -- glow under the curve, then the curve itself
    local lastX = math.floor(X(tNow))
    local colIdx = clamp(math.floor(math.log(m) / math.log(1.8)), 0, 7)
    local band = math.max(6, math.floor(h * 0.35))
    local areaC = C.AREA + colIdx
    for xx = x0, lastX do
      local tt = (xx - x0) / (w - 1) * xmax
      local yy = math.floor(Y(math.exp(CFG.growth * tt)))
      local bx = (xx % 4) + 1
      for py = yy, math.min(y0 + h - 1, yy + band) do
        if BAYER[(py % 4) + 1][bx] < (1 - (py - yy) / band) * 10 then fb[py + 1][xx + 1] = areaC end
      end
    end
    local th = math.max(1, math.floor(math.min(w, h) / 70))
    local prevY
    for xx = x0, lastX do
      local tt = (xx - x0) / (w - 1) * xmax
      local mm = math.exp(CFG.growth * tt)
      local yy = math.floor(Y(mm))
      local c = C.CURVE + clamp(math.floor(math.log(mm) / math.log(1.8)), 0, 7)
      local a, b = yy, prevY or yy
      for py = math.min(a, b) - th, math.max(a, b) + th do put(xx, py, c) end
      prevY = yy
    end
    -- rocket at the tip
    local tipX, tipY = X(tNow), Y(m)
    local dt = math.max(0.05, xmax / 200)
    local nx, ny = X(tNow + dt) - tipX, Y(m * math.exp(CFG.growth * dt)) - tipY
    local len = math.sqrt(nx * nx + ny * ny)
    nx, ny = nx / len, ny / len
    G.rocketX, G.rocketY = tipX, tipY
    if G.state == "running" then
      drawRocket(tipX, tipY, nx, ny, math.max(8, math.floor(math.min(w, h) * 0.1)))
    end
  end

  -- the big number in the middle
  local big, sub, col
  if G.state == "betting" then
    big = "STARTING IN " .. math.max(0, math.ceil(G.endT - tm))
    sub = "PLACE BETS IN CHAT: !BET 100"
    col = C.TEXT
  elseif G.state == "running" then
    big = fmtX(m)
    col = C.BIG
  else
    big = "CRASHED @ " .. fmtX(G.crashAt)
    col = C.RED + 1
  end
  -- the curve always ends top-right, so the text lives in the empty upper-left
  local bsc = fitScale(big, w * 0.62, h * 0.2, 9)
  local bx = x0 + math.floor(w * 0.04)
  local by = y0 + math.floor(h * 0.2)
  text(bx, by, big, bsc, col, C.OUTLINE, math.max(1, math.floor(bsc / 3)))
  if sub then
    local ssc = fitScale(sub, w * 0.8, h * 0.08, 3)
    text(bx, by + 5 * bsc + 2 * ssc + 2, sub, ssc, C.DIM)
  end
  -- explosion particles
  for _, p in ipairs(G.particles) do
    if p.life > 0 then
      local c = (p.life > 20) and C.FLAME + 2 or ((p.life > 10) and C.FLAME + 1 or C.FLAME)
      local px, py = math.floor(p.x), math.floor(p.y)
      local ps = math.max(2, math.floor(math.min(w, h) / 70))
      if p.life > 24 then ps = ps + 1 end
      if px >= x0 and px < x0 + w - ps and py >= y0 and py < y0 + h - ps then
        for dy = 0, ps - 1 do for dx = 0, ps - 1 do put(px + dx, py + dy, c) end end
      end
    end
  end

  push(Gr.x, Gr.y, Gr.w, Gr.h)
end

local function updateParticles()
  for _, p in ipairs(G.particles) do
    if p.life > 0 then
      p.x, p.y = p.x + p.vx, p.y + p.vy
      p.vy = p.vy + 0.12
      p.vx = p.vx * 0.97
      p.life = p.life - 1
    end
  end
end

local function updatePalettes(tm)
  if G.state == "running" then
    local idx = clamp(math.floor(math.log(G.mult) / math.log(1.8)), 0, 7)
    local stops = ramp({ 0x30f080, 0xf0e040, 0xff8a20, 0xff3a8a, 0xc060ff }, 8)
    setPal(C.BIG, mix(stops[idx + 1], 0xffffff, 0.25 + 0.25 * math.sin(tm * 12)))
  end
  local f = clamp(1 - (tm - (G.flashT or -100)) / 0.5, 0, 1)
  for k = 0, 15 do setPal(C.BG + k, mix(G.BGCOLS[k + 1], 0x8a1020, f * 0.7)) end
end

---------------------------------------------------------------- run
load()
computeLayout()
drawStarfield()
startBetting(now())
drawHeader() drawFooter() drawPanel() drawGraph(now())
push(0, 0, PW, PH)
print("crash is running on " .. (G.isMon and "the monitor" or "this screen") .. (G.chat and "" or " (NO CHAT BOX)"))

local ok, err = pcall(function()
  local timer = os.startTimer(0.05)
  local n = 0
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      local tm = now()
      n = n + 1
      freeze(true)
      if G.state == "betting" then
        if tm >= G.endT then liftoff(tm) drawPanel() end
      elseif G.state == "running" then
        G.mult = multAt(tm)
        for _, name in ipairs(G.order) do
          local bt = G.bets[name]
          if bt.auto and not bt.cashed and G.mult >= bt.auto and bt.auto <= G.crashAt then cashOut(name, bt.auto, true) end
        end
        if G.mult >= G.crashAt then explode(tm) drawHeader() drawPanel() end
        if n % 10 == 0 and G.state == "running" then beep("minecraft:block.note_block.hat", 0.6 + math.min(1.4, G.mult / 8), 1) end
      elseif G.state == "crashed" then
        updateParticles()
        if tm >= G.endT then startBetting(tm) drawPanel() end
      end
      updatePalettes(tm)
      if n % ((G.state == "betting") and 4 or 2) == 0 or G.justChanged then drawGraph(tm) G.justChanged = nil end
      if n % 5 == 0 then drawPanel() end
      pumpChat(tm)
      if G.dirty and n % 40 == 0 then save() G.dirty = false end
      freeze(false)
      timer = os.startTimer(0.05)
    elseif e == "chat" then
      onChatEvent(a, b, c)
      drawPanel()
    elseif e == "key" and a == keys.q then
      break
    end
  end
end)

-- refund bets of a round that never finished
if G.state ~= "crashed" then
  for name, b in pairs(G.bets) do if not b.cashed then wallet(name).bal = wallet(name).bal + b.amt end end
end
save()
pcall(t.setGraphicsMode, 0)
lib.resetPalette(t)
t.setBackgroundColor(colors.black)
t.setTextColor(colors.white)
t.clear()
t.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("crash stopped. wallets saved.")
