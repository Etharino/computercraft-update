local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found") end

local screen = term.current()
screen.setCursorBlink(false)

local SELF_NAME = "Etharino"

local MIN_RANGE = 50
local RANGE_STEP = 50
local REFRESH = 0.35

local targets = {
    "Etharino",
    "Steve",
    "Alex"
}

local lastRel = {}
local oldRows = {}

local function fg(c)
    return colors.toBlit(c or colors.white)
end

local function bg(c)
    return colors.toBlit(c or colors.black)
end

local function isOverworld(pos)
    if not pos.dimension then return true end
    return pos.dimension == "minecraft:overworld" or pos.dimension == "overworld"
end

local function getPlayerPos(name)
    local ok, pos = pcall(function()
        return detector.getPlayerPos(name)
    end)

    if ok and pos and pos.x and pos.z and isOverworld(pos) then
        return pos
    end

    return nil
end

local function getArrow(dx, dz)
    if math.abs(dx) < 0.1 and math.abs(dz) < 0.1 then
        return "O"
    end

    if math.abs(dx) > math.abs(dz) then
        if dx > 0 then return ">" else return "<" end
    else
        if dz > 0 then return "v" else return "^" end
    end
end

local function roundRange(dist)
    local r = math.ceil(dist / RANGE_STEP) * RANGE_STEP
    if r < MIN_RANGE then r = MIN_RANGE end
    return r
end

local function makeFrame(w, h)
    local chars = {}
    local fgs = {}
    local bgs = {}

    for y = 1, h do
        chars[y] = {}
        fgs[y] = {}
        bgs[y] = {}

        for x = 1, w do
            chars[y][x] = " "
            fgs[y][x] = fg(colors.white)
            bgs[y][x] = bg(colors.black)
        end
    end

    return chars, fgs, bgs
end

local function put(chars, fgs, bgs, x, y, text, color)
    local w, h = screen.getSize()
    x = math.floor(x)
    y = math.floor(y)

    if y < 1 or y > h then return end

    text = tostring(text)

    for i = 1, #text do
        local px = x + i - 1
        if px >= 1 and px <= w then
            chars[y][px] = text:sub(i, i)
            fgs[y][px] = fg(color or colors.white)
            bgs[y][px] = bg(colors.black)
        end
    end
end

local function flush(chars, fgs, bgs, w, h)
    for y = 1, h do
        local c = table.concat(chars[y])
        local f = table.concat(fgs[y])
        local b = table.concat(bgs[y])

        local row = c .. f .. b

        if oldRows[y] ~= row then
            screen.setCursorPos(1, y)
            screen.blit(c, f, b)
            oldRows[y] = row
        end
    end
end

local function drawGrid(chars, fgs, bgs, w, h, cx, cy)
    for x = 1, w do
        if x % 5 == 0 then
            put(chars, fgs, bgs, x, cy, "-", colors.gray)
        end
    end

    for y = 1, h do
        if y % 3 == 0 then
            put(chars, fgs, bgs, cx, y, "|", colors.gray)
        end
    end

    put(chars, fgs, bgs, cx, cy, "+", colors.lime)
    put(chars, fgs, bgs, cx, 1, "N", colors.white)
end

local function worldToMap(dx, dz, cx, cy, radiusX, radiusY, range)
    local x = cx + (dx / range) * radiusX
    local y = cy + (dz / range) * radiusY
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

screen.setBackgroundColor(colors.black)
screen.clear()

while true do
    local w, h = screen.getSize()
    local chars, fgs, bgs = makeFrame(w, h)

    local cx = math.floor((w + 1) / 2)
    local cy = math.floor((h + 1) / 2)

    local radiusX = math.max(1, math.min(cx - 1, w - cx))
    local radiusY = math.max(1, math.min(cy - 1, h - cy))

    local selfPos = getPlayerPos(SELF_NAME)

    if not selfPos then
        put(chars, fgs, bgs, 1, 1, "NO SELF POSITION", colors.red)
    else
        local players = {}
        local farthest = MIN_RANGE

        for _, name in ipairs(targets) do
            if name ~= SELF_NAME then
                local pos = getPlayerPos(name)

                if pos then
                    local dx = pos.x - selfPos.x
                    local dz = pos.z - selfPos.z
                    local dist = math.sqrt(dx * dx + dz * dz)

                    if dist > farthest then farthest = dist end

                    table.insert(players, {
                        name = name,
                        dx = dx,
                        dz = dz,
                        dist = dist
                    })
                end
            end
        end

        local range = roundRange(farthest)

        drawGrid(chars, fgs, bgs, w, h, cx, cy)

        put(chars, fgs, bgs, 1, 1, "R" .. range, colors.green)
        put(chars, fgs, bgs, 1, h, "X" .. math.floor(selfPos.x) .. " Z" .. math.floor(selfPos.z), colors.green)

        for _, p in ipairs(players) do
            local x, y = worldToMap(p.dx, p.dz, cx, cy, radiusX, radiusY, range)

            local last = lastRel[p.name]
            local marker = "O"

            if last then
                marker = getArrow(p.dx - last.dx, p.dz - last.dz)
            end

            local label = p.name:sub(1, 3)
            local offset = math.floor(p.dx) .. "," .. math.floor(p.dz)

            put(chars, fgs, bgs, x, y, marker, colors.red)

            if x + 4 <= w then
                put(chars, fgs, bgs, x + 1, y, label, colors.white)
            elseif x - 3 >= 1 then
                put(chars, fgs, bgs, x - 3, y, label, colors.white)
            end

            if y + 1 <= h and x + #offset <= w then
                put(chars, fgs, bgs, x, y + 1, offset, colors.yellow)
            end

            lastRel[p.name] = {
                dx = p.dx,
                dz = p.dz
            }
        end
    end

    flush(chars, fgs, bgs, w, h)
    sleep(REFRESH)
end
