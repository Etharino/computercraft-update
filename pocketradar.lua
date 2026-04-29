local detector = peripheral.find("playerDetector")
local speaker = peripheral.find("speaker")

if not detector then error("No playerDetector found") end

local screen = term.current()

local RANGE = 100
local SWEEP_SPEED = 0.16
local CONTACT_TIME = 5
local PING_COOLDOWN = 1

local targets = {
    "Etharino",
    "Steve",
    "Alex"
}

local angle = 0
local beams = {}
local contacts = {}
local lastPing = {}
local lastW, lastH = 0, 0

local function writeAt(x, y, text, color)
    local w, h = screen.getSize()
    x = math.floor(x)
    y = math.floor(y)

    if x < 1 or y < 1 or x > w or y > h then return end

    screen.setCursorPos(x, y)
    screen.setTextColor(color or colors.white)
    screen.write(tostring(text):sub(1, w - x + 1))
end

local function eraseText(x, y, text)
    writeAt(x, y, string.rep(" ", #tostring(text)), colors.black)
end

local function getRadar()
    local w, h = screen.getSize()
    local cx = math.floor((w + 1) / 2)
    local cy = math.floor((h + 2) / 2)
    local radius = math.floor(math.min(w, h - 1) / 2) - 1

    if radius < 1 then radius = 1 end

    return w, h, cx, cy, radius
end

local function isOverworld(pos)
    if not pos.dimension then return true end
    return pos.dimension == "minecraft:overworld" or pos.dimension == "overworld"
end

local function drawStatic(w, cx, cy, radius)
    writeAt(1, 1, string.rep(" ", w), colors.black)
    writeAt(1, 1, "POCKET RADAR 0,0", colors.green)

    for deg = 0, 360, 15 do
        local rad = math.rad(deg)
        writeAt(cx + math.cos(rad) * radius, cy + math.sin(rad) * radius, "o", colors.green)
    end

    writeAt(cx, cy, "+", colors.lime)
end

local function nearPlayer(x, y, blips)
    for _, b in ipairs(blips) do
        local dx = x - b.x
        local dy = y - b.y

        if dx * dx + dy * dy <= 4 then
            return b
        end
    end

    return nil
end

local function ping(name, dist)
    if not speaker then return end

    local now = os.clock()
    if lastPing[name] and now - lastPing[name] < PING_COOLDOWN then return end

    lastPing[name] = now

    pcall(function()
        local pitch = 2 - math.min(dist / RANGE, 1)
        speaker.playSound("minecraft:block.note_block.bell", 1, pitch)
    end)
end

local function eraseContact(c)
    writeAt(c.x, c.y, " ", colors.black)

    if c.label then
        eraseText(c.x + 1, c.y, c.label)
    end
end

local function eraseBeam(beam)
    for _, p in ipairs(beam.points) do
        writeAt(p.x, p.y, " ", colors.black)
    end
end

local function drawBeam(beam, color)
    for _, p in ipairs(beam.points) do
        writeAt(p.x, p.y, "*", color)
    end
end

screen.setCursorBlink(false)
screen.setBackgroundColor(colors.black)
screen.clear()

while true do
    local now = os.clock()
    local w, h, cx, cy, radius = getRadar()
    local hiddenBlips = {}
    local currentPoints = {}
    local hit = nil

    if w ~= lastW or h ~= lastH then
        screen.setBackgroundColor(colors.black)
        screen.clear()
        lastW = w
        lastH = h
        beams = {}
        contacts = {}
    end

    for _, name in ipairs(targets) do
        local ok, pos = pcall(function()
            return detector.getPlayerPos(name)
        end)

        if ok and pos and pos.x and pos.z and isOverworld(pos) then
            -- Radar is centered on world X/Z 0,0.
            local dx = pos.x
            local dz = pos.z
            local dist = math.sqrt(dx * dx + dz * dz)

            if dist <= RANGE then
                local bx = math.floor(cx + (dx / RANGE) * radius + 0.5)
                local by = math.floor(cy + (dz / RANGE) * radius + 0.5)

                table.insert(hiddenBlips, {
                    name = name,
                    x = bx,
                    y = by,
                    dist = dist
                })
            end
        end
    end

    while #beams > 3 do
        eraseBeam(table.remove(beams))
    end

    drawStatic(w, cx, cy, radius)

    for name, c in pairs(contacts) do
        if c.expire <= now then
            eraseContact(c)
            contacts[name] = nil
        end
    end

    for r = 1, radius do
        local x = math.floor(cx + math.cos(angle) * r + 0.5)
        local y = math.floor(cy + math.sin(angle) * r + 0.5)

        table.insert(currentPoints, { x = x, y = y })

        local b = nearPlayer(x, y, hiddenBlips)
        if b then hit = b end
    end

    local currentHit = false

    if hit then
        currentHit = true
        ping(hit.name, hit.dist)

        if contacts[hit.name] then
            eraseContact(contacts[hit.name])
        end

        contacts[hit.name] = {
            x = hit.x,
            y = hit.y,
            label = hit.name:sub(1, 3),
            expire = now + CONTACT_TIME
        }
    end

    table.insert(beams, 1, {
        points = currentPoints,
        hit = currentHit
    })

    for name, c in pairs(contacts) do
        writeAt(c.x, c.y, "O", colors.red)

        if c.x + 4 <= w then
            writeAt(c.x + 1, c.y, c.label, colors.white)
        end
    end

    for i, beam in ipairs(beams) do
        local color

        if i == 4 then
            color = colors.gray
        elseif beam.hit then
            color = colors.red
        elseif i == 1 then
            color = colors.lime
        else
            color = colors.green
        end

        drawBeam(beam, color)
    end

    angle = angle + SWEEP_SPEED
    if angle > math.pi * 2 then
        angle = angle - math.pi * 2
    end

    sleep(0.15)
end
