local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found") end

local screen = term.current()
screen.setCursorBlink(false)
screen.setBackgroundColor(colors.black)
screen.clear()

local SELF_NAME = "Etharino"

local MIN_RANGE = 50
local RANGE_STEP = 50
local REFRESH = 0.25

local targets = {
    "Etharino",
    "Steve",
    "Alex"
}

local lastRel = {}
local lastDrawn = {}

local function writeAt(x, y, text, color)
    local w, h = screen.getSize()
    x = math.floor(x)
    y = math.floor(y)

    if x < 1 or y < 1 or x > w or y > h then return end

    screen.setCursorPos(x, y)
    screen.setTextColor(color or colors.white)
    screen.write(tostring(text):sub(1, w - x + 1))
end

local function draw(x, y, text, color)
    writeAt(x, y, text, color)

    text = tostring(text)
    for i = 0, #text - 1 do
        table.insert(lastDrawn, {
            x = math.floor(x) + i,
            y = math.floor(y)
        })
    end
end

local function eraseOld()
    for _, p in ipairs(lastDrawn) do
        writeAt(p.x, p.y, " ", colors.black)
    end
    lastDrawn = {}
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
        -- North is up, so negative Z is up.
        if dz > 0 then return "v" else return "^" end
    end
end

local function roundRange(dist)
    local r = math.ceil(dist / RANGE_STEP) * RANGE_STEP
    if r < MIN_RANGE then r = MIN_RANGE end
    return r
end

local function worldToMap(dx, dz, cx, cy, radiusX, radiusY, range)
    local x = cx + (dx / range) * radiusX
    local y = cy + (dz / range) * radiusY

    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function drawGrid(w, h, cx, cy)
    for x = 1, w do
        if x % 5 == 0 then
            draw(x, cy, "-", colors.gray)
        end
    end

    for y = 1, h do
        if y % 3 == 0 then
            draw(cx, y, "|", colors.gray)
        end
    end

    draw(cx, cy, "+", colors.lime)
    draw(cx, 1, "N", colors.white)
end

while true do
    local w, h = screen.getSize()
    local cx = math.floor((w + 1) / 2)
    local cy = math.floor((h + 1) / 2)

    local radiusX = cx - 1
    local radiusY = cy - 1
    if w - cx < radiusX then radiusX = w - cx end
    if h - cy < radiusY then radiusY = h - cy end
    if radiusX < 1 then radiusX = 1 end
    if radiusY < 1 then radiusY = 1 end

    local selfPos = getPlayerPos(SELF_NAME)

    eraseOld()

    if not selfPos then
        draw(1, 1, "NO SELF POSITION", colors.red)
        sleep(0.5)
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

                    if dist > farthest then
                        farthest = dist
                    end

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

        drawGrid(w, h, cx, cy)

        draw(1, 1, "R" .. range, colors.green)
        draw(1, h, "X" .. math.floor(selfPos.x) .. " Z" .. math.floor(selfPos.z), colors.green)

        for _, p in ipairs(players) do
            local x, y = worldToMap(p.dx, p.dz, cx, cy, radiusX, radiusY, range)

            local last = lastRel[p.name]
            local marker = "O"

            if last then
                marker = getArrow(p.dx - last.dx, p.dz - last.dz)
            end

            local label = p.name:sub(1, 3)
            local offset = math.floor(p.dx) .. "," .. math.floor(p.dz)

            draw(x, y, marker, colors.red)

            if x + 4 <= w then
                draw(x + 1, y, label, colors.white)
            elseif x - 3 >= 1 then
                draw(x - 3, y, label, colors.white)
            end

            -- Show block offset when there is room near the dot.
            if y + 1 <= h and x + #offset <= w then
                draw(x, y + 1, offset, colors.yellow)
            end

            lastRel[p.name] = {
                dx = p.dx,
                dz = p.dz
            }
        end

        sleep(REFRESH)
    end
end
