local detector = peripheral.find("playerDetector")
if not detector then error("No playerDetector found") end

local screen = term.current()
screen.setCursorBlink(false)
screen.setBackgroundColor(colors.black)
screen.clear()

local MIN_RANGE = 50
local RANGE_STEP = 50
local REFRESH = 0.35
local SELF_DETECT_RANGE = 2.5
local STALE_TIME = 5

local modeList = { "FOLLOW", "ORIGIN", "PLAYER" }
local dimList = { "ALL", "OW", "NETHER", "END" }

local modeIndex = 1
local dimIndex = 2
local autoZoom = true
local manualRange = 100
local selectedIndex = 1
local waypoint = nil
local cannonMode = false

local lastRel = {}
local stale = {}
local oldChars = {}
local oldFg = {}
local oldBg = {}

local function blitColor(c)
    return colors.toBlit(c or colors.white)
end

local function dimName(pos)
    local d = pos.dimension
    if not d then return "OW" end
    if d == "minecraft:overworld" or d == "overworld" then return "OW" end
    if d == "minecraft:the_nether" or d == "the_nether" or d == "nether" then return "NETHER" end
    if d == "minecraft:the_end" or d == "the_end" or d == "end" then return "END" end
    return tostring(d)
end

local function dimAllowed(pos)
    local filter = dimList[dimIndex]
    if filter == "ALL" then return true end
    return dimName(pos) == filter
end

local function getPlayerPos(name)
    local ok, pos = pcall(function()
        return detector.getPlayerPos(name)
    end)

    if ok and pos and pos.x and pos.z then
        return pos
    end

    return nil
end

local function getOnlineNames()
    local names = {}

    local ok, online = pcall(function()
        return detector.getOnlinePlayers()
    end)

    if ok and type(online) == "table" then
        for _, p in pairs(online) do
            if type(p) == "string" then
                table.insert(names, p)
            elseif type(p) == "table" and p.name then
                table.insert(names, p.name)
            end
        end
    end

    table.sort(names)
    return names
end

local function getHolderName()
    local ok, nearby = pcall(function()
        return detector.getPlayersInRange(SELF_DETECT_RANGE)
    end)

    if ok and type(nearby) == "table" then
        for _, p in pairs(nearby) do
            if type(p) == "string" then return p end
            if type(p) == "table" and p.name then return p.name end
        end
    end

    return nil
end

local function roundRange(dist)
    local r = math.ceil(dist / RANGE_STEP) * RANGE_STEP
    if r < MIN_RANGE then r = MIN_RANGE end
    return r
end

local function getArrow(dx, dz)
    if math.abs(dx) < 0.1 and math.abs(dz) < 0.1 then return "O" end

    if math.abs(dx) > math.abs(dz) then
        if dx > 0 then return ">" else return "<" end
    else
        if dz > 0 then return "v" else return "^" end
    end
end

local function getDir(dx, dz)
    local ns = ""
    local ew = ""

    if dz < -2 then ns = "N" elseif dz > 2 then ns = "S" end
    if dx > 2 then ew = "E" elseif dx < -2 then ew = "W" end

    if ns == "" and ew == "" then return "HERE" end
    return ns .. ew
end

local function threatColor(dist, range, staleFlag)
    if staleFlag then return colors.gray end
    if dist <= range * 0.25 then return colors.red end
    if dist <= range * 0.55 then return colors.yellow end
    return colors.white
end

local function makeFrame(w, h)
    local chars, fgs, bgs = {}, {}, {}

    for y = 1, h do
        chars[y], fgs[y], bgs[y] = {}, {}, {}
        for x = 1, w do
            chars[y][x] = " "
            fgs[y][x] = blitColor(colors.white)
            bgs[y][x] = blitColor(colors.black)
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
            fgs[y][px] = blitColor(color or colors.white)
            bgs[y][px] = blitColor(colors.black)
        end
    end
end

local function flush(chars, fgs, bgs, w, h)
    for y = 1, h do
        if not oldChars[y] then
            oldChars[y], oldFg[y], oldBg[y] = {}, {}, {}
        end

        for x = 1, w do
            local c = chars[y][x]
            local f = fgs[y][x]
            local b = bgs[y][x]

            if oldChars[y][x] ~= c or oldFg[y][x] ~= f or oldBg[y][x] ~= b then
                screen.setCursorPos(x, y)
                screen.blit(c, f, b)
                oldChars[y][x] = c
                oldFg[y][x] = f
                oldBg[y][x] = b
            end
        end
    end
end

local function worldToMap(dx, dz, cx, cy, radiusX, radiusY, range)
    local x = cx + (dx / range) * radiusX
    local y = cy + (dz / range) * radiusY
    return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function drawGrid(chars, fgs, bgs, w, h, cx, cy)
    for x = 1, w do
        if x % 5 == 0 then put(chars, fgs, bgs, x, cy, "-", colors.gray) end
    end

    for y = 1, h do
        if y % 3 == 0 then put(chars, fgs, bgs, cx, y, "|", colors.gray) end
    end

    put(chars, fgs, bgs, cx, cy, "+", colors.lime)
    put(chars, fgs, bgs, cx, 1, "N", colors.white)
end

local function handleKey(key)
    if key == keys.m then
        modeIndex = modeIndex + 1
        if modeIndex > #modeList then modeIndex = 1 end
    elseif key == keys.d then
        dimIndex = dimIndex + 1
        if dimIndex > #dimList then dimIndex = 1 end
    elseif key == keys.z then
        autoZoom = not autoZoom
    elseif key == keys.equals or key == keys.numPadAdd then
        manualRange = manualRange + RANGE_STEP
        autoZoom = false
    elseif key == keys.minus or key == keys.numPadSubtract then
        manualRange = manualRange - RANGE_STEP
        if manualRange < MIN_RANGE then manualRange = MIN_RANGE end
        autoZoom = false
    elseif key == keys.tab then
        selectedIndex = selectedIndex + 1
    elseif key == keys.p then
        waypoint = "SET"
    elseif key == keys.c then
        cannonMode = not cannonMode
    end
end

local timer = os.startTimer(0)

while true do
    local event, a = os.pullEvent()

    if event == "key" then
        handleKey(a)
    elseif event == "timer" and a == timer then
        local now = os.clock()
        local w, h = screen.getSize()
        local chars, fgs, bgs = makeFrame(w, h)

        local holder = getHolderName()
        local holderPos = holder and getPlayerPos(holder) or nil
        local online = getOnlineNames()

        if selectedIndex > #online then selectedIndex = 1 end
        local selectedName = online[selectedIndex]

        local centerPos = nil
        local mode = modeList[modeIndex]

        if mode == "FOLLOW" then
            centerPos = holderPos
        elseif mode == "ORIGIN" then
            centerPos = { x = 0, z = 0 }
        elseif mode == "PLAYER" and selectedName then
            centerPos = getPlayerPos(selectedName)
        end

        if waypoint == "SET" and holderPos then
            waypoint = { x = holderPos.x, z = holderPos.z }
        end

        if not centerPos then
            put(chars, fgs, bgs, 1, 1, "NO CENTER POS", colors.red)
            put(chars, fgs, bgs, 1, 2, "Hold pocket or pick player", colors.yellow)
        else
            local cx = math.floor((w + 1) / 2)
            local cy = math.floor((h + 1) / 2)
            local radiusX = math.max(1, math.min(cx - 1, w - cx))
            local radiusY = math.max(1, math.min(cy - 1, h - cy))

            local players = {}
            local farthest = MIN_RANGE

            for _, name in ipairs(online) do
                if name ~= holder then
                    local pos = getPlayerPos(name)

                    if pos and dimAllowed(pos) then
                        local dx = pos.x - centerPos.x
                        local dz = pos.z - centerPos.z
                        local dist = math.sqrt(dx * dx + dz * dz)

                        stale[name] = {
                            x = pos.x,
                            z = pos.z,
                            dx = dx,
                            dz = dz,
                            dim = dimName(pos),
                            seen = now
                        }

                        if dist > farthest then farthest = dist end

                        table.insert(players, {
                            name = name,
                            dx = dx,
                            dz = dz,
                            dist = dist,
                            stale = false
                        })
                    end
                end
            end

            for name, s in pairs(stale) do
                if now - s.seen <= STALE_TIME and name ~= holder then
                    local already = false
                    for _, p in ipairs(players) do
                        if p.name == name then already = true end
                    end

                    if not already then
                        local dx = s.x - centerPos.x
                        local dz = s.z - centerPos.z
                        local dist = math.sqrt(dx * dx + dz * dz)

                        table.insert(players, {
                            name = name,
                            dx = dx,
                            dz = dz,
                            dist = dist,
                            stale = true
                        })
                    end
                elseif now - s.seen > STALE_TIME then
                    stale[name] = nil
                end
            end

            local range = autoZoom and roundRange(farthest) or manualRange

            drawGrid(chars, fgs, bgs, w, h, cx, cy)

            local zoomText = autoZoom and "A" or "M"
            put(chars, fgs, bgs, 1, 1, mode .. " " .. dimList[dimIndex], colors.green)
            put(chars, fgs, bgs, 1, 2, "R" .. range .. " " .. zoomText, colors.green)

            if holder then
                put(chars, fgs, bgs, 1, h, holder:sub(1, 8), colors.lime)
            end

            if waypoint and waypoint ~= "SET" then
                local wx = waypoint.x - centerPos.x
                local wz = waypoint.z - centerPos.z
                local mx, my = worldToMap(wx, wz, cx, cy, radiusX, radiusY, range)

                put(chars, fgs, bgs, mx, my, "W", colors.blue)
            end

            table.sort(players, function(a, b) return a.dist < b.dist end)

            for _, p in ipairs(players) do
                local mx, my = worldToMap(p.dx, p.dz, cx, cy, radiusX, radiusY, range)

                local last = lastRel[p.name]
                local marker = "O"

                if last then
                    marker = getArrow(p.dx - last.dx, p.dz - last.dz)
                end

                local color = threatColor(p.dist, range, p.stale)
                put(chars, fgs, bgs, mx, my, marker, color)

                if mx + 4 <= w then
                    put(chars, fgs, bgs, mx + 1, my, p.name:sub(1, 3), color)
                elseif mx - 3 >= 1 then
                    put(chars, fgs, bgs, mx - 3, my, p.name:sub(1, 3), color)
                end

                lastRel[p.name] = { dx = p.dx, dz = p.dz }
            end

            local listW = math.min(18, w)
            local listX = math.max(1, w - listW + 1)
            local listH = math.min(6, h - 2)
            local listY = math.max(3, h - listH + 1)

            put(chars, fgs, bgs, listX, listY - 1, "PLAYERS", colors.green)

            for i = 1, math.min(listH, #players) do
                local p = players[i]
                local dir = getDir(p.dx, p.dz)
                local color = threatColor(p.dist, range, p.stale)
                local line = p.name:sub(1, 5) .. " " .. math.floor(p.dist) .. " " .. dir
                put(chars, fgs, bgs, listX, listY + i - 1, line, color)
            end

            if cannonMode and selectedName then
                for _, p in ipairs(players) do
                    if p.name == selectedName then
                        put(chars, fgs, bgs, 1, 3, "CANNON " .. selectedName:sub(1, 5), colors.red)
                        put(chars, fgs, bgs, 1, 4, "X " .. math.floor(p.dx) .. " Z " .. math.floor(p.dz), colors.red)
                        put(chars, fgs, bgs, 1, 5, "D " .. math.floor(p.dist), colors.red)
                    end
                end
            end
        end

        flush(chars, fgs, bgs, w, h)
        timer = os.startTimer(REFRESH)
    end
end
