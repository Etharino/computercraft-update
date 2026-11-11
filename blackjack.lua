-- blackjack.lua :: chunky cartoon blackjack for CC: Graphics (256-colour graphics mode).
--   blue checkerboard table, thick-outlined cards, deal + flip animations, pop-up results.
--   rules: 6-deck shoe, dealer peeks for blackjack, dealer stands on soft 17, blackjack pays 3:2,
--   double on any first two cards, split pairs (up to 4 hands, split aces get one card).
--
-- works on an advanced computer or any advanced monitor; the layout adapts to the shape.
-- controls: tap/click chips to bet, DEAL, then HIT / STAND / DOUBLE / SPLIT.
--   keyboard: 1-4 = chips, c = clear, enter = deal / rebet, n = new bet,
--             h = hit, s = stand, d = double, p = split, q = quit
-- needs: ccgraphics. optional: speaker, chat box. credits are shared with slots/roulette/stocks.

local lib = require("auralib")
math.randomseed(os.epoch("utc"))
lib.font["/"] = { "..#", "..#", ".#.", "#..", "#.." }

-- all state in G, palette in C: ComputerCraft's Lua rejects functions with more than 60
-- upvalues and scopes with more than 200 locals, so locals are kept few.
local G = { bet = 0, hands = {}, dealer = { cards = {} }, coins = {}, showerUntil = 0, phase = "bet",
  msg = "PLACE YOUR BET", lastBet = 0, buttons = {} }
local C = {}
local CHIPS = { 10, 50, 100, 500 }
local SAVE = "slots.db"
local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

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
local function toHex(r, g, b)
  return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5)
end
G.nextIdx = 16
local function family(list)
  local base = G.nextIdx
  for k, c in ipairs(list) do setPal(base + k - 1, c) end
  G.nextIdx = G.nextIdx + #list
  return base
end
C.BG1     = family({ 0x5aa6f4 })
C.BG2     = family({ 0x4a94ea })
C.BAR     = family({ 0x2a62c0, 0x3a76d6 })
C.OUTLINE = family({ 0x141a3c })
C.WHITE   = family({ 0xffffff })
C.SHADE   = family({ 0xdce6f4 })
C.SHADOW  = family({ 0x2f6ac8 })
C.REDS    = family({ 0x9a1424, 0xe23040, 0xff7a84 })
C.BLKS    = family({ 0x0e1230, 0x1e2448, 0x56608a })
C.BACK    = family({ 0xa81c28, 0xd8343c, 0xf06068 })
C.GOLD    = family({ 0x8a5a08, 0xd8a018, 0xffd23a, 0xfff2a0 })
C.DIM     = family({ 0xc8dcff })
C.MSG     = family({ 0xffffff })
C.GLOW    = family({ 0xffe060 })
C.BANNER  = family({ 0xffd23a })
C.PILL    = family({ 0x1c2456 })
C.GREEN   = family({ 0x168a36, 0x30c050, 0x8af0a0 })
C.RED     = family({ 0xa01828, 0xe03644, 0xff8a94 })
C.ORANGE  = family({ 0xb06008, 0xf09a20, 0xffd080 })
C.PURPLE  = family({ 0x5a2a9a, 0x8a4ad8, 0xc8a0ff })
C.BLUE    = family({ 0x1c4aa0, 0x2e6ee0, 0x8ab8ff })
C.GREY    = family({ 0x4a5270, 0x6a7290, 0x9aa2c0 })
C.CHIPC   = {
  family({ 0x0a2a6a, 0x2a5ad0, 0x7aa8ff }),
  family({ 0x5a0a0a, 0xc02020, 0xff7070 }),
  family({ 0x0a3a14, 0x22a040, 0x80f090 }),
  family({ 0x101014, 0x34343c, 0x8a8a96 }),
}

---------------------------------------------------------------- framebuffer + helpers
local fb = {}
for y = 1, PH do local r = {} for x = 1, PW do r[x] = C.BG1 end fb[y] = r end
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
local function pushAll() push(0, 0, PW, PH) end
local function freeze(b) if type(t.setFrozen) == "function" then pcall(t.setFrozen, b) end end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

-- copy / restore rectangles (used to animate things over the composed scene)
local function grab(x, y, w, h)
  local s = { x = math.floor(x), y = math.floor(y), w = math.ceil(w), h = math.ceil(h), rows = {} }
  for j = 1, s.h do
    local src, dst = fb[s.y + j], {}
    if src then for i = 1, s.w do dst[i] = src[s.x + i] end end
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

-- rounded rectangle; fn(localX, localY, distFromEdge) -> colour or nil.
-- distance math is inlined (only corner pixels need a square root): this runs for every
-- pixel of every card and button, so it has to be cheap.
local function rrect(x, y, w, h, r, fn)
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  r = math.min(r, math.floor(math.min(w, h) / 2))
  local sqrt, x1, y1 = math.sqrt, w - 1, h - 1
  for yy = 0, y1 do
    local row = fb[y + yy + 1]
    if row then
      local dyE = (yy < y1 - yy) and yy or (y1 - yy)
      local cy = (yy < r) and (r - yy) or ((yy > y1 - r) and (yy - (y1 - r)) or 0)
      for xx = 0, x1 do
        local px = x + xx
        if px >= 0 and px < PW then
          local cx = (xx < r) and (r - xx) or ((xx > x1 - r) and (xx - (x1 - r)) or 0)
          local d
          if cx > 0 and cy > 0 then
            d = r - sqrt(cx * cx + cy * cy)
          else
            local dxE = (xx < x1 - xx) and xx or (x1 - xx)
            d = (dxE < dyE) and dxE or dyE
          end
          if d >= 0 then
            local c = fn(xx, yy, d)
            if c then row[px + 1] = c end
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
      if a * a + b * b <= 1 then local c = fn(a, b) if c then put(x, y, c) end end
    end
  end
end
local function textW(s, sc) return (#s * 4 - 1) * sc end
-- chunky text: optional outline (grow px) and drop shadow; flip = rotate 180 degrees
local function text(x, y, s, sc, col, outline, grow, shadow, flip)
  s = s:upper()
  local n = #s
  local passes = {}
  if shadow then passes[#passes + 1] = { outline or C.OUTLINE, grow or 1, shadow } end
  if outline then passes[#passes + 1] = { outline, grow or 1, 0 } end
  passes[#passes + 1] = { col, 0, 0 }
  for _, pass in ipairs(passes) do
    local color, gr, off = pass[1], pass[2], pass[3]
    for ci = 1, n do
      local g = lib.font[s:sub(ci, ci)] or lib.font[" "]
      for gy = 1, 5 do
        local row = g[gy]
        for gx = 1, 3 do
          if row:sub(gx, gx) == "#" then
            local px, py
            if flip then px, py = x + (n - ci) * 4 * sc + (3 - gx) * sc, y + (5 - gy) * sc
            else px, py = x + (ci - 1) * 4 * sc + (gx - 1) * sc, y + (gy - 1) * sc end
            for yy = py - gr + off, py + sc - 1 + gr + off do
              for xx = px - gr + off, px + sc - 1 + gr + off do put(xx, yy, color) end
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

---------------------------------------------------------------- cards
local function cardValue(c) return math.min(10, c.r) end
local function handValue(cards, onlyUp)
  local sum, aces = 0, 0
  for _, c in ipairs(cards) do
    if c.up or not onlyUp then
      sum = sum + cardValue(c)
      if c.r == 1 then aces = aces + 1 end
    end
  end
  if aces > 0 and sum + 10 <= 21 then return sum + 10, true end
  return sum, false
end
local function isBJ(cards) return #cards == 2 and handValue(cards) == 21 end
local function totalLabel(cards, onlyUp)
  local v, soft = handValue(cards, onlyUp)
  if v > 21 then return "BUST" end
  if #cards == 2 and v == 21 and not onlyUp then return "BJ!" end
  if soft and v < 21 then return (v - 10) .. "/" .. v end
  return tostring(v)
end

local function newShoe()
  G.shoe = {}
  for _ = 1, 6 do
    for s = 1, 4 do for r = 1, 13 do G.shoe[#G.shoe + 1] = { r = r, s = s } end end
  end
  for k = #G.shoe, 2, -1 do local j = math.random(k) G.shoe[k], G.shoe[j] = G.shoe[j], G.shoe[k] end
end
local function drawCardFromShoe()
  if CC_SIM and CC_SIM.deck and #CC_SIM.deck > 0 then   -- test harness can stack the deck
    local c = table.remove(CC_SIM.deck, 1)
    return { r = c[1], s = c[2] }
  end
  if #G.shoe == 0 then newShoe() end
  local c = table.remove(G.shoe)
  return { r = c.r, s = c.s }
end

-- suit shapes on u,v in [-1,1]; suits: 1 hearts, 2 diamonds, 3 spades, 4 clubs
local function heartAt(x, y) return (x * x + y * y - 1) ^ 3 - x * x * y * y * y <= 0 end
local function stemAt(u, v, top) return v >= top and v <= 0.98 and math.abs(u) <= (v - top) / (0.98 - top) * 0.34 + 0.05 end
local SUITFN = {
  function(u, v) return heartAt(u * 1.22, -v * 1.22 + 0.22) end,
  function(u, v) return math.abs(u) / 0.74 + math.abs(v) / 0.98 <= 1 end,
  function(u, v) return heartAt(u * 1.28, v * 1.28 + 0.2) and v < 0.62 or stemAt(u, v, 0.3) end,
  function(u, v)
    local function c(cx, cy, r) return (u - cx) ^ 2 + (v - cy) ^ 2 <= r * r end
    return c(0, -0.44, 0.34) or c(-0.42, 0.1, 0.34) or c(0.42, 0.1, 0.34) or c(0, -0.05, 0.2) or stemAt(u, v, 0.15)
  end,
}
local function suitFam(s) return (s <= 2) and C.REDS or C.BLKS end
local function genSuit(s, size)
  local bmp, fam = {}, suitFam(s)
  for py = 0, size - 1 do
    local row = {}
    for px = 0, size - 1 do
      local u, v = (px + 0.5) / size * 2 - 1, (py + 0.5) / size * 2 - 1
      if SUITFN[s](u, v) then
        local k = u + v
        row[px + 1] = (k < -0.85) and fam + 2 or ((k > 1.0) and fam or fam + 1)
      else
        row[px + 1] = false
      end
    end
    bmp[py + 1] = row
  end
  return bmp
end
local function blit(bmp, x, y, flip)
  local n = #bmp
  for j = 1, n do
    local row = bmp[flip and (n - j + 1) or j]
    local m = #row
    for i = 1, m do
      local c = row[flip and (m - i + 1) or i]
      if c then put(x + i - 1, y + j - 1, c) end
    end
  end
end

-- draw one card at (x, y). squash in (0,1] narrows it for the flip animation.
local function drawCard(card, x, y, faceUp, squash)
  local w, h = G.cardW, G.cardH
  local sw = squash and math.max(2, math.floor(w * squash + 0.5)) or w
  local sx = math.floor(x + (w - sw) / 2)
  local ot, r = G.ot, G.cr
  local sh = math.max(2, math.floor(w / 16))
  rrect(sx + sh, y + sh, sw, h, r, function() return C.SHADOW end)
  if faceUp then
    rrect(sx, y, sw, h, r, function(_, yy, d)
      if d < ot then return C.OUTLINE end
      return (yy > h * 0.84) and C.SHADE or C.WHITE
    end)
    if sw < w * 0.85 then return end
    local fam = suitFam(card.s)
    local label = RANKS[card.r]
    local rs = G.rsc
    local lx, ly = x + ot + 2, y + ot + 2
    text(lx, ly, label, rs, fam + 1)
    local small = G.small[card.s]
    if G.cardH >= 40 then blit(small, lx, ly + 5 * rs + 2) end
    local rw = textW(label, rs)
    -- bottom corner rank stays upright: a rotated "10" or "9" reads wrong in a pixel font
    text(x + w - ot - 2 - rw, y + h - ot - 2 - 5 * rs, label, rs, fam + 1)
    if G.cardH >= 40 then blit(small, x + w - ot - 2 - #small, y + h - ot - 2 - 5 * rs - 2 - #small, true) end
    if card.r >= 11 then
      local bs = math.max(1, math.floor(G.bigS / 5))
      text(x + math.floor((w - textW(label, bs)) / 2), y + math.floor((h - 5 * bs) / 2), label, bs, fam + 1, C.OUTLINE, 1)
    else
      local big = G.big[card.s]
      blit(big, x + math.floor((w - #big) / 2), y + math.floor((h - #big) / 2))
    end
  else
    local k = math.max(4, math.floor(w / 6))
    local band = ot + math.max(1, math.floor(w / 16))
    rrect(sx, y, sw, h, r, function(xx, yy, d)
      if d < ot then return C.OUTLINE end
      if d < band then return C.WHITE end
      if d < band + 1 then return C.BACK end
      if (xx + yy) % k == 0 or (xx - yy) % k == 0 then return C.BACK end
      return ((xx + yy) % k < k / 2) and C.BACK + 2 or C.BACK + 1
    end)
  end
end

---------------------------------------------------------------- layout
local function computeLayout()
  local m = math.max(3, math.floor(math.min(PW, PH) * 0.02))
  G.m = m
  G.barH = math.max(13, math.floor(math.min(PW, PH) * 0.085))
  if PW >= PH * 1.15 then
    G.land = true
    local pw = math.floor(PW * 0.3)
    G.table = { x = m, y = G.barH + m, w = PW - pw - 3 * m, h = PH - G.barH - 2 * m }
    G.panel = { x = PW - pw - m, y = G.barH + m, w = pw, h = PH - G.barH - 2 * m }
    G.info = { x = G.panel.x, y = G.panel.y, w = pw, h = math.floor(G.panel.h * 0.3) }
  else
    G.land = false
    local ch = math.floor(PH * 0.26)
    G.table = { x = m, y = G.barH + m, w = PW - 2 * m, h = PH - G.barH - ch - 3 * m }
    G.panel = { x = m, y = PH - ch - m, w = PW - 2 * m, h = ch }
    G.info = { x = G.panel.x, y = G.panel.y, w = G.panel.w, h = math.floor(ch * 0.3) }
  end
  G.btnArea = { x = G.panel.x, y = G.info.y + G.info.h + m, w = G.panel.w, h = G.panel.h - G.info.h - m }
  local T = G.table
  local zoneH = math.floor(T.h / 2)
  G.bubH = math.max(9, math.floor(zoneH * 0.15))
  G.cardH = math.max(24, math.min(math.floor((zoneH - G.bubH - 8) * 0.96), math.floor(T.w * 0.21 * 1.4)))
  G.cardW = math.floor(G.cardH * 0.71)
  G.ot = math.max(1, math.floor(G.cardW / 22))
  G.rsc = math.max(1, math.floor(G.cardW / 26))
  G.bigS = math.floor(G.cardW * 0.56)
  G.cr = math.max(2, math.floor(G.cardW * 0.13))
  G.shoeX, G.shoeY = T.x + T.w - G.cardW - m, T.y + 2
  G.dealerZone = { x = T.x, y = T.y, w = T.w - G.cardW - 2 * m, h = zoneH }
  G.playerZone = { x = T.x, y = T.y + zoneH, w = T.w, h = T.h - zoneH }
  G.small, G.big = {}, {}
  for s = 1, 4 do G.small[s] = genSuit(s, 5 * G.rsc + 1) G.big[s] = genSuit(s, G.bigS) end
end

-- where the cards of a hand go; zone is split when there are several player hands
local function handZone(which)
  if which == 0 then return G.dealerZone end
  local P, n = G.playerZone, math.max(1, #G.hands)
  local w = math.floor(P.w / n)
  return { x = P.x + (which - 1) * w, y = P.y, w = w, h = P.h }
end
local function cardSlots(n, zone)
  local s = math.floor(G.cardW * 0.6)
  if n > 1 then s = math.min(s, math.floor((zone.w - G.cardW - 4) / (n - 1))) end
  local total = G.cardW + (n - 1) * s
  local x0 = zone.x + math.floor((zone.w - total) / 2)
  local y = zone.y + G.bubH + 5 + math.floor((zone.h - G.bubH - 5 - G.cardH - G.cardH * 0.06) / 2)
  local out = {}
  for i = 1, n do out[i] = { x = x0 + (i - 1) * s, y = y } end
  return out
end

---------------------------------------------------------------- scene
local function buildBackground()
  local S = math.max(8, math.floor(math.min(PW, PH) / 9))
  G.bg = {}
  for y = 0, PH - 1 do
    local row = {}
    for x = 0, PW - 1 do
      row[x + 1] = ((math.floor(x / S) + math.floor(y / S)) % 2 == 0) and C.BG1 or C.BG2
    end
    G.bg[y + 1] = row
  end
  for y = 0, G.barH - 1 do
    for x = 0, PW - 1 do G.bg[y + 1][x + 1] = (y == G.barH - 1) and C.OUTLINE or ((y < G.barH / 2) and C.BAR + 1 or C.BAR) end
  end
end

local function pill(cx, y, label, fill)
  local sc = math.max(1, math.floor((G.bubH - 3) / 5))
  local w = textW(label, sc) + 8
  local x = math.floor(cx - w / 2)
  rrect(x, y, w, G.bubH, math.floor(G.bubH / 2), function(_, _, d)
    if d < 1 then return C.OUTLINE end
    return fill
  end)
  text(x + 4, y + math.floor((G.bubH - 5 * sc) / 2), label, sc, C.WHITE)
end

local RESULT_FILL = { WIN = C.GREEN + 1, BJ = C.GOLD + 1, PUSH = C.GREY + 1, LOSE = C.RED, BUST = C.RED }

local function drawHand(cards, zone, isDealer, hand, idx)
  local slots = cardSlots(math.max(1, #cards), zone)
  for i, c in ipairs(cards) do
    if not c.anim and not c.flipping then drawCard(c, slots[i].x, slots[i].y, c.up) end
  end
  if #cards > 0 then
    local cx = slots[1].x + (slots[#cards].x - slots[1].x + G.cardW) / 2
    local by = slots[1].y - G.bubH - 3
    local landed = {}
    for _, c in ipairs(cards) do if not c.anim then landed[#landed + 1] = c end end
    local label = totalLabel(landed, isDealer)
    local fill = C.PILL
    if hand and hand.result then
      label = (hand.result == "BJ") and "BLACKJACK" or hand.result
      fill = RESULT_FILL[hand.result]
    elseif label == "BUST" then fill = C.RED end
    pill(cx, by, label, fill)
    if hand and G.activeHand == idx and G.phase ~= "result" then
      -- arrow under the hand that's being played
      local ay = slots[1].y + G.cardH + 3
      local ah = math.max(3, math.floor(G.cardH * 0.08))
      for k = 0, ah - 1 do
        for dx = -k, k do put(math.floor(cx + dx), ay + k, C.GLOW) end
      end
    end
  end
end

local function drawChip(cx, cy, r, fam, label)
  disk(cx + 1, cy + 2, r, function() return C.OUTLINE end)
  disk(cx, cy, r + 0.6, function() return C.OUTLINE end)
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
  if label then
    local sc = math.max(1, math.floor(r / 6))
    if r * 2 - 4 >= textW(label, sc) then
      text(math.floor(cx - textW(label, sc) / 2 + 0.5), math.floor(cy - 5 * sc / 2 + 0.5), label, sc, C.WHITE, C.OUTLINE, 1)
    end
  end
end

local function short(n)
  if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
  if n >= 10000 then return math.floor(n / 1000) .. "K" end
  return tostring(math.floor(n))
end

local function drawTopBar()
  local sc = math.max(1, math.floor((G.barH - 4) / 6))
  text(G.m + 1, math.floor((G.barH - 5 * sc) / 2) - 1, "BLACKJACK", sc, C.WHITE, C.OUTLINE, 1, 1)
  local cr = "CREDITS " .. short(G.credits)
  text(PW - G.m - 2 - textW(cr, sc), math.floor((G.barH - 5 * sc) / 2) - 1, cr, sc, C.GOLD + 2, C.OUTLINE, 1, 1)
end

local function drawShoe()
  for k = 3, 0, -1 do drawCard(nil, G.shoeX + k, G.shoeY + k, false) end
end

local function drawInfo()
  local I = G.info
  rrect(I.x, I.y, I.w, I.h, 4, function(_, _, d)
    if d < 2 then return C.OUTLINE end
    return C.PILL
  end)
  local bet = G.bet
  if G.phase ~= "bet" then
    bet = 0
    for _, h in ipairs(G.hands) do bet = bet + h.bet end
  end
  local half = math.floor(I.h * 0.58)
  -- chip stack showing the bet
  local r = math.max(4, math.floor(math.min(half * 0.42, I.w * 0.1)))
  local cx, cy = I.x + 6 + r, I.y + math.floor(half / 2) + 3
  local left, n = bet, 0
  for k = #CHIPS, 1, -1 do
    while left >= CHIPS[k] and n < 6 do
      drawChip(cx, cy - n * math.max(2, math.floor(r / 3)), r, C.CHIPC[k], nil)
      left = left - CHIPS[k]
      n = n + 1
    end
  end
  local label = "BET " .. short(bet)
  local tx = cx + r + 6
  local sc = fitScale(label, I.x + I.w - tx - 4, half, 4)
  text(tx, I.y + math.floor((half - 5 * sc) / 2) + 2, label, sc, C.WHITE, C.OUTLINE, 1)
  local msc = fitScale(G.msg, I.w - 8, I.h - half - 2, 3)
  text(I.x + math.floor((I.w - textW(G.msg, msc)) / 2), I.y + half + math.floor((I.h - half - 5 * msc) / 2) - 1, G.msg, msc, C.MSG)
end

local function drawButton(b)
  if b.chip then
    local r = math.floor(math.min(b.w, b.h) / 2) - 2
    drawChip(b.x + b.w / 2, b.y + b.h / 2, r, C.CHIPC[b.chip], short(CHIPS[b.chip]))
    if not b.enabled then
      for yy = b.y, b.y + b.h - 1 do for xx = b.x, b.x + b.w - 1 do if (xx + yy) % 2 == 0 then put(xx, yy, C.OUTLINE) end end end
    end
    return
  end
  local fam = b.enabled and b.fam or C.GREY
  local lip = math.max(2, math.floor(b.h * 0.12))
  rrect(b.x, b.y, b.w, b.h, math.max(3, math.floor(b.h * 0.25)), function(_, yy, d)
    if d < 2 then return C.OUTLINE end
    if yy >= b.h - lip - 1 then return fam end
    if yy < b.h * 0.42 then return fam + 2 end
    return fam + 1
  end)
  local sc = b.sc or fitScale(b.label, b.w - 8, b.h - lip - 6, 4)
  local tx = b.x + math.floor((b.w - textW(b.label, sc)) / 2)
  local ty = b.y + math.floor((b.h - lip - 5 * sc) / 2)
  text(tx, ty, b.label, sc, b.enabled and C.WHITE or C.DIM, C.OUTLINE, math.max(1, math.floor(sc / 2)))
end

-- lay out a list of buttons on a grid inside rect A
local function grid(A, cols, rows, items, gap)
  local cw = math.floor((A.w - (cols - 1) * gap) / cols)
  local rh = math.floor((A.h - (rows - 1) * gap) / rows)
  for k, it in ipairs(items) do
    local c, r = (k - 1) % cols, math.floor((k - 1) / cols)
    it.x, it.y, it.w, it.h = A.x + c * (cw + gap), A.y + r * (rh + gap), cw, rh
    G.buttons[#G.buttons + 1] = it
  end
end

local function currentHand() return G.activeHand and G.hands[G.activeHand] end
local function canDouble()
  local h = currentHand()
  return G.phase == "play" and h and #h.cards == 2 and not h.splitAces and G.credits >= h.bet
end
local function canSplit()
  local h = currentHand()
  return G.phase == "play" and h and #h.cards == 2 and cardValue(h.cards[1]) == cardValue(h.cards[2])
    and #G.hands < 4 and G.credits >= h.bet
end

local function layoutButtons()
  G.buttons = {}
  local A, gap = G.btnArea, math.max(2, G.m)
  local ph = G.phase
  if ph == "bet" then
    local chips = {}
    for k = 1, 4 do chips[k] = { id = "chip", chip = k, enabled = G.credits >= CHIPS[k] } end
    local acts = { { id = "clear", label = "CLEAR", fam = C.BLUE, enabled = G.bet > 0 },
                   { id = "deal", label = "DEAL", fam = C.GREEN, enabled = G.bet > 0 } }
    local topH = math.floor(A.h * (G.land and 0.62 or 0.5))
    if G.land then grid({ x = A.x, y = A.y, w = A.w, h = topH }, 2, 2, chips, gap)
    else grid({ x = A.x, y = A.y, w = A.w, h = topH }, 4, 1, chips, gap) end
    grid({ x = A.x, y = A.y + topH + gap, w = A.w, h = A.h - topH - gap }, 2, 1, acts, gap)
  elseif ph == "result" then
    local acts = { { id = "rebet", label = "REBET", fam = C.GREEN, enabled = G.credits >= G.lastBet and G.lastBet > 0 },
                   { id = "newbet", label = "NEW BET", fam = C.BLUE, enabled = true } }
    if G.land then grid(A, 1, 2, acts, gap) else grid(A, 2, 1, acts, gap) end
  else
    local live = (ph == "play")
    local acts = { { id = "hit", label = "HIT", fam = C.GREEN, enabled = live },
                   { id = "stand", label = "STAND", fam = C.RED, enabled = live },
                   { id = "double", label = "DOUBLE", fam = C.ORANGE, enabled = canDouble() },
                   { id = "split", label = "SPLIT", fam = C.PURPLE, enabled = canSplit() } }
    local wide = A.w / 4 >= textW("DOUBLE", 2) + 10
    if G.land or not wide then grid(A, 2, 2, acts, gap) else grid(A, 4, 1, acts, gap) end
  end
  -- matching label sizes across a row of buttons
  local sc = 99
  for _, b in ipairs(G.buttons) do
    if not b.chip then
      local lip = math.max(2, math.floor(b.h * 0.12))
      sc = math.min(sc, fitScale(b.label, b.w - 8, b.h - lip - 6, 4))
    end
  end
  for _, b in ipairs(G.buttons) do b.sc = sc end
end

local function drawBanner(scale)
  local B = G.banner
  if not B then return end
  local T = G.table
  local sc = scale or B.sc
  local tw = textW(B.text, sc)
  local subSc = math.max(1, math.floor(sc / 2))
  local h = 5 * sc + (B.sub and (5 * subSc + sc) or 0) + 2 * sc
  local y = T.y + math.floor((T.h - h) / 2)
  local w = math.min(T.w, tw + 4 * sc)
  local x = T.x + math.floor((T.w - w) / 2)
  rrect(x, y, w, h, math.max(3, sc), function(_, _, d)
    if d < math.max(2, math.floor(sc / 2)) then return C.OUTLINE end
    return C.PILL
  end)
  local col = (B.kind == "bj") and C.BANNER or ((B.kind == "win") and C.GOLD + 2 or ((B.kind == "lose") and C.RED + 2 or C.WHITE))
  text(T.x + math.floor((T.w - tw) / 2), y + sc, B.text, sc, col, C.OUTLINE, math.max(1, math.floor(sc / 2)), math.max(1, math.floor(sc / 2)))
  if B.sub then
    local sw = textW(B.sub, subSc)
    text(T.x + math.floor((T.w - sw) / 2), y + 6 * sc + math.floor(sc / 2), B.sub, subSc, col, C.OUTLINE, 1)
  end
  return x, y, w, h
end

local function compose()
  for y = 1, PH do
    local s, d = G.bg[y], fb[y]
    for x = 1, PW do d[x] = s[x] end
  end
  drawTopBar()
  drawShoe()
  local lsc = math.max(1, math.floor((G.bubH - 3) / 5))
  text(G.dealerZone.x + 2, G.dealerZone.y + 2, "DEALER", lsc, C.WHITE, C.OUTLINE, 1)
  text(G.playerZone.x + 2, G.playerZone.y + 2, "YOU", lsc, C.WHITE, C.OUTLINE, 1)
  drawHand(G.dealer.cards, handZone(0), true)
  for i, h in ipairs(G.hands) do drawHand(h.cards, handZone(i), false, h, i) end
  drawInfo()
  for _, b in ipairs(G.buttons) do drawButton(b) end
  drawBanner()
end
local function refresh() compose() pushAll() end

---------------------------------------------------------------- round director (a coroutine)
local function wait(s)
  local t0 = now()
  repeat coroutine.yield() until now() - t0 >= s
end
local function animate(dur, fn)
  local t0 = now()
  while true do
    local p = math.min(1, (now() - t0) / dur)
    fn(p)
    if p >= 1 then return end
    coroutine.yield()
  end
end

local function cardSlotFor(cards, zone, i) return cardSlots(#cards, zone)[i] end

local function dealTo(hand, zoneIdx, faceUp)
  local card = drawCardFromShoe()
  card.up = faceUp
  card.anim = true
  table.insert(hand.cards, card)
  compose()
  pushAll()
  local dst = cardSlotFor(hand.cards, handZone(zoneIdx), #hand.cards)
  local sx, sy = G.shoeX, G.shoeY
  local pad = math.max(4, math.floor(G.cardW / 8))
  local bx, by = math.min(sx, dst.x) - pad, math.min(sy, dst.y) - pad
  local layer = grab(bx, by, math.abs(sx - dst.x) + G.cardW + 2 * pad, math.abs(sy - dst.y) + G.cardH + 2 * pad)
  local prev
  beep("minecraft:item.book.page_turn", 1.2 + math.random() * 0.3)
  animate(0.22, function(p)
    local e = 1 - (1 - p) ^ 3
    local x, y = math.floor(sx + (dst.x - sx) * e), math.floor(sy + (dst.y - sy) * e)
    restore(layer)
    drawCard(card, x, y, faceUp)
    local fx, fy = math.min(x, prev and prev[1] or x), math.min(y, prev and prev[2] or y)
    local tx, ty = math.max(x, prev and prev[1] or x), math.max(y, prev and prev[2] or y)
    push(fx - 1, fy - 1, tx - fx + G.cardW + pad + 2, ty - fy + G.cardH + pad + 2)
    prev = { x, y }
  end)
  card.anim = nil
  refresh()
end

local function flipHole()
  local card = G.dealer.cards[2]
  if not card or card.up then return end
  card.flipping = true
  compose()
  pushAll()
  local pos = cardSlotFor(G.dealer.cards, handZone(0), 2)
  local pad = math.max(4, math.floor(G.cardW / 8))
  local layer = grab(pos.x - 1, pos.y - 1, G.cardW + pad + 2, G.cardH + pad + 2)
  beep("minecraft:item.book.page_turn", 0.9)
  animate(0.3, function(p)
    restore(layer)
    local sq = math.abs(math.cos(p * math.pi))
    drawCard(card, pos.x, pos.y, p >= 0.5, math.max(0.05, sq))
    push(layer.x, layer.y, layer.w, layer.h)
  end)
  card.flipping = nil
  card.up = true
  refresh()
end

local function popBanner(text_, kind, sub)
  local T = G.table
  G.banner = nil
  compose()
  pushAll()
  local maxSc = math.max(1, math.min(math.floor(T.w * 0.92 / (textW(text_, 1) + 4)), math.floor(T.h * 0.22 / 5)))
  local layer = grab(T.x, T.y, T.w, T.h)
  G.banner = { text = text_, kind = kind, sub = sub, sc = maxSc }
  local steps = { math.max(1, maxSc - 2), maxSc + 1, maxSc }
  for _, s in ipairs(steps) do
    restore(layer)
    drawBanner(s)
    push(T.x, T.y, T.w, T.h)
    wait(0.07)
  end
end

local function setPhase(p)
  G.phase = p
  layoutButtons()
end

local function saveCredits()
  local f = fs.open(SAVE, "w")
  f.write(tostring(math.floor(G.credits)))
  f.close()
end

local function finishRound()
  local dv = handValue(G.dealer.cards)
  local dealerBJ = isBJ(G.dealer.cards)
  local payout, staked, anyBJ, allBust = 0, 0, false, true
  local single = (#G.hands == 1)
  for _, h in ipairs(G.hands) do
    local v = handValue(h.cards)
    local bj = single and isBJ(h.cards)
    staked = staked + h.bet
    if v <= 21 then allBust = false end
    if v > 21 then h.result = "BUST"
    elseif bj and not dealerBJ then h.result, payout, anyBJ = "BJ", payout + h.bet * 2.5, true
    elseif dealerBJ and not bj then h.result = "LOSE"
    elseif dv > 21 or v > dv then h.result, payout = "WIN", payout + h.bet * 2
    elseif v == dv then h.result, payout = "PUSH", payout + h.bet
    else h.result = "LOSE" end
  end
  payout = math.floor(payout)
  G.credits = G.credits + payout
  saveCredits()
  local net = payout - staked
  local title, kind
  if anyBJ then title, kind = "BLACKJACK!", "bj"
  elseif net > 0 then title, kind = "YOU WIN!", "win"
  elseif net == 0 then title, kind = "PUSH", "push"
  elseif allBust then title, kind = "BUST!", "lose"
  else title, kind = "DEALER WINS", "lose" end
  local sub = (net > 0) and ("+" .. net) or ((net < 0) and tostring(net) or nil)
  G.activeHand = nil
  setPhase("result")
  G.msg = (kind == "lose") and "BETTER LUCK NEXT TIME" or ((kind == "push") and "BET RETURNED" or "NICE!")
  G.msgKind = kind
  popBanner(title, kind, sub)
  if kind == "bj" then
    G.showerUntil = now() + 3
    beep("minecraft:ui.toast.challenge_complete", 1, 3)
    if G.chat then pcall(G.chat.sendMessage, "someone hit BLACKJACK! +" .. net .. " credits", "BLACKJACK") end
  elseif kind == "win" then
    if net >= 100 then G.showerUntil = now() + 1.5 end
    beep("minecraft:entity.player.levelup", 1)
  elseif kind == "lose" then
    beep(allBust and "minecraft:block.note_block.didgeridoo" or "minecraft:block.note_block.bass", 0.7)
  else
    beep("minecraft:block.note_block.bell", 1)
  end
  refresh()
  -- let the banner sink in, then clear it so each hand's WIN/LOSE tag is visible
  wait(2.5)
  if G.phase == "result" and G.banner then
    G.banner = nil
    refresh()
  end
end

local function roundFlow()
  G.hands = { { cards = {}, bet = G.bet } }
  G.dealer = { cards = {} }
  G.banner = nil
  G.lastBet = G.bet
  G.bet = 0
  G.activeHand = nil
  setPhase("busy")
  if not G.shoe or #G.shoe < 60 then
    newShoe()
    G.msg = "SHUFFLING..."
    refresh()
    wait(0.6)
  end
  G.msg = "GOOD LUCK"
  refresh()
  dealTo(G.hands[1], 1, true)
  dealTo(G.dealer, 0, true)
  dealTo(G.hands[1], 1, true)
  dealTo(G.dealer, 0, false)

  local upV = cardValue(G.dealer.cards[1])
  local dealerBJ = isBJ(G.dealer.cards)
  local playerBJ = isBJ(G.hands[1].cards)
  if (upV == 10 or G.dealer.cards[1].r == 1) and not playerBJ then
    G.msg = "DEALER PEEKS..."
    refresh()
    wait(0.5)
  end
  if dealerBJ or playerBJ then
    wait(0.25)
    flipHole()
    return finishRound()
  end

  local i = 1
  while i <= #G.hands do
    local h = G.hands[i]
    G.activeHand = i
    if #h.cards == 1 then dealTo(h, i, true) end
    while true do
      local v = handValue(h.cards)
      if v > 21 then
        G.msg = "BUST!"
        beep("minecraft:block.note_block.didgeridoo", 0.8)
        refresh()
        wait(0.5)
        break
      end
      if v == 21 or h.splitAces then break end
      G.msg = (#G.hands > 1) and ("HAND " .. i .. " - YOUR MOVE") or "YOUR MOVE"
      setPhase("play")
      refresh()
      G.action = nil
      while not G.action do coroutine.yield() end
      local a = G.action
      G.action = nil
      setPhase("busy")
      if a == "hit" then
        dealTo(h, i, true)
      elseif a == "stand" then
        break
      elseif a == "double" then
        G.credits = G.credits - h.bet
        h.bet = h.bet * 2
        saveCredits()
        G.msg = "DOUBLE DOWN!"
        dealTo(h, i, true)
        wait(0.3)
        break
      elseif a == "split" then
        G.credits = G.credits - h.bet
        saveCredits()
        local moved = table.remove(h.cards, 2)
        local nh = { cards = { moved }, bet = h.bet, split = true }
        h.split = true
        if h.cards[1].r == 1 then h.splitAces, nh.splitAces = true, true end
        table.insert(G.hands, i + 1, nh)
        G.msg = "SPLIT!"
        refresh()
        dealTo(h, i, true)
      end
    end
    i = i + 1
  end
  G.activeHand = nil

  setPhase("busy")
  G.msg = "DEALER'S TURN"
  refresh()
  wait(0.3)
  flipHole()
  local anyLive = false
  for _, h in ipairs(G.hands) do if handValue(h.cards) <= 21 then anyLive = true end end
  if anyLive then
    while handValue(G.dealer.cards) < 17 do
      wait(0.45)
      dealTo(G.dealer, 0, true)
    end
  end
  wait(0.3)
  finishRound()
end

local function startRound()
  -- a finished round may still be waiting to hide its banner; that's safe to replace
  if G.director and coroutine.status(G.director) ~= "dead" and G.phase ~= "result" then return end
  G.director = coroutine.create(roundFlow)
end

---------------------------------------------------------------- coins
G.CS = math.max(4, math.floor(math.min(PW, PH) / 24))
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
    for _ = 1, 2 do
      coins[#coins + 1] = { x = math.random(0, PW - CS), y = -CS, vx = (math.random() - 0.5) * 1.5,
        vy = math.random() * 2, f = math.random(0, 3) }
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
    cn.px, cn.py = x, y
    local spr = G.coinSprites[(cn.f % 4) + 1]
    local xa, xb = math.max(0, x), math.min(PW - 1, x + CS - 1)
    local rows, firstY = {}, nil
    if xa <= xb then
      for j = 1, CS do
        local yy = y + j - 1
        if yy >= 0 and yy < PH then
          firstY = firstY or yy
          local src, row, tmp, n = spr[j], fb[yy + 1], {}, 0
          for xx = xa, xb do n = n + 1 tmp[n] = src[xx - x + 1] or row[xx + 1] end
          rows[#rows + 1] = string.char(table.unpack(tmp))
        end
      end
      if firstY then t.drawPixels(xa, firstY, rows) end
    end
  end
end

---------------------------------------------------------------- palette animation
local function updatePalettes(tm)
  local p = 0.5 + 0.5 * math.sin(tm * 7)
  setPal(C.GLOW, mix(0xffb020, 0xfff6b0, p))
  setPal(C.BANNER, toHex(lib.hsv(tm * 0.6, 0.6, 1)))
  local k = G.msgKind
  if k == "bj" then setPal(C.MSG, toHex(lib.hsv(tm * 0.6, 0.5, 1)))
  elseif k == "win" then setPal(C.MSG, mix(0x60ff90, 0xffffff, p))
  elseif k == "lose" then setPal(C.MSG, mix(0xff6070, 0xffc0c8, p))
  else setPal(C.MSG, 0xffffff) end
end

---------------------------------------------------------------- input
local function press(b)
  if not b or not b.enabled then return end
  local id = b.id
  if G.phase == "bet" then
    if id == "chip" then
      local v = CHIPS[b.chip]
      if G.credits >= v then
        G.credits = G.credits - v
        G.bet = G.bet + v
        G.msg = "BET " .. short(G.bet) .. " - PRESS DEAL"
        G.msgKind = "info"
        beep("minecraft:block.stone_button.click_on", 1.4 + b.chip * 0.1)
      end
    elseif id == "clear" then
      G.credits = G.credits + G.bet
      G.bet = 0
      G.msg = "PLACE YOUR BET"
    elseif id == "deal" then
      saveCredits()
      startRound()
      return
    end
    saveCredits()
    layoutButtons()
    refresh()
  elseif G.phase == "play" then
    if id == "hit" or id == "stand" or id == "double" or id == "split" then G.action = id end
  elseif G.phase == "result" then
    if id == "rebet" then
      G.credits = G.credits - G.lastBet
      G.bet = G.lastBet
      saveCredits()
      G.msgKind = "info"
      startRound()
    elseif id == "newbet" then
      G.hands, G.dealer, G.banner = {}, { cards = {} }, nil
      G.msg, G.msgKind = "PLACE YOUR BET", "info"
      setPhase("bet")
      refresh()
    end
  end
end
local function findButton(id, chip)
  for _, b in ipairs(G.buttons) do if b.id == id and (not chip or b.chip == chip) then return b end end
end
local function hit(px, py)
  for _, b in ipairs(G.buttons) do
    if px >= b.x and px < b.x + b.w and py >= b.y and py < b.y + b.h then return b end
  end
end

---------------------------------------------------------------- run
G.credits = 500
if fs.exists(SAVE) then
  local f = fs.open(SAVE, "r")
  G.credits = tonumber(f.readLine()) or 500
  f.close()
end
computeLayout()
buildBackground()
newShoe()
setPhase("bet")
refresh()

local monName = G.isMon and peripheral.getName(t) or nil
local KEYMAP = { h = "hit", s = "stand", d = "double", p = "split", c = "clear", n = "newbet" }
local ok, err = pcall(function()
  local timer = os.startTimer(0.05)
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      local tm = now()
      freeze(true)
      updatePalettes(tm)
      if G.director and coroutine.status(G.director) ~= "dead" then
        local okc, errc = coroutine.resume(G.director)
        if not okc then error(errc, 0) end
      end
      updateCoins(tm)
      freeze(false)
      timer = os.startTimer(0.05)
    elseif e == "monitor_touch" and a == monName then
      press(hit((b - 1) * 6 + 3, (c - 1) * 9 + 4))
    elseif e == "mouse_click" and not G.isMon then
      press(hit(b, c))
    elseif e == "key" then
      if a == keys.q then break end
      local name = keys.getName and keys.getName(a)
      if name and KEYMAP[name] then press(findButton(KEYMAP[name]))
      elseif a == keys.enter then press(findButton("deal") or findButton("rebet"))
      elseif name == "one" or name == "two" or name == "three" or name == "four" then
        local k = ({ one = 1, two = 2, three = 3, four = 4 })[name]
        press(findButton("chip", k))
      end
    end
  end
end)

if G.phase == "bet" then G.credits = G.credits + G.bet saveCredits() end
pcall(t.setGraphicsMode, 0)
lib.resetPalette(t)
t.setBackgroundColor(colors.black)
t.setTextColor(colors.white)
t.clear()
t.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("left the table with " .. lib.commas(math.floor(G.credits)) .. " credits.")
