-- slots.lua :: pixel-art slot machine, drawn with the CC: Graphics mod (256-colour graphics mode).
--   gold bezel cabinet, chasing marquee bulbs, shimmering JACKPOT sign, 3D-shaded spinning
--   reels with bounce stops, a pull lever, LED credit counter, and a coin shower on big wins.
--
-- controls: tap the monitor / click the screen / space or enter = pull.  q = quit.
-- needs: CC: Graphics (ccgraphics) on an advanced computer or advanced monitor.
-- optional: speaker (sounds), chat box (announces big wins).
-- credits persist in slots.db. each pull costs 10. the old text version is slots_classic.

local lib = require("auralib")
math.randomseed(os.epoch("utc"))

local BET = 10
local SAVE = "slots.db"

-- name, payout multiplier for 3-in-a-row, weight (higher = more common)
local SYMBOLS = {
  { "DIAMOND", 100, 1 },
  { "SEVEN",    50, 2 },
  { "BELL",     20, 3 },
  { "STAR",     10, 4 },
  { "BAR",       6, 5 },
  { "LEMON",     4, 7 },
  { "CHERRY",    3, 9 },
}
local MULT, WEIGHT_TOTAL = {}, 0
for _, s in ipairs(SYMBOLS) do MULT[s[1]] = s[2] WEIGHT_TOTAL = WEIGHT_TOTAL + s[3] end
local function rollSymbol()
  local r = math.random(WEIGHT_TOTAL)
  for _, s in ipairs(SYMBOLS) do
    r = r - s[3]
    if r <= 0 then return s[1] end
  end
  return "CHERRY"
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
  print("the old text version still works: slots_classic")
  return
end
local isMon = (t ~= term)

-- pick the sharpest monitor text scale that keeps the pixel count sane (Lua has to fill every pixel)
local MAX_PIXELS = 140000
if isMon then
  local chosen = 5
  for s = 0.5, 5, 0.5 do
    t.setTextScale(s)
    local w, h = t.getSize()
    if w * 6 * h * 9 <= MAX_PIXELS then chosen = s break end
  end
  t.setTextScale(chosen)
end

local okMode, modeErr = pcall(t.setGraphicsMode, 2)
if not okMode then
  printError("couldn't switch to 256-colour graphics mode: " .. tostring(modeErr))
  return
end

local PW, PH
do
  local ok, w, h = pcall(t.getSize, 2)
  if ok and type(w) == "number" and type(h) == "number" then
    PW, PH = w, h
  else
    local cw, ch = t.getSize()
    PW, PH = cw * 6, ch * 9
  end
end

local speaker = peripheral.find("speaker")
local chat = lib.findAny("chatBox", "chat_box")
local function now() return os.epoch("utc") / 1000 end
local function beep(sound, pitch, vol)
  if speaker then pcall(speaker.playSound, sound, vol or 2, pitch or 1) end
end

local lastYield = os.clock()
local function maybeYield()
  if os.clock() - lastYield > 1 then
    os.queueEvent("slots_yield")
    os.pullEvent("slots_yield")
    lastYield = os.clock()
  end
end

---------------------------------------------------------------- palette (mode 2: indices 0-255)
local palCache = {}
local function setPal(i, c)
  if palCache[i] == c then return end
  palCache[i] = c
  pcall(t.setPaletteColor, i, c)
end
local function split(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 end
local function mix(a, b, f)
  local ar, ag, ab = split(a)
  local br, bg, bb = split(b)
  return math.floor(ar + (br - ar) * f + 0.5) * 65536
       + math.floor(ag + (bg - ag) * f + 0.5) * 256
       + math.floor(ab + (bb - ab) * f + 0.5)
end
local function toHex(r, g, b)
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
end
local function rampColors(stops, n)
  local out = {}
  for k = 0, n - 1 do
    local f = (n == 1) and 0 or k / (n - 1) * (#stops - 1)
    local s = math.floor(f)
    local c1 = stops[math.min(s + 1, #stops)]
    local c2 = stops[math.min(s + 2, #stops)]
    out[k + 1] = mix(c1, c2, f - s)
  end
  return out
end
local nextIdx = 16
local function family(list)
  local base = nextIdx
  for k, c in ipairs(list) do setPal(base + k - 1, c) end
  nextIdx = nextIdx + #list
  return base
end
local function alloc(n) local base = nextIdx nextIdx = nextIdx + n return base end

local BGCOLS   = rampColors({ 0x07021a, 0x1d0636, 0x3b0a3f }, 24)
local BG       = family(BGCOLS)
local STARA    = family({ 0xffffff })
local STARB    = family({ 0x8a7aaa })
local GOLD     = family({ 0x2a1703, 0x5c3a0c, 0x8f5f12, 0xbf8a1b, 0xe2b532, 0xf5d35c, 0xffeb98, 0xfffbe0 })
local CAB      = family(rampColors({ 0xb3222c, 0x7c0f1b, 0x3a0510 }, 8))
local PANEL    = family({ 0x12061f })
local PANEL2   = family({ 0x1e0c30 })
local SHINE_ROWS, SHINE_BANDS = 4, 12
local SHINE    = alloc(SHINE_ROWS * SHINE_BANDS)
local TITLE_GOLD = { 0xfff0a0, 0xf5c842, 0xd99a1e, 0xa8650f }
local DRUM     = family(rampColors({ 0x2e2a26, 0x9e958a, 0xfff8ea }, 16))
local SHADOW   = family({ 0x0b0610 })
local PAYLINE  = family({ 0xff2a3a })
local FRAMEGLOW= family({ 0xe2b532 })
local RED      = family({ 0x5a0a10, 0xa3141f, 0xe02a34, 0xff7a7a })
local CHERRY   = family({ 0x4a0618, 0x8f0c2e, 0xd11a48, 0xff6f93 })
local GREEN    = family({ 0x0c3a12, 0x16702a, 0x2fb34a, 0x8ef08f })
local YELLOW   = family({ 0x6b5200, 0xc49b00, 0xf5d20f, 0xfff2a0 })
local GOLDS    = family({ 0x5c3a0c, 0xbf8a1b, 0xf2c33a, 0xfff0a0 })
local CYAN     = family({ 0x063a52, 0x0b7fa8, 0x2fd3f5, 0xc8f7ff })
local PURPLE   = family({ 0x2e0b52, 0x5a1aa0, 0x9147e6, 0xd7b2ff })
local BARK     = family({ 0x050505, 0x16161a, 0x2a2a32, 0x4a4a58 })
local OUTLINE  = family({ 0x140610 })
local WHITE    = family({ 0xffffff })
local BULB     = alloc(3)
local BULBLIT, BULBDIM = 0xfff3b0, 0x5a2e10
local LEDBG    = family({ 0x070102 })
local LEDOFF   = family({ 0x2c0606 })
local LEDON    = family({ 0xff3a24 })
local LEDGLOW  = family({ 0x6e0d08 })
local DIM      = family({ 0xb89c7c })
local MSG      = family({ 0xf5ead6 })
local CHROME   = family({ 0x3c3c46, 0x8c8c9c, 0xdedeee })
for k = 0, 2 do setPal(BULB + k, BULBDIM) end

---------------------------------------------------------------- framebuffer
local fb = {}
for y = 1, PH do
  local r = {}
  for x = 1, PW do r[x] = BG end
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
  x, y = math.floor(x), math.floor(y)
  if x < 0 then w = w + x x = 0 end
  if y < 0 then h = h + y y = 0 end
  if x + w > PW then w = PW - x end
  if y + h > PH then h = PH - y end
  if w <= 0 or h <= 0 then return end
  local rows = {}
  for j = 1, h do rows[j] = rowStr(fb[y + j], x + 1, x + w) end
  t.drawPixels(x, y, rows)
end

local canFreeze = type(t.setFrozen) == "function"
local function freeze(b) if canFreeze then pcall(t.setFrozen, b) end end

local function snapshot(x, y, w, h)
  local s = { x = x, y = y, w = w, h = h, rows = {} }
  for j = 1, h do
    local src, dst = fb[y + j], {}
    if src then for i = 1, w do dst[i] = src[x + i] end end
    s.rows[j] = dst
  end
  return s
end
local function restore(s)
  for j = 1, s.h do
    local dst, src = fb[s.y + j], s.rows[j]
    if dst then for i = 1, s.w do if src[i] then dst[s.x + i] = src[i] end end end
  end
end

---------------------------------------------------------------- drawing primitives
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

-- distance from the edge of a rounded rect (0 = outermost ring, negative = outside)
local function rrDist(px, py, x0, y0, x1, y1, r)
  local cx = clamp(px, x0 + r, x1 - r)
  local cy = clamp(py, y0 + r, y1 - r)
  local dx, dy = px - cx, py - cy
  if dx == 0 and dy == 0 then
    return math.min(px - x0, x1 - px, py - y0, y1 - py)
  end
  return r - math.sqrt(dx * dx + dy * dy)
end

local function panel(x0, y0, x1, y1, r, fill, border)
  for y = y0, y1 do
    local row = fb[y + 1]
    if row then
      for x = x0, x1 do
        if x >= 0 and x < PW then
          local d = rrDist(x, y, x0, y0, x1, y1, r)
          if d >= 0 then
            if d < 1 then row[x + 1] = OUTLINE
            elseif d < 2 then row[x + 1] = border
            else row[x + 1] = (type(fill) == "function") and fill(x, y) or fill end
          end
        end
      end
    end
  end
end

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

local function shade(base, a, b)
  local s = a + b
  if s < -0.75 then return base + 3
  elseif s < 0.15 then return base + 2
  elseif s < 0.95 then return base + 1 end
  return base
end
local function shade3(base, a, b)
  local s = a + b
  if s < -0.5 then return base + 2 elseif s < 0.6 then return base + 1 end
  return base
end

local function textW(s, sc) return (#s * 4 - 1) * sc end
-- col may be an index or function(localX, localY) -> index
local function text(x, y, s, sc, col, outline, outW, shadowOff)
  s = s:upper()
  local function pass(color, grow, dx, dy)
    for ci = 1, #s do
      local g = lib.font[s:sub(ci, ci)] or lib.font[" "]
      for gy = 1, 5 do
        local row = g[gy]
        for gx = 1, 3 do
          if row:sub(gx, gx) == "#" then
            local px = x + (ci - 1) * 4 * sc + (gx - 1) * sc + dx
            local py = y + (gy - 1) * sc + dy
            for yy = py - grow, py + sc - 1 + grow do
              for xx = px - grow, px + sc - 1 + grow do
                local c = color
                if type(c) == "function" then c = c(xx - x, yy - y) end
                put(xx, yy, c)
              end
            end
          end
        end
      end
    end
  end
  if shadowOff then pass(SHADOW, outW or 1, shadowOff, shadowOff) end
  if outline then pass(outline, outW or 1, 0, 0) end
  pass(col, 0, 0, 0)
end

---------------------------------------------------------------- symbol art
local function segDist(px, py, ax, ay, bx, by)
  local vx, vy = bx - ax, by - ay
  local wx, wy = px - ax, py - ay
  local tt = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy), 0, 1)
  local dx, dy = px - (ax + vx * tt), py - (ay + vy * tt)
  return math.sqrt(dx * dx + dy * dy)
end

local STARPTS = {}
for k = 0, 9 do
  local ang = -math.pi / 2 + k * math.pi / 5
  local r = (k % 2 == 0) and 0.95 or 0.42
  STARPTS[#STARPTS + 1] = { math.cos(ang) * r, math.sin(ang) * r + 0.06 }
end
local function inPoly(px, py, pts)
  local inside, j = false, #pts
  for i = 1, #pts do
    local xi, yi, xj, yj = pts[i][1], pts[i][2], pts[j][1], pts[j][2]
    if ((yi > py) ~= (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then inside = not inside end
    j = i
  end
  return inside
end

local function ball(u, v, cx, cy, r, base)
  local a, b = (u - cx) / r, (v - cy) / r
  if a * a + b * b <= 1 then
    if (a + 0.38) ^ 2 + (b + 0.42) ^ 2 < 0.05 then return WHITE end
    return shade(base, a, b)
  end
end

local SHAPES = {}
SHAPES.CHERRY = function(u, v)
  local c = ball(u, v, -0.38, 0.4, 0.36, CHERRY) or ball(u, v, 0.36, 0.48, 0.36, CHERRY)
  if c then return c end
  if segDist(u, v, -0.32, 0.08, 0.16, -0.7) < 0.07 or segDist(u, v, 0.34, 0.15, 0.16, -0.7) < 0.07 then
    return GREEN + 1
  end
  local lx, ly = u - 0.42, v + 0.6
  local ca, sa = math.cos(0.5), math.sin(0.5)
  local rx, ry = lx * ca + ly * sa, -lx * sa + ly * ca
  if (rx / 0.3) ^ 2 + (ry / 0.13) ^ 2 <= 1 then return shade(GREEN, rx / 0.3, ry / 0.13) end
end
SHAPES.LEMON = function(u, v)
  local a, b = u / 0.8, (v - 0.04) / 0.58
  local inBody = a * a + b * b <= 1
  local inNub = ((u - 0.8) ^ 2 + (v - 0.04) ^ 2 <= 0.017) or ((u + 0.8) ^ 2 + (v - 0.04) ^ 2 <= 0.017)
  if inBody or inNub then
    if (a + 0.4) ^ 2 + (b + 0.45) ^ 2 < 0.04 then return WHITE end
    return shade(YELLOW, a, b)
  end
end
SHAPES.BELL = function(u, v)
  if u * u + (v + 0.82) ^ 2 <= 0.012 then return GOLDS + 1 end
  if v <= -0.32 and u * u + (v + 0.32) ^ 2 <= 0.16 then
    if u > -0.2 and u < -0.1 then return GOLDS + 3 end
    return shade(GOLDS, u / 0.4, (v + 0.32) / 0.4)
  end
  if v > -0.32 and v <= 0.45 then
    local hw = 0.4 + 0.42 * ((v + 0.32) / 0.77) ^ 2
    if math.abs(u) <= hw then
      local k = u / hw
      if k > -0.55 and k < -0.32 then return GOLDS + 3 end
      return shade(GOLDS, k, (v - 0.05) / 0.6)
    end
  end
  if v > 0.45 and v <= 0.62 and math.abs(u) <= 0.86 then return GOLDS + 1 end
  if u * u + (v - 0.74) ^ 2 <= 0.022 then return GOLDS end
end
SHAPES.SEVEN = function(u, v)
  if v >= -0.8 and v <= -0.48 and u >= -0.62 and u <= 0.68 then return shade(RED, u, v * 2) end
  if segDist(u, v, 0.56, -0.62, -0.14, 0.84) < 0.19 then return shade(RED, u, v) end
end
SHAPES.STAR = function(u, v)
  if inPoly(u, v, STARPTS) then
    if u * u + (v - 0.06) ^ 2 < 0.04 then return PURPLE + 3 end
    return shade(PURPLE, u, v)
  end
end
SHAPES.DIAMOND = function(u, v)
  if (u + 0.35) ^ 2 + (v + 0.42) ^ 2 < 0.006 then return WHITE end
  if v >= -0.58 and v < -0.16 then
    local hw = 0.44 + (v + 0.58) / 0.42 * 0.46
    if math.abs(u) <= hw then
      if math.abs(u) < hw * 0.38 then return CYAN + 3 end
      return (u < 0) and CYAN + 2 or CYAN + 1
    end
  elseif v >= -0.16 and v <= 0.86 then
    local hw = 0.9 * (0.86 - v) / 1.02
    if math.abs(u) <= hw then
      local k = u / math.max(hw, 0.01)
      if k < -0.45 then return CYAN + 2 elseif k < 0 then return CYAN + 1 elseif k < 0.45 then return CYAN + 3 end
      return CYAN
    end
  end
end
SHAPES.BAR = function(u, v)
  local ax, ay = math.abs(u), math.abs(v)
  if ax > 0.92 or ay > 0.44 then return nil end
  local rc = 0.16
  if ax > 0.92 - rc and ay > 0.44 - rc and (ax - (0.92 - rc)) ^ 2 + (ay - (0.44 - rc)) ^ 2 > rc * rc then return nil end
  if ax > 0.8 or ay > 0.33 then return GOLDS + 2 end
  if ax <= 0.66 and ay <= 0.24 then
    local fx = math.floor((u + 0.66) / 1.32 * 11)
    local fy = math.floor((v + 0.24) / 0.48 * 5)
    local ci = math.floor(fx / 4) + 1
    local g = lib.font[("BAR"):sub(ci, ci)]
    local gx = fx % 4
    if g and gx < 3 and fy >= 0 and fy < 5 and g[fy + 1]:sub(gx + 1, gx + 1) == "#" then return WHITE end
  end
  return shade(BARK, u, v)
end

local function genSymbol(fn, S)
  local bmp = {}
  for py = 0, S - 1 do
    local row = {}
    for px = 0, S - 1 do
      local u = ((px + 0.5) / S * 2 - 1) * 1.08
      local v = ((py + 0.5) / S * 2 - 1) * 1.08
      row[px + 1] = fn(u, v) or false
    end
    bmp[py + 1] = row
  end
  local out = {}
  for py = 1, S do
    local row = {}
    for px = 1, S do
      local c = bmp[py][px]
      if not c then
        local n = (bmp[py - 1] and bmp[py - 1][px]) or (bmp[py + 1] and bmp[py + 1][px])
          or bmp[py][px - 1] or bmp[py][px + 1]
        if n then c = OUTLINE end
      end
      row[px] = c
    end
    out[py] = row
  end
  return out
end

---------------------------------------------------------------- layout
local m = math.max(2, math.floor(math.min(PW, PH) * 0.03))
local LVW = math.max(10, math.floor(PW * 0.09))
local CX0, CY0 = m, m
local CX1, CY1 = PW - m - LVW - 1, PH - m - 1
local CW, CH = CX1 - CX0 + 1, CY1 - CY0 + 1
local BZ = math.max(2, math.floor(math.min(CW, CH) * 0.03))
local RC = BZ * 3
local IX0, IY0, IX1, IY1 = CX0 + BZ, CY0 + BZ, CX1 - BZ, CY1 - BZ
local IW, IH = IX1 - IX0 + 1, IY1 - IY0 + 1
local pad = math.max(2, math.floor(math.min(IW, IH) * 0.03))

local MQX0, MQX1 = IX0 + pad, IX1 - pad
local MQY0 = IY0 + pad
local MQH = math.floor(IH * 0.21)
local MQY1 = MQY0 + MQH - 1

local RY0 = MQY1 + pad + 1
local RH = math.floor(IH * 0.49)
local RY1 = RY0 + RH - 1

local BPX0, BPX1 = MQX0, MQX1
local BPY0, BPY1 = RY1 + pad + 1, IY1 - pad
local BPW, BPH = BPX1 - BPX0 + 1, BPY1 - BPY0 + 1

-- reel windows
local bayW = MQX1 - MQX0 + 1
local GAP = math.max(2, math.floor(bayW * 0.025))
local FR = math.max(1, math.floor(GAP * 0.6))
local winW = math.floor((bayW - 4 * GAP) / 3)
local winH = RH - 2 * GAP
local reels = {}
for i = 1, 3 do
  local wx = MQX0 + GAP + (i - 1) * (winW + GAP)
  local wy = RY0 + GAP
  reels[i] = { fx = wx, fy = wy, x = wx + FR, y = wy + FR, w = winW - 2 * FR, h = winH - 2 * FR, pos = 1 }
end
local RW, RHH = reels[1].w, reels[1].h
local S = math.max(8, math.floor(math.min(RW * 0.62, RHH * 0.64)))
local P = S + math.max(2, math.floor(S * 0.12))
local PAYY = reels[1].y + math.floor(RHH / 2)

-- reel strips (each symbol at least once; common ones more often)
local STRIP_SET = { "DIAMOND", "SEVEN", "BELL", "BELL", "STAR", "STAR", "BAR", "BAR", "BAR",
  "LEMON", "LEMON", "LEMON", "CHERRY", "CHERRY", "CHERRY", "CHERRY" }
local STRIP = {}
for i = 1, 3 do
  local s = {}
  for k, v in ipairs(STRIP_SET) do s[k] = v end
  for k = #s, 2, -1 do local j = math.random(k) s[k], s[j] = s[j], s[k] end
  STRIP[i] = s
end

-- bottom panel
local lsc = math.max(1, math.floor(BPH / 18))
local labelH = 5 * lsc
local lp = math.max(1, math.floor(BPH * 0.06))
local labelY = BPY0 + 3 + lp
local ledY0 = labelY + labelH + lp + 1
-- digit scale: whatever fits between the label and the bottom of the panel
local dsc = math.max(1, math.floor(((BPY1 - 3 - lp) - ledY0 + 1 - lp * 2 - 4) / 5))
local function boxW(n, sc) return textW(string.rep("8", n), sc) + lp * 2 + 4 end
while dsc > 1 and boxW(7, dsc) + boxW(3, dsc) + lp * 8 > BPW * 0.7 do dsc = dsc - 1 end
local ledH = dsc * 5 + lp * 2 + 4
local credX0 = BPX0 + lp * 2 + 2
local credW = boxW(7, dsc)
local betW = boxW(3, dsc)
local betX0 = BPX1 - lp * 2 - 2 - betW + 1
local msgX0, msgX1 = credX0 + credW + lp * 2, betX0 - lp * 2 - 1
local msgY0, msgY1 = BPY0 + 3, BPY1 - 3

-- lever
local LV = {}
LV.x0 = CX1 + 1
LV.w = PW - LV.x0
LV.ballR = math.max(2, math.floor(LVW * 0.28))
LV.px = LV.x0 + math.max(LV.ballR + 2, math.floor(LV.w * 0.45))
LV.py = math.floor((RY0 + RY1) / 2)
LV.L = math.floor(CH * 0.3)
LV.rodT = math.max(1, math.floor(LV.ballR * 0.45))
LV.rest = 0.15
LV.a = LV.rest

-- coins
local CS = math.max(4, math.floor(math.min(PW, PH) / 26))

---------------------------------------------------------------- static scene
local tsBand, titleH
local leverBase, msgBase, credBase, betBase

local function titleColor(lx, ly)
  local r = clamp(math.floor(ly / titleH * SHINE_ROWS), 0, SHINE_ROWS - 1)
  local b = clamp(math.floor((lx + ly) / tsBand), 0, SHINE_BANDS - 1)
  return SHINE + r * SHINE_BANDS + b
end

local function buildScene()
  -- background gradient + stars
  for y = 0, PH - 1 do
    local c = BG + clamp(math.floor(y / PH * #BGCOLS), 0, #BGCOLS - 1)
    local row = fb[y + 1]
    for x = 1, PW do row[x] = c end
  end
  for _ = 1, math.floor(PW * PH / 350) do
    put(math.random(0, PW - 1), math.random(0, PH - 1), (math.random() < 0.5) and STARA or STARB)
  end
  maybeYield()

  -- cabinet: gold bevelled bezel + red body
  local ccx, ccy = (CX0 + CX1) / 2, (CY0 + CY1) / 2
  for y = CY0, CY1 do
    local row = fb[y + 1]
    for x = CX0, CX1 do
      local d = rrDist(x, y, CX0, CY0, CX1, CY1, RC)
      if d >= 0 then
        if d < 1 then
          row[x + 1] = OUTLINE
        elseif d < BZ then
          local tt = d / BZ
          local ridge = 1 - math.abs(tt - 0.3) * 1.8
          local light = (x - ccx) / CW + (y - ccy) / CH
          row[x + 1] = GOLD + clamp(math.floor((ridge - light * 0.35) * 7 + 0.5), 0, 7)
        else
          row[x + 1] = CAB + clamp(math.floor((y - IY0) / IH * 8), 0, 7)
        end
      end
    end
    maybeYield()
  end

  -- marquee panel + chasing bulbs
  panel(MQX0, MQY0, MQX1, MQY1, 3, PANEL2, GOLD + 5)
  local br = math.max(1, math.floor(MQH * 0.07))
  local ins = br + 3
  local ax0, ay0, ax1, ay1 = MQX0 + ins, MQY0 + ins, MQX1 - ins, MQY1 - ins
  local wE, hE = ax1 - ax0, ay1 - ay0
  local per = 2 * (wE + hE)
  local n = math.max(4, math.floor(per / (br * 3 + 2)))
  for i = 0, n - 1 do
    local d = i * per / n
    local bx, by
    if d < wE then bx, by = ax0 + d, ay0
    elseif d < wE + hE then bx, by = ax1, ay0 + (d - wE)
    elseif d < 2 * wE + hE then bx, by = ax1 - (d - wE - hE), ay1
    else bx, by = ax0, ay1 - (d - 2 * wE - hE) end
    bx, by = math.floor(bx + 0.5), math.floor(by + 0.5)
    disk(bx, by, br + 1, function() return OUTLINE end)
    local idx = BULB + (i % 3)
    disk(bx, by, br, function() return idx end)
    if br >= 2 then put(bx - 1, by - 1, WHITE) end
  end

  -- JACKPOT title with a sweeping shine
  local title = "JACKPOT"
  local areaW = (MQX1 - MQX0) - 2 * ins - 8
  local areaH = (MQY1 - MQY0) - 2 * ins - 4
  local ts = math.max(1, math.min(math.floor(areaW / 27), math.floor((areaH - 2) / 5)))
  titleH = 5 * ts
  local tw = textW(title, ts)
  tsBand = math.max(2, math.ceil((tw + titleH) / SHINE_BANDS))
  local titleX = math.floor((MQX0 + MQX1 - tw) / 2)
  local titleY = math.floor((MQY0 + MQY1 - titleH) / 2)
  text(titleX, titleY, title, ts, titleColor, OUTLINE, math.max(1, math.floor(ts / 3)), math.max(1, math.floor(ts / 2)))
  maybeYield()

  -- reel bay + window frames
  panel(MQX0, RY0, MQX1, RY1, 2, SHADOW, GOLD + 5)
  for i = 1, 3 do
    local R = reels[i]
    for y = R.fy, R.fy + winH - 1 do
      for x = R.fx, R.fx + winW - 1 do
        local edge = math.min(x - R.fx, R.fx + winW - 1 - x, y - R.fy, R.fy + winH - 1 - y)
        if edge < FR then put(x, y, (edge < 1) and OUTLINE or FRAMEGLOW) end
      end
    end
  end
  -- payline through the gaps, with arrow tips at both ends
  local pth = math.max(1, math.floor(RHH / 60))
  for x = MQX0 + 2, MQX1 - 2 do
    for k = 0, pth - 1 do
      local row = fb[PAYY + k + 1]
      if row then
        local c = row[x + 1]
        if c == SHADOW or c == GOLD + 5 then row[x + 1] = PAYLINE end
      end
    end
  end
  for k = 0, GAP - 2 do
    for dy = -(GAP - 1 - k), (GAP - 1 - k) do
      put(MQX0 + 1 + k, PAYY + dy, PAYLINE)
      put(MQX1 - 1 - k, PAYY + dy, PAYLINE)
    end
  end
  maybeYield()

  -- bottom panel: credits LED, message, bet LED
  panel(BPX0, BPY0, BPX1, BPY1, 3, PANEL, GOLD + 5)
  panel(credX0, ledY0, credX0 + credW - 1, ledY0 + ledH - 1, 1, LEDBG, GOLD + 2)
  panel(betX0, ledY0, betX0 + betW - 1, ledY0 + ledH - 1, 1, LEDBG, GOLD + 2)
  text(credX0 + 1, labelY, "CREDITS", lsc, DIM)
  text(betX0 + 1, labelY, "BET", lsc, DIM)

  -- lever mount plate
  local plateH = LV.ballR * 3
  local plateTop = LV.py - math.floor(plateH / 2)
  panel(CX1 - BZ, plateTop, LV.px + LV.rodT + 3, LV.py + math.floor(plateH / 2), 2,
    function(_, y) return GOLD + clamp(6 - math.floor((y - plateTop) / plateH * 5), 1, 6) end, GOLD + 7)

  local lvx = math.max(0, LV.px - math.ceil(LV.ballR * 1.4) - 4)
  leverBase = snapshot(lvx, 0, PW - lvx, PH)
  msgBase = snapshot(msgX0, msgY0, msgX1 - msgX0 + 1, msgY1 - msgY0 + 1)
  credBase = snapshot(credX0, ledY0, credW, ledH)
  betBase = snapshot(betX0, ledY0, betW, ledH)
end

---------------------------------------------------------------- dynamic parts
local BMP = {}
local BAYER = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }

local function renderReel(i)
  local R = reels[i]
  local x0, y0, w, h = R.x, R.y, R.w, R.h
  local half = h / 2
  -- curved drum background
  for yy = 0, h - 1 do
    local row = fb[y0 + yy + 1]
    local dist = math.abs(yy + 0.5 - half) / half
    local c = DRUM + clamp(math.floor(math.cos(dist * 1.25) * 15 + 0.5), 0, 15)
    for xx = 1, w do row[x0 + xx] = c end
  end

  -- symbols
  local strip = STRIP[i]
  local L = #strip
  local pos = R.pos
  local reach = math.ceil(half / P) + 2
  local base = math.floor(pos)
  local sx = math.floor((w - S) / 2)
  -- motion blur: dithered ghost copies trailing behind each symbol while the reel is fast
  local ghosts = 0
  if R.speed and R.speed > 25 then ghosts = 2 elseif R.speed and R.speed > 9 then ghosts = 1 end
  local function stamp(bmp, sy, parity)
    for j = 1, S do
      local yy = sy + j - 1
      if yy >= 0 and yy < h then
        local row, src = fb[y0 + yy + 1], bmp[j]
        for q = 1, S do
          local c = src[q]
          if c then
            local xx = sx + q - 1
            if xx >= 0 and xx < w and (not parity or (xx + yy) % 2 == parity) then
              row[x0 + xx + 1] = c
            end
          end
        end
      end
    end
  end
  for k = base - reach, base + reach do
    local bmp = BMP[strip[((k - 1) % L) + 1]]
    local cy = half - (k - pos) * P
    local sy = math.floor(cy - S / 2 + 0.5)
    for gIdx = ghosts, 1, -1 do
      stamp(bmp, sy - math.floor(gIdx * S * 0.4), gIdx % 2)
    end
    stamp(bmp, sy, nil)
  end

  -- drum curvature: dithered shadow toward top and bottom
  for yy = 0, h - 1 do
    local dist = math.abs(yy + 0.5 - half) / half
    if dist > 0.5 then
      local th = (dist - 0.5) / 0.5 * 17
      local row, brow = fb[y0 + yy + 1], BAYER[(yy % 4) + 1]
      for xx = 0, w - 1 do
        if brow[(xx % 4) + 1] < th then row[x0 + xx + 1] = SHADOW end
      end
    end
  end

  -- glowing box around a winning symbol (drawn over the shading so it stays crisp)
  if R.win then
    local th = math.max(1, math.floor(S / 14))
    local bx0, by0 = sx - th - 1, math.floor(half - S / 2) - th - 1
    local bx1, by1 = sx + S + th, math.floor(half + S / 2) + th
    for yy = by0, by1 do
      for xx = bx0, bx1 do
        if yy >= 0 and yy < h and xx >= 0 and xx < w then
          local e = math.min(xx - bx0, bx1 - xx, yy - by0, by1 - yy)
          if e < th then fb[y0 + yy + 1][x0 + xx + 1] = FRAMEGLOW end
        end
      end
    end
  end

  -- dashed payline across the glass
  local pth = math.max(1, math.floor(h / 60))
  for yy = math.floor(half), math.floor(half) + pth - 1 do
    local row = fb[y0 + yy + 1]
    for xx = 0, w - 1 do if xx % 3 ~= 2 then row[x0 + xx + 1] = PAYLINE end end
  end
end
local function pushReel(i) local R = reels[i] push(R.x, R.y, R.w, R.h) end

local function drawLED(snap, value, digits)
  restore(snap)
  local s = tostring(math.floor(value))
  if #s > digits then s = string.rep("9", digits) end
  s = string.rep(" ", digits - #s) .. s
  local tx, ty = snap.x + lp + 2, snap.y + lp + 2
  text(tx, ty, string.rep("8", digits), dsc, LEDOFF)
  text(tx, ty, s, dsc, LEDON, LEDGLOW, 1)
  push(snap.x, snap.y, snap.w, snap.h)
end

local msgKind = "info"
local function setMessage(s, kind)
  msgKind = kind or "info"
  local w, h = msgBase.w, msgBase.h
  if w < 4 or h < 5 then return end
  restore(msgBase)
  s = s:upper()
  local function fit(lines)
    local maxLen = 0
    for _, l in ipairs(lines) do maxLen = math.max(maxLen, #l) end
    return math.min(math.floor(h / (#lines * 6)), math.floor(w / (textW(string.rep("8", maxLen), 1) + 2)))
  end
  -- use two lines if that lets the text be bigger
  local lines = { s }
  local sc = fit(lines)
  local sp = s:find(" ")
  if sp then
    local two = { s:sub(1, sp - 1), s:sub(sp + 1) }
    local sc2 = fit(two)
    if sc2 > sc then lines, sc = two, sc2 end
  end
  sc = math.max(1, sc)
  local maxChars = math.max(1, math.floor((w + 1) / (4 * sc)))
  local blockH = #lines * 5 * sc + (#lines - 1) * sc
  local y = msgBase.y + math.floor((h - blockH) / 2)
  for _, l in ipairs(lines) do
    if #l > maxChars then l = l:sub(1, maxChars) end
    local x = msgBase.x + math.floor((w - textW(l, sc)) / 2)
    text(x, y, l, sc, MSG, OUTLINE, math.max(1, math.floor(sc / 3)))
    y = y + 6 * sc
  end
  push(msgBase.x, msgBase.y, w, h)
end

local function drawLever()
  restore(leverBase)
  local a = LV.a
  local ey = LV.py - LV.L * math.cos(a)
  for y = math.floor(math.min(LV.py, ey)), math.floor(math.max(LV.py, ey)) do
    for dx = -LV.rodT, LV.rodT do
      local c = (dx < -LV.rodT / 3) and CHROME + 2 or ((dx > LV.rodT / 3) and CHROME or CHROME + 1)
      put(LV.px + dx, y, c)
    end
  end
  disk(LV.px, LV.py, LV.rodT + 3, function() return OUTLINE end)
  disk(LV.px, LV.py, LV.rodT + 2, function(u, v) return shade3(CHROME, u, v) end)
  local br = LV.ballR * (1 + 0.3 * math.sin(a))
  disk(LV.px, ey, br + 1, function() return OUTLINE end)
  disk(LV.px, ey, br, function(u, v)
    if (u + 0.35) ^ 2 + (v + 0.4) ^ 2 < 0.06 then return WHITE end
    return shade(RED, u, v)
  end)
  push(leverBase.x, leverBase.y, leverBase.w, leverBase.h)
end

---------------------------------------------------------------- coins
local coinSprites = {}
for k, fw in ipairs({ 1, 0.66, 0.22, 0.66 }) do
  local spr, r = {}, CS / 2
  for j = 1, CS do
    local row = {}
    for q = 1, CS do
      local a = (q - 0.5 - r) / (r * fw)
      local b = (j - 0.5 - r) / r
      local d = a * a + b * b
      if d <= 1 then
        if fw < 0.4 or d > 0.62 then row[q] = GOLDS + 1
        elseif (a + 0.35) ^ 2 + (b + 0.35) ^ 2 < 0.06 then row[q] = WHITE
        else row[q] = shade(GOLDS, a, b) end
      else
        row[q] = false
      end
    end
    spr[j] = row
  end
  coinSprites[k] = spr
end

local coins = {}
local showerUntil, showerRate = 0, 0

local function drawCoin(cn)
  local x, y = math.floor(cn.x), math.floor(cn.y)
  local spr = coinSprites[(cn.f % 4) + 1]
  local xa, xb = math.max(0, x), math.min(PW - 1, x + CS - 1)
  cn.px, cn.py = x, y
  if xa > xb then return end
  local rows, firstY = {}, nil
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

local function updateCoins(tm)
  if #coins == 0 and tm > showerUntil then return end
  for _, cn in ipairs(coins) do
    if cn.px then push(cn.px, cn.py, CS, CS) end
  end
  if tm < showerUntil then
    for _ = 1, showerRate do
      if #coins < 45 then
        coins[#coins + 1] = { x = math.random(0, PW - CS), y = -CS - math.random(0, math.floor(PH / 4)),
          vx = (math.random() - 0.5) * 1.5, vy = math.random() * 2, f = math.random(0, 3) }
      end
    end
    if math.random() < 0.3 then beep("minecraft:entity.experience_orb.pickup", 0.8 + math.random() * 0.8, 1) end
  end
  for k = #coins, 1, -1 do
    local cn = coins[k]
    cn.vy = cn.vy + PH * 0.004
    cn.x, cn.y = cn.x + cn.vx, cn.y + cn.vy
    cn.f = cn.f + 1
    if cn.y > PH then table.remove(coins, k) end
  end
  for _, cn in ipairs(coins) do drawCoin(cn) end
end

---------------------------------------------------------------- palette animation
local shinePhase = 0
local winLevel, winT = 0, -100
local bgPulsed = false
local state = "idle"

local function updateShine(speed)
  shinePhase = shinePhase + speed
  local span = SHINE_BANDS + 10
  local p = shinePhase % span - 3
  for r = 0, SHINE_ROWS - 1 do
    local base = TITLE_GOLD[r + 1]
    for b = 0, SHINE_BANDS - 1 do
      local d = math.abs(b - p)
      local g = (d < 0.75) and 0.9 or ((d < 1.75) and 0.45 or 0)
      setPal(SHINE + r * SHINE_BANDS + b, mix(base, 0xffffff, g))
    end
  end
end

local function updatePalettes(tm)
  local winning = winLevel >= 1 and tm - winT < 5
  local jackpot = winLevel >= 3 and tm - winT < 6

  updateShine((state == "spinning" or winning) and 0.7 or 0.25)

  if jackpot then
    for k = 0, 2 do setPal(BULB + k, toHex(lib.hsv(tm * 1.5 + k / 3, 0.7, 1))) end
  elseif winning then
    local on = math.floor(tm * 8) % 2 == 0
    for k = 0, 2 do setPal(BULB + k, on and BULBLIT or BULBDIM) end
  else
    local ph = math.floor(tm * ((state == "spinning") and 16 or 6)) % 3
    for k = 0, 2 do setPal(BULB + k, (k == ph) and BULBLIT or BULBDIM) end
  end

  local s = 0.5 + 0.5 * math.sin(tm * 2.2)
  setPal(STARA, mix(0x4a3a6a, 0xffffff, s))
  setPal(STARB, mix(0x4a3a6a, 0xffffff, 1 - s))

  if winning then
    local p = 0.5 + 0.5 * math.sin(tm * 14)
    setPal(PAYLINE, mix(0xff2a3a, 0xfff2a0, p))
    setPal(FRAMEGLOW, mix(0xe2b532, 0xffffff, p))
  else
    setPal(PAYLINE, 0xff2a3a)
    setPal(FRAMEGLOW, 0xe2b532)
  end

  if msgKind == "jackpot" then setPal(MSG, toHex(lib.hsv(tm * 0.8, 0.75, 1)))
  elseif msgKind == "win" then setPal(MSG, mix(0xffc83a, 0xffffff, 0.5 + 0.5 * math.sin(tm * 10)))
  elseif msgKind == "good" then setPal(MSG, mix(0x3aff6a, 0xd0ffd8, 0.5 + 0.5 * math.sin(tm * 8)))
  elseif msgKind == "bad" then setPal(MSG, mix(0xff3030, 0x801010, 0.5 + 0.5 * math.sin(tm * 8)))
  else setPal(MSG, 0xf5ead6) end

  if jackpot then
    local p = 0.5 + 0.5 * math.sin(tm * 9)
    for k = 1, #BGCOLS do setPal(BG + k - 1, mix(BGCOLS[k], 0x6a1a8a, p * 0.45)) end
    bgPulsed = true
  elseif bgPulsed then
    for k = 1, #BGCOLS do setPal(BG + k - 1, BGCOLS[k]) end
    bgPulsed = false
  end
end

---------------------------------------------------------------- game
local credits = 500
local function loadCredits()
  if fs.exists(SAVE) then
    local f = fs.open(SAVE, "r")
    credits = tonumber(f.readLine()) or 500
    f.close()
  end
end
local function saveCredits()
  local f = fs.open(SAVE, "w")
  f.write(tostring(credits))
  f.close()
end

local chatStyle
local function announce(msg)
  if not chat then return end
  local json = textutils.serializeJSON({ { text = "" }, { text = msg, color = "gold", bold = true } })
  local order = (chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res = pcall(function()
      if style == "new" then return chat.sendFormattedMessage(json, { prefix = "SLOTS", brackets = "[]", bracketColor = "&6" })
      else return chat.sendFormattedMessage(json, "SLOTS", "[]", "&6") end
    end)
    if ok and res then chatStyle = style return end
  end
  pcall(chat.sendMessage, msg, "SLOTS")
end

local spinStart = -100
local lastTick = 0

local function startSpin()
  if state == "spinning" then return end
  if credits < BET then
    setMessage("NOT ENOUGH CREDITS", "bad")
    beep("minecraft:entity.villager.no", 1)
    return
  end
  credits = credits - BET
  saveCredits()
  drawLED(credBase, credits, 7)
  state = "spinning"
  spinStart = now()
  winLevel = 0
  for i = 1, 3 do
    local R = reels[i]
    local strip = STRIP[i]
    local L = #strip
    local sym = rollSymbol()
    local opts = {}
    for k, s in ipairs(strip) do if s == sym then opts[#opts + 1] = k end end
    local target = opts[math.random(#opts)]
    local cur = math.floor(R.pos + 0.5)
    local curIdx = ((cur - 1) % L) + 1
    R.from = cur
    R.dist = ((target - curIdx) % L) + L * (2 + i)
    R.dur = 1.0 + 0.55 * i
    R.result = sym
    R.stopped = false
    R.win = false
  end
  setMessage("GOOD LUCK", "info")
  beep("minecraft:block.lever.click", 0.8)
end

local OVER, SETTLE = 0.22, 0.18
local function updateReel(i, tm)
  local R = reels[i]
  if R.stopped then return false end
  local e = tm - spinStart
  if e >= R.dur + SETTLE then
    R.pos = ((R.from + R.dist - 1) % #STRIP[i]) + 1
    R.stopped = true
    R.speed = 0
    beep("minecraft:block.note_block.basedrum", 0.9 + i * 0.1)
  elseif e >= R.dur then
    local y = (e - R.dur) / SETTLE
    R.pos = R.from + R.dist + OVER * (1 - y) * (1 - y)
    R.speed = 0
  else
    local x = e / R.dur
    R.pos = R.from + (R.dist + OVER) * (1 - (1 - x) ^ 3)
    R.speed = (R.dist + OVER) * 3 * (1 - x) ^ 2 / R.dur
  end
  return true
end

local function finishSpin(tm)
  state = "idle"
  local a, b, c = reels[1].result, reels[2].result, reels[3].result
  local payout = 0
  if a == b and b == c then
    payout = BET * MULT[a]
    for i = 1, 3 do reels[i].win = true end
    if MULT[a] >= 20 then
      winLevel = 3
      setMessage("JACKPOT +" .. payout, "jackpot")
      beep("minecraft:ui.toast.challenge_complete", 1, 3)
      showerUntil, showerRate = tm + 4, 3
      announce("someone hit a " .. a .. " JACKPOT on the slots! +" .. lib.commas(payout) .. " credits")
    else
      winLevel = 2
      setMessage("BIG WIN +" .. payout, "win")
      beep("minecraft:entity.player.levelup", 1)
      showerUntil, showerRate = tm + 1.5, 1
    end
  elseif a == b or b == c or a == c then
    payout = BET * 2
    winLevel = 1
    if a == b then reels[1].win, reels[2].win = true, true end
    if b == c then reels[2].win, reels[3].win = true, true end
    if a == c then reels[1].win, reels[3].win = true, true end
    setMessage("PAIR +" .. payout, "good")
    beep("minecraft:entity.experience_orb.pickup", 1.2)
  else
    winLevel = 0
    setMessage("NO MATCH", "info")
    beep("minecraft:block.dispenser.fail", 1)
  end
  winT = tm
  for i = 1, 3 do renderReel(i) pushReel(i) end
  if payout > 0 then
    credits = credits + payout
    saveCredits()
    drawLED(credBase, credits, 7)
  end
end

local leverDrawnA = nil
local function updateLever(tm)
  local e = tm - spinStart
  local target, top = LV.rest, 2.9
  if e >= 0 and e < 0.25 then target = LV.rest + (top - LV.rest) * (e / 0.25)
  elseif e >= 0.25 and e < 0.65 then target = top - (top - LV.rest) * ((e - 0.25) / 0.4)
  end
  LV.a = target
  if leverDrawnA ~= LV.a then
    drawLever()
    leverDrawnA = LV.a
  end
end

local function tick()
  local tm = now()
  freeze(true)
  updatePalettes(tm)
  if state == "spinning" then
    local moving = false
    for i = 1, 3 do
      if updateReel(i, tm) then renderReel(i) pushReel(i) end
      if not reels[i].stopped then moving = true end
    end
    if moving and tm - lastTick > 0.09 then
      beep("minecraft:block.note_block.hat", 1.4, 1)
      lastTick = tm
    end
    if not moving then finishSpin(tm) end
  end
  updateLever(tm)
  updateCoins(tm)
  freeze(false)
end

---------------------------------------------------------------- run
loadCredits()
for _, s in ipairs(SYMBOLS) do BMP[s[1]] = genSymbol(SHAPES[s[1]], S) end
buildScene()
updateShine(0)
for i = 1, 3 do reels[i].pos = math.random(#STRIP[i]) renderReel(i) end
push(0, 0, PW, PH)
drawLED(credBase, credits, 7)
drawLED(betBase, BET, 3)
setMessage(isMon and "TAP TO PULL" or "SPACE TO PULL", "info")
drawLever()
leverDrawnA = LV.a

local monName = isMon and peripheral.getName(t) or nil
local ok, err = pcall(function()
  local timer = os.startTimer(0.05)
  while true do
    local e, a = os.pullEvent()
    if e == "timer" and a == timer then
      tick()
      timer = os.startTimer(0.05)
    elseif e == "monitor_touch" and a == monName then
      startSpin()
    elseif e == "mouse_click" and not isMon then
      startSpin()
    elseif e == "key" then
      if a == keys.space or a == keys.enter then startSpin()
      elseif a == keys.q then break end
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
print("cashed out with " .. lib.commas(credits) .. " credits.")
