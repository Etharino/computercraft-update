-- auralib.lua :: shared stuff for the aura programs (big font, colours, helpers)
local M = {}

-- 3x5 pixel font. each "#" becomes a 2x1 block of cells (cells are tall, so this looks square-ish)
M.font = {
  A={".#.","#.#","###","#.#","#.#"}, B={"##.","#.#","##.","#.#","##."},
  C={".##","#..","#..","#..",".##"}, D={"##.","#.#","#.#","#.#","##."},
  E={"###","#..","##.","#..","###"}, F={"###","#..","##.","#..","#.."},
  G={".##","#..","#.#","#.#",".##"}, H={"#.#","#.#","###","#.#","#.#"},
  I={"###",".#.",".#.",".#.","###"}, J={"..#","..#","..#","#.#",".#."},
  K={"#.#","#.#","##.","#.#","#.#"}, L={"#..","#..","#..","#..","###"},
  M={"#.#","###","###","#.#","#.#"}, N={"##.","#.#","#.#","#.#","#.#"},
  O={".#.","#.#","#.#","#.#",".#."}, P={"##.","#.#","##.","#..","#.."},
  Q={".#.","#.#","#.#","##.",".##"}, R={"##.","#.#","##.","#.#","#.#"},
  S={".##","#..",".#.","..#","##."}, T={"###",".#.",".#.",".#.",".#."},
  U={"#.#","#.#","#.#","#.#","###"}, V={"#.#","#.#","#.#","#.#",".#."},
  W={"#.#","#.#","###","###","#.#"}, X={"#.#","#.#",".#.","#.#","#.#"},
  Y={"#.#","#.#",".#.",".#.",".#."}, Z={"###","..#",".#.","#..","###"},
  ["0"]={"###","#.#","#.#","#.#","###"}, ["1"]={".#.","##.",".#.",".#.","###"},
  ["2"]={"##.","..#",".#.","#..","###"}, ["3"]={"##.","..#",".#.","..#","##."},
  ["4"]={"#.#","#.#","###","..#","..#"}, ["5"]={"###","#..","##.","..#","##."},
  ["6"]={".##","#..","###","#.#","###"}, ["7"]={"###","..#",".#.",".#.",".#."},
  ["8"]={"###","#.#","###","#.#","###"}, ["9"]={"###","#.#","###","..#","##."},
  [" "]={"...","...","...","...","..."}, ["!"]={".#.",".#.",".#.","...",".#."},
  ["+"]={"...",".#.","###",".#.","..."}, ["-"]={"...","...","###","...","..."},
  ["_"]={"...","...","...","...","###"}, ["."]={"...","...","...","...",".#."},
  [","]={"...","...","...",".#.","#.."}, [":"]={"...",".#.","...",".#.","..."},
  ["?"]={"##.","..#",".#.","...",".#."},
}

function M.hsv(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return v, t, p
  elseif i == 1 then return q, v, p
  elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v
  elseif i == 4 then return t, p, v
  else return v, p, q end
end

function M.commas(n)
  local neg = n < 0
  local s = string.format("%.0f", math.abs(n))
  s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if s:sub(1, 1) == "," then s = s:sub(2) end
  return (neg and "-" or "") .. s
end

-- big text sizing. xs = how many cells wide each font pixel is per scale step:
-- 2 looks best, 1 is the skinny fallback for small screens (computer / pocket computer)
function M.lineWidth(s, sc, xs) if #s == 0 then return 0 end return (#s * 4 - 1) * (xs or 2) * sc end
function M.blockHeight(n, sc) return (n * 6 - 1) * sc end

-- returns scale, xs  (scale 0 = doesn't fit at all)
function M.fitLines(lines, w, h)
  local maxLen = 0
  for _, l in ipairs(lines) do maxLen = math.max(maxLen, #l) end
  if maxLen == 0 then return 0, 2 end
  local sh = math.floor(h / (#lines * 6 - 1))
  for _, xs in ipairs({ 2, 1 }) do
    local sc = math.min(math.floor(w / ((maxLen * 4 - 1) * xs)), sh)
    if sc >= 1 then return sc, xs end
  end
  return 0, 1
end

-- returns lines, scale, xs
function M.fitText(text, w, h, maxScale)
  text = text:upper()
  local lines = { text }
  local sc, xs = M.fitLines(lines, w, h)
  if sc < 1 and text:find(" ") then
    lines = {}
    for word in text:gmatch("%S+") do lines[#lines + 1] = word end
    sc, xs = M.fitLines(lines, w, h)
  end
  if maxScale then sc = math.min(sc, maxScale) end
  return lines, sc, xs
end

-- grid = 2D table of background hex chars, blitted row by row
function M.grid(w, h, hex)
  local g = {}
  for y = 1, h do
    local r = {}
    for x = 1, w do r[x] = hex end
    g[y] = r
  end
  return g
end

-- paint big centred text into a grid (optionally with a drop shadow)
function M.stamp(grid, lines, sc, hex, shadowHex, yOffset)
  local h, w = #grid, #grid[1]
  local y0 = math.floor((h - M.blockHeight(#lines, sc)) / 2) + 1 + (yOffset or 0)
  local passes = shadowHex and { { 1, shadowHex }, { 0, hex } } or { { 0, hex } }
  for _, pass in ipairs(passes) do
    local off, col = pass[1], pass[2]
    for li, line in ipairs(lines) do
      local x0 = math.floor((w - M.lineWidth(line, sc)) / 2) + 1
      local ly = y0 + (li - 1) * 6 * sc
      for ci = 1, #line do
        local g = M.font[line:sub(ci, ci)] or M.font[" "]
        for gy = 1, 5 do
          local row = g[gy]
          for gx = 1, 3 do
            if row:sub(gx, gx) == "#" then
              local bx = x0 + (ci - 1) * 8 * sc + (gx - 1) * 2 * sc + off
              local by = ly + (gy - 1) * sc + off
              for sy = 0, sc - 1 do
                local r = grid[by + sy]
                if r then
                  for sx = 0, 2 * sc - 1 do
                    if r[bx + sx] then r[bx + sx] = col end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

function M.blitRow(t, grid, y, fgHex)
  local row = grid[y]
  t.setCursorPos(1, y)
  t.blit(string.rep(" ", #row), string.rep(fgHex, #row), table.concat(row))
end

function M.blitGrid(t, grid, fgHex)
  for y = 1, #grid do M.blitRow(t, grid, y, fgHex) end
end

function M.resetPalette(t)
  for i = 0, 15 do
    local c = 2 ^ i
    t.setPaletteColor(c, term.nativePaletteColor(c))
  end
end

-- Advanced Peripherals has used both camelCase and snake_case type names, so try both
function M.findAny(...)
  for _, n in ipairs({ ... }) do
    local p = peripheral.find(n)
    if p then return p, n end
  end
end

return M
