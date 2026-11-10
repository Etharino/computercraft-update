-- tiktok.lua :: a fake "for you" short-video feed, rendered with the CC: Graphics mod
-- (the ccgraphics addon) if it's active on this screen, for real per-pixel video instead
-- of blocky characters. Falls back to the normal character-block look if ccgraphics
-- isn't available so this still works either way.
--
-- there's no real video here — no network video exists for ComputerCraft to play — these
-- are small procedurally-animated loops with fake captions/usernames/like counts, styled
-- like a short-form feed.
--
-- controls:
--   on a monitor: tap the top half = next video, bottom half = previous video,
--                 tap the heart on the right edge = like
--   no monitor:   up/down arrows = next/previous, L or enter = like, q = quit

local lib = require("auralib")

local mon = peripheral.find("monitor")
local t = mon or term
if mon then mon.setTextScale(0.5) end

local hasGfx = type(t.setGraphicsMode) == "function"
local MODE   -- "gfx" or "block"

---------------------------------------------------------------- canvas setup
local LW, LH          -- logical grid size we animate at (kept small & fast)
local pw, ph, ox, oy  -- gfx: real pixels per logical cell, and centring offset
local realW, realH
local touchW, touchH  -- monitor_touch always reports in TEXT cell coords, even in
                       -- graphics mode, so touch zones are measured against these, not realW/realH

local function colorHex(c)
  local i, v = 0, c
  while v > 1 do v = v / 2 i = i + 1 end
  return ("0123456789abcdef"):sub(i + 1, i + 1)
end

local function setup()
  touchW, touchH = t.getSize() -- text dimensions; valid in any mode, even before switching
  if hasGfx then
    local ok = pcall(t.setGraphicsMode, 1)
    if ok then
      realW, realH = t.getSize(1)
      -- cap the working resolution so a huge monitor doesn't make every frame slow;
      -- we scale small logical cells up to fill the real screen instead.
      LW = math.min(realW, 72)
      LH = math.min(realH, 48)
      pw = math.max(1, math.floor(realW / LW))
      ph = math.max(1, math.floor(realH / LH))
      ox = math.floor((realW - LW * pw) / 2)
      oy = math.floor((realH - LH * ph) / 2)
      MODE = "gfx"
      return
    end
  end
  MODE = "block"
  LW, LH = t.getSize()
  t.setBackgroundColor(colors.black)
  t.clear()
end

-- grid[y][x] = a `colors.X` constant (or false for "leave black")
local function newGrid()
  local g = {}
  for y = 1, LH do
    local row = {}
    for x = 1, LW do row[x] = false end
    g[y] = row
  end
  return g
end

local function flush(grid)
  if MODE == "gfx" then
    local rows = {}
    for ly = 1, LH do
      local src = grid[ly]
      for r = 1, ph do
        local row = {}
        local i = 1
        for lx = 1, LW do
          local c = src[lx] or colors.black
          for _ = 1, pw do row[i] = c i = i + 1 end
        end
        rows[(ly - 1) * ph + r] = row
      end
    end
    pcall(t.drawPixels, ox, oy, rows)
  else
    for y = 1, LH do
      local row = grid[y]
      local fg, bg = {}, {}
      for x = 1, LW do
        local h = colorHex(row[x] or colors.black)
        fg[x], bg[x] = h, h
      end
      t.setCursorPos(1, y)
      t.blit(string.rep(" ", LW), table.concat(fg), table.concat(bg))
    end
  end
end

-- plot a pixel-font glyph straight onto the logical grid (shared by both backends)
local function drawText(grid, x0, y0, text, color, scale)
  text = text:upper()
  for ci = 1, #text do
    local g = lib.font[text:sub(ci, ci)] or lib.font[" "]
    for gy = 1, 5 do
      local row = g[gy]
      for gx = 1, 3 do
        if row:sub(gx, gx) == "#" then
          local bx = x0 + (ci - 1) * 4 * scale + (gx - 1) * scale
          local by = y0 + (gy - 1) * scale
          for sy = 0, scale - 1 do
            local r = grid[by + sy]
            if r then
              for sx = 0, scale - 1 do
                if r[bx + sx] ~= nil then r[bx + sx] = color end
              end
            end
          end
        end
      end
    end
  end
end
local function textWidth(text, scale) return (#text * 4 - 1) * scale end

local function heart(grid, cx, cy, size, color)
  -- classic implicit heart curve, sampled on the grid
  for y = -size, size do
    for x = -size, size do
      local nx, ny = x / size, -y / size + 0.3
      local v = (nx * nx + ny * ny - 1) ^ 3 - nx * nx * ny * ny * ny
      if v <= 0 then
        local r = grid[cy + y]
        if r and r[cx + x] ~= nil then r[cx + x] = color end
      end
    end
  end
end

---------------------------------------------------------------- the "videos"
local PALETTE = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green,
  colors.cyan, colors.lightBlue, colors.blue, colors.purple, colors.magenta, colors.pink }

local function auraRave(grid, frame)
  local cx, cy = LW / 2, LH / 2
  for y = 1, LH do
    for x = 1, LW do
      local dx, dy = (x - cx), (y - cy) * 1.7
      local d = math.sqrt(dx * dx + dy * dy)
      local a = math.atan2(dy, dx)
      local v = d * 0.5 + math.sin(a * 5 - frame * 0.25) * 2 + frame * 0.4
      grid[y][x] = PALETTE[(math.floor(v) % #PALETTE) + 1]
    end
  end
end

local function lavaLamp(grid, frame)
  local blobs = {
    { 0.3, 0.35 }, { 0.7, 0.55 }, { 0.5, 0.75 }, { 0.25, 0.65 },
  }
  for y = 1, LH do
    for x = 1, LW do
      local nx, ny = x / LW, y / LH
      local v = 0
      for i, b in ipairs(blobs) do
        local bx = b[1] + math.sin(frame * 0.05 + i * 2) * 0.22
        local by = (b[2] + math.cos(frame * 0.04 + i * 3) * 0.22) % 1
        local dx, dy = nx - bx, ny - by
        v = v + 0.02 / (dx * dx + dy * dy + 0.001)
      end
      grid[y][x] = v > 1.6 and colors.orange or (v > 0.9 and colors.red or colors.black)
    end
  end
end

local rainCols
local function matrixRain(grid, frame)
  rainCols = rainCols or {}
  for x = 1, LW do
    rainCols[x] = rainCols[x] or { y = math.random(1, LH), speed = math.random(1, 2) }
  end
  for y = 1, LH do for x = 1, LW do grid[y][x] = colors.black end end
  for x = 1, LW do
    local c = rainCols[x]
    if frame % c.speed == 0 then
      c.y = c.y + 1
      if c.y > LH + 6 then c.y = -math.random(0, LH) end
    end
    for tail = 0, 6 do
      local y = c.y - tail
      if y >= 1 and y <= LH then
        grid[y][x] = tail == 0 and colors.white or (tail < 3 and colors.lime or colors.green)
      end
    end
  end
end

local function pulseHeart(grid, frame)
  for y = 1, LH do for x = 1, LW do grid[y][x] = colors.black end end
  local beat = math.abs(math.sin(frame * 0.15))
  local size = math.floor(math.min(LW, LH) * 0.38 * (0.85 + 0.25 * beat))
  heart(grid, math.floor(LW / 2), math.floor(LH / 2), math.max(size, 3), colors.pink)
  if beat > 0.9 then heart(grid, math.floor(LW / 2), math.floor(LH / 2), math.max(size + 2, 4), colors.red) end
end

local VIDEOS = {
  { user = "@auracore",     caption = "unreal lighting today ✨ no filter",    song = "deep house mix",     likes = 48200,  comments = 621,  draw = auraRave },
  { user = "@lavalampvibes", caption = "put this on in the bg and chill",      song = "lofi beats to relax", likes = 19500,  comments = 203,  draw = lavaLamp },
  { user = "@terminalcore",  caption = "hacked the mainframe (not clickbait)", song = "cyberpunk synth",    likes = 103000, comments = 2114, draw = matrixRain },
  { user = "@wholesome",     caption = "sending love to everyone reading 💗",  song = "soft piano",         likes = 76800,  comments = 955,  draw = pulseHeart },
}

---------------------------------------------------------------- app state
local idx = 1
local liked = {}
local frame = 0
local likeBurst = 0

local function heartIconColor(i)
  return liked[i] and colors.red or colors.white
end

local function render()
  local grid = newGrid()
  local v = VIDEOS[idx]
  v.draw(grid, frame)

  -- top tabs
  drawText(grid, math.floor(LW / 2 - 18), 1, "FOLLOWING", colors.gray, 1)
  drawText(grid, math.floor(LW / 2 + 2), 1, "FOR YOU", colors.white, 1)

  -- caption / username overlay, bottom-left, over a dim bar
  local barY = LH - 7
  for y = barY, LH do
    for x = 1, LW - 5 do
      local r = grid[y]
      if r and r[x] ~= nil then r[x] = false end
    end
  end
  drawText(grid, 2, barY + 1, v.user, colors.lime, 1)
  -- scrolling caption
  local cw = textWidth(v.caption, 1)
  local scroll = (frame * 1) % (cw + LW)
  drawText(grid, 2 - scroll + LW, barY + 3, v.caption, colors.white, 1)
  drawText(grid, 2, barY + 5, "\xa7 " .. v.song, colors.cyan, 1)

  -- right-side action rail: heart + counts
  local rx = LW - 3
  heart(grid, rx, LH - 14, 2, heartIconColor(idx))
  drawText(grid, rx - 6, LH - 11, lib.commas(v.likes + (liked[idx] and 1 or 0)), colors.white, 1)
  drawText(grid, rx - 6, LH - 6, lib.commas(v.comments), colors.white, 1)

  if likeBurst > 0 then
    heart(grid, math.floor(LW / 2), math.floor(LH / 2), likeBurst, colors.red)
    likeBurst = likeBurst - 1
  end

  flush(grid)
end

local function doLike()
  liked[idx] = not liked[idx]
  if liked[idx] then likeBurst = math.floor(math.min(LW, LH) * 0.3) end
end

local function nextVideo(dir)
  idx = ((idx - 1 + dir) % #VIDEOS) + 1
  frame = 0
  if MODE == "block" then t.setBackgroundColor(colors.black) t.clear() end
end

---------------------------------------------------------------- main
setup()
local timer = os.startTimer(0.12)
local running = true
local okRun, errRun = pcall(function()
  while running do
    local e, a, b, c = os.pullEvent()
    if e == "timer" and a == timer then
      frame = frame + 1
      render()
      timer = os.startTimer(0.12)
    elseif e == "monitor_touch" and mon then
      if a == peripheral.getName(mon) then
        if b > touchW - touchW * 0.12 and c > touchH * 0.35 and c < touchH * 0.75 then
          doLike()
        elseif c < touchH / 2 then
          nextVideo(1)
        else
          nextVideo(-1)
        end
      end
    elseif e == "key" and not mon then
      if b == keys.up then nextVideo(-1)
      elseif b == keys.down then nextVideo(1)
      elseif b == keys.l or b == keys.enter then doLike()
      elseif b == keys.q then running = false
      end
    elseif e == "monitor_resize" or e == "term_resize" then
      setup()
    end
  end
end)

if hasGfx and MODE == "gfx" then pcall(t.setGraphicsMode, 0) end
t.setBackgroundColor(colors.black)
t.setTextColor(colors.white)
t.clear()
t.setCursorPos(1, 1)
if not okRun and errRun ~= "Terminated" then printError(errRun) end
print("left the feed.")
