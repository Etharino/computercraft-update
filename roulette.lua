-- roulette.lua :: pixel-art european roulette for CC: Graphics (256-colour graphics mode).
--   spinning wheel with numbered pockets, a ball that orbits, spirals in and bounces into a
--   pocket, a full betting board with chips, payouts, result history, and coin rain on big wins.
--
-- works on an advanced computer or any advanced monitor (3x4, 4x3, ...). layout adapts:
--   tall screens put the wheel on top, wide screens put it on the left.
--
-- controls:
--   tap / click a spot on the board = put a chip there
--   CHIP button = change chip value,  CLEAR = take bets back (REBET when empty),  SPIN = spin
--   keyboard: arrows move the cursor, enter = place / press,  s = spin, c = clear, x = chip, q = quit
-- needs: ccgraphics. optional: speaker, chat box. credits are shared with slots (slots.db).

local lib = require("auralib")
math.randomseed(os.epoch("utc"))

-- everything lives in these tables: ComputerCraft's Lua refuses functions with more than
-- 60 upvalues and scopes with more than 200 locals, so we keep the count of locals tiny.
local G = { bets = {}, lastBets = nil, history = {}, chipIdx = 1, state = "betting", rot = 0,
  ballPocket = 1, winLevel = 0, winT = -100, msgKind = "info", coins = {}, showerUntil = 0 }
local C = {}
local CHIPS = { 10, 50, 100, 500 }
local SAVE = "slots.db"

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
  G.CW, G.CH = t.getSize()
end
local PW, PH = G.PW, G.PH

G.speaker = peripheral.find("speaker")
G.chat = lib.findAny("chatBox", "chat_box")
local function now() return os.epoch("utc") / 1000 end
local function beep(sound, pitch, vol)
  if G.speaker then pcall(G.speaker.playSound, sound, vol or 2, pitch or 1) end
end
local function maybeYield()
  if os.clock() - (G.lastYield or 0) > 1 then
    os.queueEvent("roulette_yield")
    os.pullEvent("roulette_yield")
    G.lastYield = os.clock()
  end
end

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
local function toHex(r, g, b)
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
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

C.FELT    = family(ramp({ 0x03200f, 0x0a4a22, 0x137a3a }, 16))
C.WOOD    = family(ramp({ 0x1e0b03, 0x5a2a0e, 0x9a5520, 0xd08a40 }, 8))
C.TRACK   = family(ramp({ 0x2a1206, 0x7a4018, 0xc88a4c, 0xf0c890 }, 8))
C.CONE    = family(ramp({ 0x24100a, 0x6a3418, 0xb06a34 }, 8))
C.GOLD    = family({ 0x2a1703, 0x5c3a0c, 0x8f5f12, 0xbf8a1b, 0xe2b532, 0xf5d35c, 0xffeb98, 0xfffbe0 })
C.RED     = family({ 0x4a060c, 0x8a0e18, 0xc81e28, 0xf04a50 })
C.BLK     = family({ 0x060608, 0x141418, 0x24242a, 0x3e3e48 })
C.GRN     = family({ 0x04300f, 0x0a6020, 0x18a038, 0x50d070 })
C.FRET    = family({ 0xc8ccd8 })
C.WHITE   = family({ 0xffffff })
C.OUTLINE = family({ 0x0a0605 })
C.SHADOW  = family({ 0x010a04 })
C.BALL    = family({ 0x8a8a94, 0xc8c8d2, 0xf4f4fa })
C.LINE    = family({ 0xe8e0c8 })
C.PANEL   = family({ 0x062a12 })
C.TEXT    = family({ 0xf5ead6 })
C.DIM     = family({ 0x9ac0a0 })
C.MSG     = family({ 0xf5ead6 })
C.HILITE  = family({ 0xffe060 })
C.CURSOR  = family({ 0x60e0ff })
C.BTN     = family({ 0x3a1e08, 0x7a4a14, 0xc89030 })
C.SPINBTN = family({ 0x5a0a10, 0xa01820, 0xe04040 })
C.CHIPC   = {
  family({ 0x0a2a6a, 0x2a5ad0, 0x7aa8ff }),  -- 10 blue
  family({ 0x5a0a0a, 0xc02020, 0xff7070 }),  -- 50 red
  family({ 0x0a3a14, 0x22a040, 0x80f090 }),  -- 100 green
  family({ 0x101014, 0x34343c, 0x8a8a96 }),  -- 500 black
}
C.LEDON   = family({ 0xffb030 })

---------------------------------------------------------------- framebuffer
local fb = {}
for y = 1, PH do
  local r = {}
  for x = 1, PW do r[x] = C.FELT end
  fb[y] = r
end
local function put(x, y, c)
  local r = fb[y + 1]
  if r and x >= 0 and x < PW then r[x + 1] = c end
end
local function rowStr(row, x1, x2)
  local parts, i = {}, x1
  while i <= x2 do
    local j = math.min(i + 199, x2)
    parts[#parts + 1] = string.char(table.unpack(row, i, j))
    i = j + 1
  end
  return table.concat(parts)
end
local function push(x, y, w, h)
  x, y, w, h = math.floor(x), math.floor(y), math.ceil(w), math.ceil(h)
  if x < 0 then w = w + x x = 0 end
  if y < 0 then h = h + y y = 0 end
  if x + w > PW then w = PW - x end
  if y + h > PH then h = PH - y end
  if w <= 0 or h <= 0 then return end
  local rows = {}
  for j = 1, h do rows[j] = rowStr(fb[y + j], x + 1, x + w) end
  t.drawPixels(x, y, rows)
end
local function freeze(b) if type(t.setFrozen) == "function" then pcall(t.setFrozen, b) end end

-- base = copy of the static scene, used to erase the ball and the hub badge
local base = {}
local function saveBase()
  for y = 1, PH do
    local src, dst = fb[y], {}
    for x = 1, PW do dst[x] = src[x] end
    base[y] = dst
  end
end
local function restoreRect(x, y, w, h)
  x, y = math.floor(x), math.floor(y)
  for yy = math.max(0, y), math.min(PH - 1, y + h - 1) do
    local d, s = fb[yy + 1], base[yy + 1]
    for xx = math.max(0, x), math.min(PW - 1, x + w - 1) do d[xx + 1] = s[xx + 1] end
  end
end

---------------------------------------------------------------- drawing helpers
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function disk(cx, cy, r, fn)
  for y = math.floor(cy - r), math.ceil(cy + r) do
    for x = math.floor(cx - r), math.ceil(cx + r) do
      local a, b = (x - cx) / r, (y - cy) / r
      if a * a + b * b <= 1 then
        local c = fn(a, b)
        if c then put(x, y, c) end
      end
    end
  end
end
local function rect(x, y, w, h, c)
  for yy = y, y + h - 1 do for xx = x, x + w - 1 do put(xx, yy, c) end end
end
local function frame(x, y, w, h, th, c)
  for yy = y, y + h - 1 do
    for xx = x, x + w - 1 do
      if xx - x < th or x + w - 1 - xx < th or yy - y < th or y + h - 1 - yy < th then put(xx, yy, c) end
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
            local px = x + (ci - 1) * 4 * sc + (gx - 1) * sc
            local py = y + (gy - 1) * sc
            for yy = py - grow, py + sc - 1 + grow do
              for xx = px - grow, px + sc - 1 + grow do put(xx, yy, color) end
            end
          end
        end
      end
    end
  end
end
-- biggest text scale that fits a box, then draw it centred
local function fitScale(s, w, h, maxSc)
  return clamp(math.min(math.floor((w - 2) / textW(s, 1)), math.floor((h - 2) / 5)), 1, maxSc or 99)
end
local function textIn(x, y, w, h, s, col, outline, maxSc)
  local sc = fitScale(s, w, h, maxSc)
  text(x + math.floor((w - textW(s, sc)) / 2), y + math.floor((h - 5 * sc) / 2), s, sc, col, outline)
end
local function short(n)
  if n >= 1000000 then return math.floor(n / 100000) / 10 .. "M" end
  if n >= 10000 then return math.floor(n / 1000) .. "K" end
  if n >= 1000 then return math.floor(n / 100) / 10 .. "K" end
  return tostring(n)
end

---------------------------------------------------------------- wheel data
local ORDER = { 0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16,
  33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26 }
local REDS = {}
for _, n in ipairs({ 1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36 }) do REDS[n] = true end
local function colorName(n) if n == 0 then return "green" elseif REDS[n] then return "red" end return "black" end
local function colorFam(n) if n == 0 then return C.GRN elseif REDS[n] then return C.RED end return C.BLK end
G.SUB = 24
G.A = 37 * G.SUB

---------------------------------------------------------------- layout
local spots, buttons = {}, {}

local function addSpot(x, y, w, h, kind, val, label)
  spots[#spots + 1] = { x = x, y = y, w = w, h = h, kind = kind, val = val, label = label }
end
local function addButton(x, y, w, h, id)
  buttons[#buttons + 1] = { x = x, y = y, w = w, h = h, id = id, button = true }
end

local OUTSIDE = { { "low", nil, "1-18" }, { "even", nil, "EVEN" }, { "red", nil, "RED" },
  { "black", nil, "BLACK" }, { "odd", nil, "ODD" }, { "high", nil, "19-36" } }
local DOZ = { "1ST 12", "2ND 12", "3RD 12" }

-- wide board under the wheel (tall screens)
local function layoutHorizontal(x0, y0, w, cw, ch, gap)
  local hy = y0
  G.header = { x = x0, y = hy, w = w, h = math.floor(ch * 1.3) }
  local gy = hy + G.header.h + gap
  addSpot(x0, gy, cw, ch * 3, "num", 0, "0")
  for j = 1, 12 do
    for r = 0, 2 do
      local n = 3 * j - r
      addSpot(x0 + j * cw, gy + r * ch, cw, ch, "num", n, tostring(n))
    end
  end
  local dy = gy + 3 * ch
  for d = 1, 3 do addSpot(x0 + cw + (d - 1) * 4 * cw, dy, 4 * cw, ch, "dozen", d, DOZ[d]) end
  local oy = dy + ch
  for k, o in ipairs(OUTSIDE) do addSpot(x0 + cw + (k - 1) * 2 * cw, oy, 2 * cw, ch, o[1], o[2], o[3]) end
  local by = oy + ch + gap
  local bh = math.floor(ch * 1.3)
  local bw = math.floor((w - 2 * gap) / 3)
  addButton(x0, by, bw, bh, "chip")
  addButton(x0 + bw + gap, by, bw, bh, "clear")
  addButton(x0 + 2 * (bw + gap), by, w - 2 * (bw + gap), bh, "spin")
end

-- tall board beside the wheel (wide screens / the computer)
local function layoutVertical(x0, y0, w, h, gap)
  local u = math.max(6, math.floor((h - 3 * gap) / 17.6))
  local cw = math.floor(w / 5)
  G.header = { x = x0, y = y0, w = w, h = 3 * u }
  local gy = y0 + 3 * u + gap
  local nx = x0 + 2 * cw
  addSpot(nx, gy, 3 * cw, u, "num", 0, "0")
  for i = 1, 12 do
    for c = 0, 2 do
      local n = 3 * (i - 1) + c + 1
      addSpot(nx + c * cw, gy + i * u, cw, u, "num", n, tostring(n))
    end
  end
  for d = 1, 3 do addSpot(x0 + cw, gy + u + (d - 1) * 4 * u, cw, 4 * u, "dozen", d, DOZ[d]) end
  for k, o in ipairs(OUTSIDE) do addSpot(x0, gy + u + (k - 1) * 2 * u, cw, 2 * u, o[1], o[2], o[3]) end
  local by = gy + 13 * u + gap
  local bh = math.max(u, y0 + h - by)
  local bw = math.floor((5 * cw - 2 * gap) / 3)
  addButton(x0, by, bw, bh, "chip")
  addButton(x0 + bw + gap, by, bw, bh, "clear")
  addButton(x0 + 2 * (bw + gap), by, 5 * cw - 2 * (bw + gap), bh, "spin")
end

local function computeLayout()
  local m = math.max(3, math.floor(math.min(PW, PH) * 0.025))
  local gap = math.max(2, math.floor(m * 0.6))
  if PW >= PH * 1.15 then
    local d = math.min(PH - 2 * m, math.floor(PW * 0.56))
    G.R = math.floor(d / 2)
    G.WX, G.WY = m + G.R, math.floor(PH / 2)
    layoutVertical(m + d + m, m, PW - (m + d + m) - m, PH - 2 * m, gap)
    G.hist = { x = m, y = m, w = math.floor(G.R * 0.5), h = math.floor(G.R * 0.5), vertical = true }
  else
    local bw = PW - 2 * m
    local cw = math.floor(bw / 13)
    local ch = math.floor(cw * 0.95)
    local d
    repeat
      local boardH = math.floor(ch * 7.6) + 3 * gap
      d = math.min(bw, PH - boardH - 3 * m)
      if d < PH * 0.42 and ch > 8 then ch = ch - 1 end
    until d >= PH * 0.42 or ch <= 8
    G.R = math.floor(d / 2)
    G.WX, G.WY = math.floor(PW / 2), m + G.R
    local x0 = math.floor((PW - 13 * cw) / 2)
    layoutHorizontal(x0, m + d + m, 13 * cw, cw, ch, gap)
    local side = math.floor((PW - d) / 2) - m
    G.hist = { x = m, y = m, w = math.max(side, 8), h = d, vertical = true }
  end
  local R = G.R
  G.r1 = math.floor(R * 0.78)              -- outer edge of the spinning pocket ring
  G.rNum = math.floor(R * 0.62)            -- numbers above this, pockets below
  G.r0 = math.floor(R * 0.50)              -- inner edge of the ring
  G.trackR = R * 0.865
  G.pocketR = (G.r0 + G.rNum) / 2
  G.ballR = math.max(2, math.floor(R * 0.035))
  G.hubR = math.max(6, math.floor(R * 0.2))
end

---------------------------------------------------------------- static scene
local function buildFelt()
  local cx, cy = PW / 2, PH / 2
  local md = math.sqrt(cx * cx + cy * cy)
  local bay = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
  for y = 0, PH - 1 do
    local row, br = fb[y + 1], bay[(y % 4) + 1]
    for x = 0, PW - 1 do
      local d = math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2) / md
      local v = (1 - d * 0.85) * 15 + br[(x % 4) + 1] / 16 - 0.5
      row[x + 1] = C.FELT + clamp(math.floor(v), 0, 15)
    end
    maybeYield()
  end
end

local function buildBowl()
  local R, WX, WY = G.R, G.WX, G.WY
  -- drop shadow
  disk(WX + R * 0.06, WY + R * 0.08, R * 1.02, function() return C.SHADOW end)
  for y = math.floor(WY - R), math.ceil(WY + R) do
    for x = math.floor(WX - R), math.ceil(WX + R) do
      local dx, dy = x - WX, y - WY
      local d = math.sqrt(dx * dx + dy * dy) / R
      if d <= 1 then
        local lit = -(dx + dy) / (R * 2.8)  -- light from the top-left
        local c
        if d > 0.985 then c = C.GOLD + 2
        elseif d > 0.955 then c = C.GOLD + clamp(math.floor(5 + lit * 6), 3, 7)
        elseif d > 0.93 then c = C.WOOD + clamp(math.floor(2 + lit * 4), 0, 7)
        elseif d > 0.80 then
          local k = 1 - math.abs((d - 0.865) / 0.065)   -- brighter mid-track: a curved bowl
          c = C.TRACK + clamp(math.floor(2 + k * 4 + lit * 3), 0, 7)
        elseif d > 0.78 then c = C.GOLD + clamp(math.floor(4 + lit * 4), 2, 7)
        elseif d > 0.5 then c = C.BLK
        elseif d > 0.47 then c = C.GOLD + clamp(math.floor(4 + lit * 4), 2, 7)
        else
          local k = d / 0.47
          c = C.CONE + clamp(math.floor((1 - k) * 4 + 2 + lit * 4), 0, 7)
        end
        put(x, y, c)
      end
    end
    maybeYield()
  end
  -- diamond deflectors on the track
  local dr = math.max(2, math.floor(R * 0.03))
  for k = 0, 7 do
    local a = k * math.pi / 4 + math.pi / 8
    local cx, cy = WX + math.cos(a) * R * 0.845, WY + math.sin(a) * R * 0.845
    for yy = -dr, dr do
      for xx = -dr, dr do
        if math.abs(xx) + math.abs(yy) <= dr then
          put(math.floor(cx + xx), math.floor(cy + yy), (xx + yy < 0) and C.GOLD + 6 or C.GOLD + 3)
        end
      end
    end
  end
  -- turret: four spokes with knobs, gold centre
  local sr = R * 0.3
  for k = 0, 3 do
    local a = k * math.pi / 2 + math.pi / 4
    local ex, ey = WX + math.cos(a) * sr, WY + math.sin(a) * sr
    local th = math.max(1, R * 0.025)
    for s = 0, 1, 1 / (sr * 1.5) do
      disk(WX + (ex - WX) * s, WY + (ey - WY) * s, th, function(u, v) return (u + v < 0) and C.GOLD + 6 or C.GOLD + 3 end)
    end
    disk(ex, ey, th * 2.2, function(u, v)
      if (u + 0.35) ^ 2 + (v + 0.35) ^ 2 < 0.08 then return C.WHITE end
      return (u + v < 0) and C.GOLD + 5 or C.GOLD + 2
    end)
  end
  disk(WX, WY, G.hubR + 1, function() return C.OUTLINE end)
  disk(WX, WY, G.hubR, function(u, v)
    local s = u + v
    if (u + 0.4) ^ 2 + (v + 0.4) ^ 2 < 0.05 then return C.WHITE end
    return C.GOLD + clamp(math.floor(5 - s * 2), 1, 7)
  end)
end

---------------------------------------------------------------- spinning ring (polar texture)
-- The ring is painted once into a texture indexed by (angle bin, radius). Each frame every ring
-- pixel just looks up texture[(its angle - wheel angle), its radius]: cheap enough to spin live.
local tex, ring = {}, {}

local function buildTexture()
  local A, SUB, r0, r1, rNum = G.A, G.SUB, G.r0, G.r1, G.rNum
  local RB = r1 - r0 + 1
  G.RB = RB
  local rc = (rNum + r1) / 2
  local nsc = math.max(1, math.min(math.floor((r1 - rNum) * 0.75 / 5), math.floor(2 * math.pi * rc / 37 * 0.8 / 7)))
  local rTop = rc + 2.5 * nsc
  for a = 0, A - 1 do
    local p = math.floor(a / SUB)
    local n = ORDER[p + 1]
    local fam = colorFam(n)
    local u = (a % SUB + 0.5) / SUB - 0.5
    local s = tostring(n)
    local tw = textW(s, 1)
    for rr = 0, RB - 1 do
      local rad = r0 + rr + 0.5
      local c
      if rr == 0 or math.abs(rad - rNum) < 0.6 or rr == RB - 1 then
        c = C.GOLD + 4
      elseif rad > rNum then
        c = (math.abs(u) > 0.46) and C.GOLD + 3 or fam + ((rad > r1 - 2) and 3 or 2)
        local arc = u * 2 * math.pi * rad / 37
        local gx = math.floor((arc + tw * nsc / 2) / nsc)
        local gy = math.floor((rTop - rad) / nsc)
        if gx >= 0 and gx < tw and gy >= 0 and gy < 5 then
          local ci = math.floor(gx / 4) + 1
          local col = gx % 4
          local g = lib.font[s:sub(ci, ci)]
          if g and col < 3 and g[gy + 1]:sub(col + 1, col + 1) == "#" then c = C.WHITE end
        end
      else
        if math.abs(u) > 0.44 then c = C.FRET
        else
          local depth = (rad - r0) / (rNum - r0)
          c = fam + ((math.abs(u) > 0.32 or depth < 0.25) and 0 or 1)
        end
      end
      tex[a * RB + rr + 1] = c
    end
    if a % 64 == 0 then maybeYield() end
  end
  -- which screen pixels belong to the ring, with their angle bin and radius
  for y = math.floor(G.WY - r1), math.ceil(G.WY + r1) do
    local xs, as, rs = {}, {}, {}
    for x = math.floor(G.WX - r1), math.ceil(G.WX + r1) do
      local dx, dy = x - G.WX, y - G.WY
      local d = math.sqrt(dx * dx + dy * dy)
      if d >= r0 and d < r1 + 1 and x >= 0 and x < PW and y >= 0 and y < PH then
        local ang = math.atan2(dy, dx)
        xs[#xs + 1] = x + 1
        as[#as + 1] = math.floor((ang / (2 * math.pi)) * A) % A
        rs[#rs + 1] = clamp(math.floor(d - r0), 0, RB - 1)
      end
    end
    if #xs > 0 then ring[#ring + 1] = { y = y + 1, xs = xs, as = as, rs = rs } end
  end
end

local function renderRing()
  local A, RB = G.A, G.RB
  local off = math.floor(G.rot / (2 * math.pi) * A) % A
  for _, rw in ipairs(ring) do
    local row, xs, as, rs = fb[rw.y], rw.xs, rw.as, rw.rs
    for k = 1, #xs do
      row[xs[k]] = tex[((as[k] - off) % A) * RB + rs[k] + 1]
    end
  end
end

---------------------------------------------------------------- ball
local function ballPos()
  if G.ballAng then return G.WX + math.cos(G.ballAng) * G.ballRad, G.WY + math.sin(G.ballAng) * G.ballRad end
  local th = (G.ballPocket - 0.5) / 37 * 2 * math.pi + G.rot
  return G.WX + math.cos(th) * G.pocketR, G.WY + math.sin(th) * G.pocketR
end

local function drawBall()
  local bx, by = ballPos()
  local r = G.ballR
  G.ballBox = { math.floor(bx - r - 2), math.floor(by - r - 2), 2 * r + 5, 2 * r + 5 }
  disk(bx + 1, by + 1, r, function() return C.OUTLINE end)
  disk(bx, by, r + 0.6, function() return C.OUTLINE end)
  disk(bx, by, r, function(u, v)
    if (u + 0.35) ^ 2 + (v + 0.4) ^ 2 < 0.09 then return C.WHITE end
    local s = u + v
    return C.BALL + ((s < -0.3) and 2 or ((s < 0.6) and 1 or 0))
  end)
end

-- redraw wheel + ball for this frame
local function frameWheel()
  local old = G.ballBox
  if old then restoreRect(old[1], old[2], old[3], old[4]) end
  renderRing()
  drawBall()
  local r1 = G.r1
  push(G.WX - r1 - 1, G.WY - r1 - 1, 2 * r1 + 3, 2 * r1 + 3)
  if old then push(old[1], old[2], old[3], old[4]) end
  local b = G.ballBox
  push(b[1], b[2], b[3], b[4])
end

---------------------------------------------------------------- hub badge (shows the result)
local function drawHub(n)
  local hr = G.hubR
  restoreRect(G.WX - hr - 2, G.WY - hr - 2, 2 * hr + 5, 2 * hr + 5)
  if n then
    local fam = colorFam(n)
    disk(G.WX, G.WY, hr + 1, function() return C.GOLD + 6 end)
    disk(G.WX, G.WY, hr, function(u, v) return fam + ((u + v < -0.2) and 3 or 2) end)
    local s = tostring(n)
    local box = math.floor(hr * 1.3)
    textIn(G.WX - math.floor(box / 2), G.WY - math.floor(box / 2), box, box, s, C.WHITE, C.OUTLINE)
  end
  push(G.WX - hr - 2, G.WY - hr - 2, 2 * hr + 5, 2 * hr + 5)
end

---------------------------------------------------------------- board drawing
local function totalBet()
  local s = 0
  for _, v in pairs(G.bets) do s = s + v end
  return s
end

local function chipColorFor(amount)
  local k = 1
  for i, v in ipairs(CHIPS) do if amount >= v then k = i end end
  return C.CHIPC[k]
end

local function drawChip(cx, cy, r, fam, label)
  disk(cx + 1, cy + 1, r, function() return C.OUTLINE end)
  if r < 5 then -- too small for stripes: plain chip with a white rim
    disk(cx, cy, r, function(u, v) return (u * u + v * v > 0.5) and C.WHITE or fam + 1 end)
    return
  end
  disk(cx, cy, r, function(u, v)
    local d = u * u + v * v
    if d > 0.55 then
      local a = math.atan2(v, u)
      if math.floor((a + math.pi) / (math.pi / 4)) % 2 == 0 then return C.WHITE end
      return fam + 1
    end
    if d > 0.45 then return C.WHITE end
    return fam + ((u + v < -0.3) and 2 or 1)
  end)
  if label and r * 2 - 2 >= textW(label, 1) then
    text(math.floor(cx - textW(label, 1) / 2 + 0.5), math.floor(cy - 2), label, 1, C.WHITE, C.OUTLINE)
  end
end

local function spotWins(sp, n)
  if sp.kind == "num" then return sp.val == n end
  if n == 0 then return false end
  if sp.kind == "red" then return REDS[n] == true end
  if sp.kind == "black" then return not REDS[n] end
  if sp.kind == "odd" then return n % 2 == 1 end
  if sp.kind == "even" then return n % 2 == 0 end
  if sp.kind == "low" then return n <= 18 end
  if sp.kind == "high" then return n >= 19 end
  if sp.kind == "dozen" then return math.ceil(n / 12) == sp.val end
  return false
end
local function spotPays(sp)
  if sp.kind == "num" then return 36 elseif sp.kind == "dozen" then return 3 end
  return 2
end

local function drawSpot(i)
  local sp = spots[i]
  local x, y, w, h = sp.x, sp.y, sp.w, sp.h
  local fill, txt = C.FELT + 9, C.WHITE
  if sp.kind == "num" then fill = colorFam(sp.val) + 1
  elseif sp.kind == "red" then fill = C.RED + 1
  elseif sp.kind == "black" then fill = C.BLK + 1 end
  rect(x, y, w, h, C.LINE)
  rect(x + 1, y + 1, w - 2, h - 2, fill)
  textIn(x + 1, y + 1, w - 2, h - 2, sp.label, txt, nil, (sp.kind == "num") and G.boardSc or G.outSc)
  if sp.win then frame(x, y, w, h, math.max(1, math.floor(math.min(w, h) / 10)), C.HILITE) end
  if G.cursor == i then frame(x + 1, y + 1, w - 2, h - 2, 1, C.CURSOR) end
  local amt = G.bets[i]
  if amt then
    local r = clamp(math.floor(math.min(w, h) * 0.42), 3, G.chipMax)
    local cx = x + w / 2
    if r < 5 then cx = x + w - r - 3 end -- tiny cells: tuck the chip at the end, keep the number readable
    drawChip(cx, y + h / 2, r, chipColorFor(amt), short(amt))
  end
  push(x, y, w, h)
end

local function drawButton(b)
  local fam, label = C.BTN, ""
  if b.id == "spin" then
    fam = C.SPINBTN
    label = (G.state == "spinning") and "..." or "SPIN"
  elseif b.id == "clear" then
    label = (totalBet() == 0 and G.lastBets) and "REBET" or "CLEAR"
  elseif b.id == "chip" then
    label = "CHIP"
  end
  for yy = b.y, b.y + b.h - 1 do
    for xx = b.x, b.x + b.w - 1 do
      local e = math.min(xx - b.x, b.x + b.w - 1 - xx, yy - b.y, b.y + b.h - 1 - yy)
      local c
      if e < 1 then c = C.OUTLINE
      elseif e < 2 then c = (yy - b.y < b.h / 2) and fam + 2 or fam
      else c = fam + 1 end
      put(xx, yy, c)
    end
  end
  if b.id == "chip" then
    local r = math.max(3, math.min(math.floor(b.h * 0.36), math.floor(b.w * 0.17)))
    local v = CHIPS[G.chipIdx]
    local lw = b.w - 2 * r - 6
    drawChip(b.x + 3 + r, b.y + b.h / 2, r, C.CHIPC[G.chipIdx], short(v))
    if lw > 8 then textIn(b.x + 2 * r + 5, b.y + 2, lw, b.h - 4, label, C.TEXT, C.OUTLINE) end
  else
    textIn(b.x + 2, b.y + 2, b.w - 4, b.h - 4, label, C.TEXT, C.OUTLINE)
  end
  if G.cursor == -b.idx then frame(b.x, b.y, b.w, b.h, 1, C.CURSOR) end
  push(b.x, b.y, b.w, b.h)
end

local function drawHeader()
  local hd = G.header
  rect(hd.x, hd.y, hd.w, hd.h, C.PANEL)
  frame(hd.x, hd.y, hd.w, hd.h, 1, C.GOLD + 4)
  local half = math.floor(hd.h / 2)
  local credits = "CREDITS " .. short(G.credits)
  local bet = "BET " .. short(totalBet())
  local lw = math.floor(hd.w * 0.55)
  textIn(hd.x + 2, hd.y + 2, lw, half - 2, credits, C.LEDON, nil, 3)
  textIn(hd.x + lw, hd.y + 2, hd.w - lw - 2, half - 2, bet, C.TEXT, nil, 3)
  textIn(hd.x + 2, hd.y + half, hd.w - 4, hd.h - half - 2, G.msg or "", C.MSG, C.OUTLINE, 3)
  push(hd.x, hd.y, hd.w, hd.h)
end

local function drawHistory()
  local hb = G.hist
  if not hb or hb.w < 8 then return end
  restoreRect(hb.x, hb.y, hb.w, hb.h)
  local size = math.max(7, math.min(hb.w - 2, math.floor(G.R * 0.22)))
  local maxN = math.floor((hb.h - 2) / (size + 2))
  for i = 1, math.min(#G.history, maxN) do
    local n = G.history[i]
    local x, y = hb.x + 1, hb.y + 1 + (i - 1) * (size + 2)
    rect(x, y, size, size, (i == 1) and C.HILITE or C.OUTLINE)
    rect(x + 1, y + 1, size - 2, size - 2, colorFam(n) + 2)
    textIn(x + 1, y + 1, size - 2, size - 2, tostring(n), C.WHITE, nil, 3)
  end
  push(hb.x, hb.y, hb.w, hb.h)
end

local function setMsg(s, kind)
  G.msg, G.msgKind = s, kind or "info"
  drawHeader()
end

local function redrawBoard()
  for i = 1, #spots do drawSpot(i) end
  for _, b in ipairs(buttons) do drawButton(b) end
  drawHeader()
end

---------------------------------------------------------------- coins (big wins)
local function coinSprite(fw, cs)
  local spr, r = {}, cs / 2
  for j = 1, cs do
    local row = {}
    for q = 1, cs do
      local a, b = (q - 0.5 - r) / (r * fw), (j - 0.5 - r) / r
      local d = a * a + b * b
      if d <= 1 then
        if fw < 0.4 or d > 0.62 then row[q] = C.GOLD + 3
        elseif (a + 0.35) ^ 2 + (b + 0.35) ^ 2 < 0.06 then row[q] = C.WHITE
        else row[q] = C.GOLD + ((a + b < 0) and 6 or 4) end
      else row[q] = false end
    end
    spr[j] = row
  end
  return spr
end
G.CS = math.max(4, math.floor(math.min(PW, PH) / 26))
G.coinSprites = {}
for k, fw in ipairs({ 1, 0.66, 0.22, 0.66 }) do G.coinSprites[k] = coinSprite(fw, G.CS) end

local function updateCoins(tm)
  local coins, CS = G.coins, G.CS
  if #coins == 0 and tm > G.showerUntil then return end
  for _, cn in ipairs(coins) do if cn.px then push(cn.px, cn.py, CS, CS) end end
  if tm < G.showerUntil then
    for _ = 1, 2 do
      if #coins < 40 then
        coins[#coins + 1] = { x = math.random(0, PW - CS), y = -CS - math.random(0, math.floor(PH / 4)),
          vx = (math.random() - 0.5) * 1.5, vy = math.random() * 2, f = math.random(0, 3) }
      end
    end
  end
  for k = #coins, 1, -1 do
    local cn = coins[k]
    cn.vy = cn.vy + PH * 0.004
    cn.x, cn.y, cn.f = cn.x + cn.vx, cn.y + cn.vy, cn.f + 1
    if cn.y > PH then table.remove(coins, k) end
  end
  for _, cn in ipairs(coins) do
    local x, y = math.floor(cn.x), math.floor(cn.y)
    local spr = G.coinSprites[(cn.f % 4) + 1]
    cn.px, cn.py = x, y
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
  local winning = G.winLevel > 0 and tm - G.winT < 6
  local pulse = 0.5 + 0.5 * math.sin(tm * 8)
  setPal(C.HILITE, mix(0xffa020, 0xffffa0, pulse))
  setPal(C.CURSOR, mix(0x2080ff, 0xa0f0ff, 0.5 + 0.5 * math.sin(tm * 6)))
  if G.msgKind == "big" then setPal(C.MSG, toHex(lib.hsv(tm * 0.8, 0.7, 1)))
  elseif G.msgKind == "win" then setPal(C.MSG, mix(0x40ff70, 0xd0ffd8, pulse))
  elseif G.msgKind == "bad" then setPal(C.MSG, mix(0xff4040, 0x902020, pulse))
  else setPal(C.MSG, 0xf5ead6) end
  if winning and G.winLevel >= 2 then
    for k = 0, 7 do setPal(C.GOLD + k, mix(({ 0x2a1703, 0x5c3a0c, 0x8f5f12, 0xbf8a1b, 0xe2b532, 0xf5d35c, 0xffeb98, 0xfffbe0 })[k + 1], 0xffffff, pulse * 0.4)) end
    G.goldPulsed = true
  elseif G.goldPulsed then
    local base8 = { 0x2a1703, 0x5c3a0c, 0x8f5f12, 0xbf8a1b, 0xe2b532, 0xf5d35c, 0xffeb98, 0xfffbe0 }
    for k = 0, 7 do setPal(C.GOLD + k, base8[k + 1]) end
    G.goldPulsed = false
  end
end

---------------------------------------------------------------- game
local function loadCredits()
  G.credits = 500
  if fs.exists(SAVE) then
    local f = fs.open(SAVE, "r")
    G.credits = tonumber(f.readLine()) or 500
    f.close()
  end
end
local function saveCredits()
  local f = fs.open(SAVE, "w")
  f.write(tostring(G.credits))
  f.close()
end

local function announce(msg)
  local chat = G.chat
  if not chat then return end
  local json = textutils.serializeJSON({ { text = "" }, { text = msg, color = "gold", bold = true } })
  local order = (G.chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res = pcall(function()
      if style == "new" then return chat.sendFormattedMessage(json, { prefix = "ROULETTE", brackets = "[]", bracketColor = "&2" })
      else return chat.sendFormattedMessage(json, "ROULETTE", "[]", "&2") end
    end)
    if ok and res then G.chatStyle = style return end
  end
  pcall(chat.sendMessage, msg, "ROULETTE")
end

local function clearWins()
  for i, sp in ipairs(spots) do
    if sp.win then sp.win = nil drawSpot(i) end
  end
end

local function placeChip(i)
  if G.state ~= "betting" then return end
  local v = CHIPS[G.chipIdx]
  if G.credits < v then setMsg("NOT ENOUGH CREDITS", "bad") beep("minecraft:entity.villager.no", 1) return end
  clearWins()
  G.credits = G.credits - v
  G.bets[i] = (G.bets[i] or 0) + v
  saveCredits()
  drawSpot(i)
  for _, b in ipairs(buttons) do if b.id == "clear" then drawButton(b) end end
  setMsg(spots[i].label .. " +" .. v, "info")
  beep("minecraft:block.stone_button.click_on", 1.6)
end

local function clearOrRebet()
  if G.state ~= "betting" then return end
  if totalBet() > 0 then
    for i, v in pairs(G.bets) do G.credits = G.credits + v G.bets[i] = nil drawSpot(i) end
    setMsg("BETS CLEARED", "info")
  elseif G.lastBets then
    local need = 0
    for _, v in pairs(G.lastBets) do need = need + v end
    if need > G.credits then setMsg("NOT ENOUGH CREDITS", "bad") return end
    clearWins()
    for i, v in pairs(G.lastBets) do G.bets[i] = v G.credits = G.credits - v drawSpot(i) end
    setMsg("REBET " .. short(need), "info")
  end
  saveCredits()
  for _, b in ipairs(buttons) do drawButton(b) end
  drawHeader()
end

local function cycleChip()
  G.chipIdx = (G.chipIdx % #CHIPS) + 1
  for _, b in ipairs(buttons) do if b.id == "chip" then drawButton(b) end end
  beep("minecraft:block.stone_button.click_on", 1.2)
end

local function startSpin()
  if G.state ~= "betting" then return end
  if totalBet() == 0 then setMsg("PLACE A BET FIRST", "bad") return end
  clearWins()
  G.state = "spinning"
  G.result = math.random(0, 36)
  local p = 1
  for k, n in ipairs(ORDER) do if n == G.result then p = k end end
  G.targetPocket = p
  G.spinStart = now()
  G.w0 = G.rot
  G.TW = 7.5                         -- wheel spin length
  G.T2 = 5.2                         -- ball lands at this time
  G.T1 = 3.4                         -- ball leaves the track and spirals in
  G.wDist = 2 * math.pi * (1.6 + math.random() * 0.6)
  local function wAt(e) local x = math.min(1, e / G.TW) return G.w0 + G.wDist * (1 - (1 - x) ^ 2) end
  G.wAt = wAt
  G.bDist = -2 * math.pi * (6 + math.random() * 2)
  local thetaP = (p - 0.5) / 37 * 2 * math.pi
  G.b0 = wAt(G.T2) + thetaP - G.bDist
  G.lastSound = 0
  drawHub(nil)
  setMsg("NO MORE BETS", "info")
  for _, b in ipairs(buttons) do drawButton(b) end
  beep("minecraft:block.lever.click", 0.7)
end

local function finishSpin(tm)
  G.state = "betting"
  G.ballAng = nil
  G.ballPocket = G.targetPocket
  local n = G.result
  table.insert(G.history, 1, n)
  if #G.history > 12 then table.remove(G.history) end
  local payout, straight = 0, false
  for i, sp in ipairs(spots) do
    if spotWins(sp, n) then
      sp.win = true
      if G.bets[i] then
        payout = payout + G.bets[i] * spotPays(sp)
        if sp.kind == "num" then straight = true end
      end
    end
  end
  local staked = totalBet()
  G.lastBets = {}
  for i, v in pairs(G.bets) do G.lastBets[i] = v end
  G.bets = {}
  G.credits = G.credits + payout
  saveCredits()
  drawHub(n)
  drawHistory()
  local label = n .. " " .. colorName(n):upper()
  if straight then
    G.winLevel, G.winT = 2, tm
    G.showerUntil = tm + 3.5
    setMsg(label .. "  WIN +" .. short(payout), "big")
    beep("minecraft:ui.toast.challenge_complete", 1, 3)
    announce("someone hit " .. n .. " straight up on roulette! +" .. lib.commas(payout) .. " credits")
  elseif payout > 0 then
    G.winLevel, G.winT = 1, tm
    setMsg(label .. "  WIN +" .. short(payout), "win")
    beep("minecraft:entity.player.levelup", 1)
  else
    G.winLevel = 0
    setMsg(label .. "  LOST " .. short(staked), "bad")
    beep("minecraft:block.note_block.bass", 0.6)
  end
  redrawBoard()
end

local function updateSpin(tm)
  local e = tm - G.spinStart
  G.rot = G.wAt(e)
  if e < G.T2 then
    local x = e / G.T2
    G.ballAng = G.b0 + G.bDist * (1 - (1 - x) ^ 2)
    if e < G.T1 then
      G.ballRad = G.trackR
    else
      local y = (e - G.T1) / (G.T2 - G.T1)
      local s = y * y * (3 - 2 * y)
      G.ballRad = G.trackR + (G.pocketR - G.trackR) * s + G.R * 0.07 * math.abs(math.sin(y * math.pi * 3)) * (1 - y)
      G.ballAng = G.ballAng + 0.3 * math.sin(y * math.pi * 4) * y * (1 - y) * 4
    end
    local gapT = (e < G.T1) and 0.12 + x * 0.25 or 0.18
    if tm - G.lastSound > gapT then
      beep((e < G.T1) and "minecraft:block.note_block.hat" or "minecraft:block.wood.hit", 1.3, 1)
      G.lastSound = tm
    end
  else
    if G.ballAng then
      G.ballAng = nil
      G.ballPocket = G.targetPocket
      beep("minecraft:block.note_block.basedrum", 1)
    end
  end
  if e >= G.TW then finishSpin(tm) end
end

---------------------------------------------------------------- input
local function hit(px, py)
  for i, sp in ipairs(spots) do
    if px >= sp.x and px < sp.x + sp.w and py >= sp.y and py < sp.y + sp.h then return i end
  end
  for _, b in ipairs(buttons) do
    if px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h then return -b.idx end
  end
end

local function activate(target)
  if not target then return end
  if target > 0 then placeChip(target) return end
  local b = buttons[-target]
  if b.id == "spin" then startSpin()
  elseif b.id == "clear" then clearOrRebet()
  elseif b.id == "chip" then cycleChip() end
end

local function itemRect(target)
  if target > 0 then return spots[target] end
  return buttons[-target]
end

-- move the keyboard cursor to the nearest item in a direction
local function moveCursor(dx, dy)
  local cur = itemRect(G.cursor)
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
  local best, bestScore
  local function consider(id, r)
    local ox, oy = r.x + r.w / 2 - cx, r.y + r.h / 2 - cy
    local along = ox * dx + oy * dy
    if along > 0.5 then
      local across = math.abs(ox * dy) + math.abs(oy * dx)
      local score = along + across * 2.5
      if not bestScore or score < bestScore then best, bestScore = id, score end
    end
  end
  for i, sp in ipairs(spots) do consider(i, sp) end
  for _, b in ipairs(buttons) do consider(-b.idx, b) end
  if best then
    local old = G.cursor
    G.cursor = best
    if old > 0 then drawSpot(old) else drawButton(buttons[-old]) end
    if best > 0 then drawSpot(best) else drawButton(buttons[-best]) end
  end
end

---------------------------------------------------------------- run
loadCredits()
computeLayout()
if CC_SIM then CC_SIM.spots = spots end -- test harness hook (does nothing in-game)
for i, b in ipairs(buttons) do b.idx = i end
G.boardSc = 3
G.chipMax = math.max(5, math.floor(math.min(PW, PH) / 18))
G.outSc = 3
for _, sp in ipairs(spots) do
  if sp.kind ~= "num" then G.outSc = math.min(G.outSc, fitScale(sp.label, sp.w - 2, sp.h - 2)) end
end
for _, sp in ipairs(spots) do
  if sp.kind == "num" and sp.val ~= 0 then G.boardSc = math.min(G.boardSc, fitScale("36", sp.w - 2, sp.h - 2)) end
end
G.cursor = 1
for i, sp in ipairs(spots) do if sp.kind == "red" then G.cursor = i end end
G.msg = G.isMon and "TAP THE BOARD TO BET" or "CLICK OR ARROWS + ENTER"

buildFelt()
buildBowl()
saveBase()
buildTexture()
renderRing()
for i = 1, #spots do drawSpot(i) end
for _, b in ipairs(buttons) do drawButton(b) end
drawHeader()
push(0, 0, PW, PH)
drawBall()
frameWheel()
drawHistory()

local monName = G.isMon and peripheral.getName(t) or nil
local ok, err = pcall(function()
  local timer = os.startTimer(0.05)
  local tickN = 0
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      local tm = now()
      tickN = tickN + 1
      freeze(true)
      updatePalettes(tm)
      if G.state == "spinning" then
        updateSpin(tm)
        frameWheel()
      elseif tickN % 3 == 0 then
        G.rot = G.rot + 0.06               -- slow idle drift
        frameWheel()
      end
      updateCoins(tm)
      freeze(false)
      timer = os.startTimer(0.05)
    elseif e == "monitor_touch" and a == monName then
      -- touches arrive in text-cell coordinates: use the centre of that cell
      activate(hit((b - 1) * 6 + 3, (c - 1) * 9 + 4))
    elseif e == "mouse_click" and not G.isMon then
      -- in graphics mode clicks are in pixels; fall back to cells if they look like cells
      local px, py = b, c
      if b <= G.CW and c <= G.CH and G.mouseIsCells then px, py = (b - 1) * 6 + 3, (c - 1) * 9 + 4 end
      activate(hit(px, py))
    elseif e == "key" then
      if a == keys.q then break
      elseif a == keys.left then moveCursor(-1, 0)
      elseif a == keys.right then moveCursor(1, 0)
      elseif a == keys.up then moveCursor(0, -1)
      elseif a == keys.down then moveCursor(0, 1)
      elseif a == keys.enter or a == keys.space then activate(G.cursor)
      elseif a == keys.s then startSpin()
      elseif a == keys.c then clearOrRebet()
      elseif a == keys.x then cycleChip() end
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
for _, v in pairs(G.bets) do G.credits = G.credits + v end
saveCredits()
print("left the table with " .. lib.commas(G.credits) .. " credits.")
