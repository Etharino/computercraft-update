-- ============================================================
--  NARAMO NUCLEAR REACTOR CONTROL SYSTEM v2.4
--  ComputerCraft Multi-Monitor Edition
--  Compatible with: CC:Tweaked / ComputerCraft
-- ============================================================
--
--  SETUP INSTRUCTIONS:
--  1. Place a Computer (Advanced recommended) in your build
--  2. Attach monitors on the LEFT and RIGHT sides using cables
--     or direct placement. Name them via the peripheral API.
--  3. (Optional) Attach a speaker peripheral for alarms
--  4. (Optional) Wire a Redstone signal on the BACK for
--     actual reactor control (on = active, off = SCRAM)
--  5. Run this file: > reactor
--
--  PERIPHERAL LAYOUT:
--    - monMain  : large left monitor (status + dials)
--    - monCtrl  : right monitor (controls + log)
--    - speaker  : optional audio alarm
--
--  You can rename peripherals with the 'rename' command or
--  edit PERIPHERAL_NAMES below to match your setup.
-- ============================================================

-- ─── CONFIGURATION ──────────────────────────────────────────
local PERIPHERAL_NAMES = {
    monMain  = "monitor_0",   -- change to match your peripheral
    monCtrl  = "monitor_1",   -- change to match your peripheral
    speaker  = "speaker_0",   -- optional, set nil to disable
}

local REDSTONE_SIDE = "back"   -- side for reactor on/off signal

-- ─── REACTOR PHYSICS CONSTANTS ──────────────────────────────
local CFG = {
    maxTemp      = 2200,    -- K  -- max safe core temperature
    critTemp     = 1800,    -- K  -- critical temp threshold
    warnTemp     = 1400,    -- K  -- warning temp threshold
    coolTemp     = 900,     -- K  -- normal operating temp
    idleTemp     = 550,     -- K  -- idle / cold temp
    maxPressure  = 95,      -- %  -- max safe pressure
    critPressure = 88,      -- %  -- critical pressure
    warnPressure = 75,      -- %  -- warning pressure
    maxPower     = 5000,    -- MW -- rated output
    coolantMax   = 100,     -- %  -- coolant capacity
    fuelMax      = 100,     -- %  -- fuel capacity
    scramDelay   = 3,       -- s  -- scram insertion time
}

-- ─── GLOBALS ────────────────────────────────────────────────
local monMain, monCtrl, spk
local running    = true
local tickTimer  = nil
local TICK       = 0.5   -- update interval (seconds)

-- Reactor state
local state = {
    -- Operational
    active       = false,
    scrammed     = false,
    scramReason  = "",
    startupPhase = 0,    -- 0=off 1=warmup 2=online
    uptime       = 0,    -- seconds

    -- Physical values
    temperature  = 293,   -- K (room temp when off)
    pressure     = 0,     -- %
    powerOutput  = 0,     -- MW
    efficiency   = 0,     -- %
    coolantFlow  = 0,     -- %
    coolantLevel = 87,    -- %
    fuelLevel    = 74,    -- %
    rodPosition  = 100,   -- % inserted (100=full in = shutdown)
    neutronFlux  = 0,     -- arbitrary units

    -- Alarms
    alarmActive  = false,
    alarmType    = "NONE",
    alarmFlash   = false,

    -- Trend tracking (last 20 values)
    tempHistory  = {},
    powerHistory = {},

    -- Log
    eventLog     = {},
    logMax       = 8,
}

-- Control panel button state
local buttons = {
    -- Main controls
    { id="START",   x=3,  y=3,  w=12, h=3, label="REACTOR\nSTART",   color=colors.green,  active=false },
    { id="SCRAM",   x=17, y=3,  w=12, h=3, label="EMERGENCY\nSCRAM", color=colors.red,    active=false },
    { id="COOLANT", x=3,  y=8,  w=12, h=3, label="COOLANT\nBOOST",   color=colors.cyan,   active=false },
    { id="FLUSH",   x=17, y=8,  w=12, h=3, label="PRESSURE\nFLUSH",  color=colors.orange, active=false },

    -- Rod control
    { id="ROD_IN",  x=3,  y=13, w=12, h=3, label="RODS\nINSERT",     color=colors.yellow, active=false },
    { id="ROD_OUT", x=17, y=13, w=12, h=3, label="RODS\nWITHDRAW",   color=colors.lime,   active=false },

    -- Alarm
    { id="ACK",     x=3,  y=18, w=26, h=3, label="ACKNOWLEDGE ALARM",color=colors.purple, active=false },
}

-- ─── UTILITY ────────────────────────────────────────────────
local function clamp(v, mn, mx) return math.max(mn, math.min(mx, v)) end
local function lerp(a, b, t)    return a + (b - a) * t end
local function round(v, d)
    local f = 10^(d or 0)
    return math.floor(v * f + 0.5) / f
end

local function logEvent(msg)
    local entry = string.format("[%05ds] %s", state.uptime, msg)
    table.insert(state.eventLog, 1, entry)
    if #state.eventLog > state.logMax then
        table.remove(state.eventLog)
    end
end

local function triggerAlarm(reason)
    if not state.alarmActive then
        state.alarmActive = true
        state.alarmType   = reason
        logEvent("ALARM: " .. reason)
    end
end

local function clearAlarm()
    state.alarmActive = false
    state.alarmType   = "NONE"
    state.alarmFlash  = false
end

-- ─── REACTOR PHYSICS SIMULATION ─────────────────────────────
local function updatePhysics()
    local dt = TICK

    -- Effective rod insertion damps power (100%=off, 0%=full power)
    local rodEffect = 1 - (state.rodPosition / 100)

    if state.active and not state.scrammed then
        state.uptime = state.uptime + dt

        if state.startupPhase == 1 then
            -- Warm-up: 15 seconds to reach operating temp
            state.temperature = lerp(state.temperature, CFG.coolTemp, dt * 0.04)
            state.pressure    = lerp(state.pressure, 45, dt * 0.06)
            state.neutronFlux = lerp(state.neutronFlux, 30 * rodEffect, dt * 0.08)
            if state.temperature > CFG.coolTemp * 0.95 then
                state.startupPhase = 2
                logEvent("Reactor online – nominal power")
            end

        elseif state.startupPhase == 2 then
            -- Online operation
            local targetTemp = lerp(CFG.coolTemp, CFG.critTemp * 0.9,
                                    rodEffect * (state.coolantFlow < 30 and 1.3 or 1))
            local coolingFactor = 1 - clamp(state.coolantFlow / 100, 0, 1) * 0.6

            state.temperature = lerp(state.temperature,
                                     targetTemp * coolingFactor,
                                     dt * 0.03)

            -- Pressure tracks temperature
            local targetPressure = lerp(30, 90, rodEffect) *
                                   (state.temperature / CFG.coolTemp) *
                                   (1 - state.coolantFlow * 0.004)
            state.pressure = lerp(state.pressure,
                                  clamp(targetPressure, 0, 99),
                                  dt * 0.05)

            -- Neutron flux
            state.neutronFlux = lerp(state.neutronFlux,
                                     rodEffect * 100 * (state.temperature / CFG.critTemp),
                                     dt * 0.1)

            -- Power output
            local tempFactor = clamp((state.temperature - 400) / (CFG.coolTemp - 400), 0, 1)
            state.powerOutput = lerp(state.powerOutput,
                                     CFG.maxPower * rodEffect * tempFactor,
                                     dt * 0.05)

            -- Efficiency (best around 1100-1300K)
            local eff = 1 - math.abs(state.temperature - 1150) / 1200
            state.efficiency = clamp(eff * 100, 0, 100)

            -- Fuel depletion
            state.fuelLevel = math.max(0, state.fuelLevel - dt * 0.002 * rodEffect)

            -- Coolant consumption
            state.coolantLevel = math.max(0,
                state.coolantLevel - dt * 0.001 * (state.coolantFlow / 100))
        end

        -- Coolant boost decay
        if state.coolantFlow > 5 then
            state.coolantFlow = math.max(0, state.coolantFlow - dt * 2)
        end

    else
        -- Reactor off or scramming: cool down
        local coolRate = state.scrammed and 0.06 or 0.03
        state.temperature = lerp(state.temperature, 293, dt * coolRate)
        state.pressure    = lerp(state.pressure, 0, dt * 0.08)
        state.neutronFlux = lerp(state.neutronFlux, 0, dt * 0.15)
        state.powerOutput = lerp(state.powerOutput, 0, dt * 0.1)
        state.efficiency  = 0
        state.coolantFlow = 0
    end

    -- ── Auto-SCRAM logic ─────────────────────────────────────
    if state.active and not state.scrammed then
        if state.temperature >= CFG.maxTemp then
            state.scrammed   = true
            state.active     = false
            state.startupPhase = 0
            triggerAlarm("CORE OVERHEAT – AUTO SCRAM")
            logEvent("AUTO SCRAM: temp=" .. round(state.temperature, 0) .. "K")
        elseif state.pressure >= CFG.maxPressure then
            state.scrammed   = true
            state.active     = false
            state.startupPhase = 0
            triggerAlarm("OVER PRESSURE – AUTO SCRAM")
        elseif state.fuelLevel <= 0 then
            state.active     = false
            state.startupPhase = 0
            logEvent("FUEL DEPLETED – reactor shutdown")
        end
    end

    -- Reset scram flag once cool
    if state.scrammed and state.temperature < 400 and state.pressure < 5 then
        state.scrammed = false
        logEvent("Scram conditions cleared – safe to restart")
    end

    -- ── Alarm conditions ─────────────────────────────────────
    if state.active then
        if state.temperature >= CFG.critTemp then
            triggerAlarm("CRITICAL TEMPERATURE")
        elseif state.temperature >= CFG.warnTemp then
            triggerAlarm("HIGH TEMPERATURE")
        end
        if state.pressure >= CFG.critPressure then
            triggerAlarm("CRITICAL PRESSURE")
        end
    end

    -- Flash alarm beacon
    state.alarmFlash = state.alarmActive and not state.alarmFlash

    -- Track history
    table.insert(state.tempHistory, state.temperature)
    table.insert(state.powerHistory, state.powerOutput)
    if #state.tempHistory > 20 then table.remove(state.tempHistory, 1) end
    if #state.powerHistory > 20 then table.remove(state.powerHistory, 1) end

    -- Redstone output
    redstone.setOutput(REDSTONE_SIDE, state.active and not state.scrammed)

    -- Speaker alarm
    if spk and state.alarmFlash then
        pcall(function() spk.playNote("bit", 1, 15) end)
    end
end

-- ─── DRAW HELPERS ───────────────────────────────────────────
local function setBG(m, c) m.setBackgroundColor(c) end
local function setFG(m, c) m.setTextColor(c) end

local function write(m, x, y, text, fg, bg)
    if fg then setFG(m, fg) end
    if bg then setBG(m, bg) end
    m.setCursorPos(x, y)
    m.write(text)
end

local function fillRect(m, x, y, w, h, c)
    setBG(m, c)
    for row = y, y + h - 1 do
        m.setCursorPos(x, row)
        m.write(string.rep(" ", w))
    end
end

local function hLine(m, x, y, w, fg, bg, char)
    char = char or "\140"  -- horizontal line char
    write(m, x, y, string.rep(char, w), fg, bg)
end

local function border(m, x, y, w, h, fg, bg)
    setBG(m, bg or colors.black)
    setFG(m, fg or colors.gray)
    -- top
    m.setCursorPos(x, y)
    m.write("\151" .. string.rep("\140", w-2) .. "\148")
    -- bottom
    m.setCursorPos(x, y+h-1)
    m.write("\138" .. string.rep("\140", w-2) .. "\133")
    -- sides
    for row = y+1, y+h-2 do
        m.setCursorPos(x, row)     m.write("\149")
        m.setCursorPos(x+w-1, row) m.write("\149")
        -- fill interior
        for cx = x+1, x+w-2 do
            m.setCursorPos(cx, row) m.write(" ")
        end
    end
end

-- Draw a percentage bar
local function drawBar(m, x, y, w, pct, colorFill, colorEmpty, label)
    local filled = math.floor(w * clamp(pct, 0, 100) / 100)
    local empty  = w - filled
    setBG(m, colorFill)
    setFG(m, colors.white)
    m.setCursorPos(x, y)
    local bar = string.rep("\127", filled) .. ""
    setBG(m, colorEmpty or colors.gray)
    m.write(string.rep(" ", empty))
    setBG(m, colorFill)
    m.setCursorPos(x, y)
    m.write(string.rep("\127", filled))
    if label then
        write(m, x, y, label, colors.white, nil)
    end
end

-- Draw a circular-style dial (ASCII art gauge)
local function drawDial(m, cx, cy, value, maxVal, label, unit, warnVal, critVal)
    local pct = clamp(value / maxVal, 0, 1)
    local col
    if value >= critVal then col = colors.red
    elseif value >= warnVal then col = colors.orange
    else col = colors.lime
    end

    -- Outer ring
    local ring = {
        "  \7\7\7\7\7  ",
        " \7     \7 ",
        "\7       \7",
        "\7       \7",
        "\7       \7",
        " \7     \7 ",
        "  \7\7\7\7\7  ",
    }

    -- Draw ring
    for i, row in ipairs(ring) do
        write(m, cx-4, cy-3+i-1, row, col, colors.black)
    end

    -- Value inside
    local valStr = tostring(round(value, 0))
    local vx = cx - math.floor(#valStr / 2)
    write(m, vx, cy, valStr, colors.white, colors.black)
    write(m, cx-2, cy+1, unit, colors.lightGray, colors.black)

    -- Needle indicator (simplified: fill arc segments)
    -- Show a small needle arrow direction
    local angle = pct  -- 0..1
    local indicators = {
        [true]  = { "\30", cx,   cy-2 },   -- up (high)
        [false] = { "\31", cx,   cy+2 },   -- down (low)
    }
    -- Simple indicator: color bar below dial
    write(m, cx-3, cy+3, "[", colors.gray, colors.black)
    local barW = 6
    local fillW = math.floor(pct * barW)
    for i = 1, barW do
        local bc = i <= fillW and col or colors.gray
        write(m, cx-3+i, cy+3, "\127", bc, colors.black)
    end
    write(m, cx+4, cy+3, "]", colors.gray, colors.black)

    -- Label
    local lx = cx - math.floor(#label / 2)
    write(m, lx, cy+4, label, colors.lightGray, colors.black)
end

-- ─── MAIN MONITOR DRAW ──────────────────────────────────────
local function drawMainMonitor()
    local m = monMain
    if not m then return end

    local W, H = m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()

    -- ── Header ───────────────────────────────────────────────
    fillRect(m, 1, 1, W, 2, colors.gray)
    local title = "NARAMO NUCLEAR REACTOR CONTROL SYSTEM"
    write(m, math.floor((W - #title) / 2) + 1, 1,
          title, colors.white, colors.gray)

    local statusStr
    local statusColor
    if state.scrammed then
        statusStr  = "  \7 SCRAM \7  "
        statusColor = state.alarmFlash and colors.red or colors.orange
    elseif state.active and state.startupPhase == 1 then
        statusStr  = "  STARTUP  "
        statusColor = colors.yellow
    elseif state.active then
        statusStr  = "  ONLINE   "
        statusColor = colors.lime
    else
        statusStr  = "  OFFLINE  "
        statusColor = colors.gray
    end
    write(m, W - #statusStr - 1, 2, statusStr, colors.black, statusColor)

    local timeStr = string.format("UP: %02d:%02d:%02d",
        math.floor(state.uptime / 3600),
        math.floor((state.uptime % 3600) / 60),
        math.floor(state.uptime % 60))
    write(m, 2, 2, timeStr, colors.lightGray, colors.gray)

    -- ── Alarm banner ─────────────────────────────────────────
    if state.alarmActive then
        local alarmBG = state.alarmFlash and colors.red or colors.orange
        fillRect(m, 1, 3, W, 1, alarmBG)
        local aMsg = string.format("\7 ALARM: %s \7", state.alarmType)
        write(m, math.floor((W - #aMsg) / 2) + 1, 3,
              aMsg, colors.white, alarmBG)
    else
        fillRect(m, 1, 3, W, 1, colors.black)
        write(m, 2, 3, "System nominal", colors.green, colors.black)
    end

    -- ── Dials row ────────────────────────────────────────────
    -- Temperature dial (col ~12)
    drawDial(m, 9, 11,
             state.temperature, CFG.maxTemp,
             "TEMP", "K",
             CFG.warnTemp, CFG.critTemp)

    -- Pressure dial (col ~22)
    drawDial(m, 22, 11,
             state.pressure, 100,
             "PRESSURE", "%",
             CFG.warnPressure, CFG.critPressure)

    -- Power dial (col ~32)
    drawDial(m, 35, 11,
             state.powerOutput, CFG.maxPower,
             "OUTPUT", "MW",
             CFG.maxPower * 0.7, CFG.maxPower * 0.9)

    -- Neutron flux (col ~45)
    drawDial(m, 48, 11,
             state.neutronFlux, 100,
             "N-FLUX", "nu",
             60, 85)

    -- ── Status bars ──────────────────────────────────────────
    local barY = 20

    write(m, 2, barY,   "FUEL LEVEL  ", colors.white, colors.black)
    local fuelCol = state.fuelLevel > 25 and colors.lime or colors.orange
    drawBar(m, 14, barY, W - 22, state.fuelLevel, fuelCol, colors.gray)
    write(m, W - 7, barY, string.format("%5.1f%%", state.fuelLevel),
          colors.white, colors.black)

    write(m, 2, barY+1, "COOLANT     ", colors.white, colors.black)
    local coolCol = state.coolantLevel > 30 and colors.cyan or colors.red
    drawBar(m, 14, barY+1, W - 22, state.coolantLevel, coolCol, colors.gray)
    write(m, W - 7, barY+1, string.format("%5.1f%%", state.coolantLevel),
          colors.white, colors.black)

    write(m, 2, barY+2, "COOLANT FLW ", colors.white, colors.black)
    drawBar(m, 14, barY+2, W - 22, state.coolantFlow, colors.blue, colors.gray)
    write(m, W - 7, barY+2, string.format("%5.1f%%", state.coolantFlow),
          colors.white, colors.black)

    write(m, 2, barY+3, "ROD INSERT  ", colors.white, colors.black)
    drawBar(m, 14, barY+3, W - 22, state.rodPosition, colors.purple, colors.gray)
    write(m, W - 7, barY+3, string.format("%5.1f%%", state.rodPosition),
          colors.white, colors.black)

    write(m, 2, barY+4, "EFFICIENCY  ", colors.white, colors.black)
    local effCol = state.efficiency > 60 and colors.lime
                   or state.efficiency > 30 and colors.yellow or colors.red
    drawBar(m, 14, barY+4, W - 22, state.efficiency, effCol, colors.gray)
    write(m, W - 7, barY+4, string.format("%5.1f%%", state.efficiency),
          colors.white, colors.black)

    -- ── Power trend graph ────────────────────────────────────
    local graphY = barY + 6
    local graphH = 5
    local graphW = W - 4

    write(m, 2, graphY, "POWER OUTPUT TREND (MW)", colors.lightGray, colors.black)
    write(m, 2, graphY + graphH + 1,
          string.format("Now: %.0f MW  Peak: %.0f MW  Eff: %.1f%%",
              state.powerOutput,
              CFG.maxPower,
              state.efficiency),
          colors.lime, colors.black)

    -- Graph border
    for gy = graphY + 1, graphY + graphH do
        write(m, 2, gy, "\149", colors.gray, colors.black)
        write(m, W - 1, gy, "\149", colors.gray, colors.black)
        for gx = 3, W - 2 do
            m.setCursorPos(gx, gy)
            m.write(" ")
        end
    end
    hLine(m, 2, graphY + graphH + 1, W - 2, colors.gray, colors.black, "\140")

    -- Plot history
    local hLen = #state.powerHistory
    if hLen > 1 then
        local plotW = W - 4
        for i, pv in ipairs(state.powerHistory) do
            local px = math.floor((i / hLen) * plotW) + 2
            local py = graphY + graphH -
                       math.floor(clamp(pv / CFG.maxPower, 0, 1) * (graphH - 1))
            local pc = pv > CFG.maxPower * 0.8 and colors.orange
                       or colors.lime
            write(m, px, py, "\7", pc, colors.black)
        end
    end

    -- ── Footer ───────────────────────────────────────────────
    fillRect(m, 1, H, W, 1, colors.gray)
    write(m, 2, H,
          string.format("T:%5.0fK  P:%4.1f%%  OUT:%6.1fMW  FLUX:%5.1f",
              state.temperature, state.pressure,
              state.powerOutput, state.neutronFlux),
          colors.white, colors.gray)
end

-- ─── CONTROL MONITOR DRAW ───────────────────────────────────
local function drawCtrlMonitor()
    local m = monCtrl
    if not m then return end

    local W, H = m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()

    -- Header
    fillRect(m, 1, 1, W, 1, colors.gray)
    write(m, 2, 1, "OPERATOR CONTROL PANEL", colors.white, colors.gray)

    -- Draw buttons
    for _, btn in ipairs(buttons) do
        local bg = btn.active and colors.white or btn.color
        local fg = btn.active and btn.color or colors.black
        fillRect(m, btn.x, btn.y, btn.w, btn.h, bg)

        -- Split label on \n
        local lines = {}
        for line in btn.label:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        local midY = btn.y + math.floor(btn.h / 2)
        if #lines == 1 then
            local lx = btn.x + math.floor((btn.w - #lines[1]) / 2)
            write(m, lx, midY, lines[1], fg, bg)
        else
            local off = math.floor(#lines / 2)
            for i, line in ipairs(lines) do
                local lx = btn.x + math.floor((btn.w - #line) / 2)
                write(m, lx, midY - off + i - 1, line, fg, bg)
            end
        end

        -- Disabled overlay for START when scrammed
        if btn.id == "START" and (state.scrammed or state.active) then
            fillRect(m, btn.x, btn.y, btn.w, btn.h, colors.gray)
            local lbl = state.active and "RUNNING" or "SCRAMMED"
            write(m, btn.x + math.floor((btn.w - #lbl) / 2), btn.y + 1,
                  lbl, colors.lightGray, colors.gray)
        end
    end

    -- Rod position large display
    local rodY = 23
    write(m, 2, rodY, "CONTROL ROD POSITION", colors.lightGray, colors.black)
    fillRect(m, 2, rodY+1, W-2, 3, colors.black)

    -- Rod visual
    local rodW = W - 4
    local rodFill = math.floor(state.rodPosition / 100 * rodW)
    write(m, 2, rodY+1, "[", colors.gray, colors.black)
    setBG(m, colors.purple)
    m.setCursorPos(3, rodY+1)
    m.write(string.rep("|", rodFill))
    setBG(m, colors.black)
    m.write(string.rep(".", rodW - rodFill))
    write(m, 3 + rodW, rodY+1, "]", colors.gray, colors.black)

    local rodLabel = string.format("%.0f%% INSERTED", state.rodPosition)
    if state.rodPosition > 95 then rodLabel = rodLabel .. " (SHUTDOWN)"
    elseif state.rodPosition < 20 then rodLabel = rodLabel .. " (FULL POWER)"
    end
    write(m, 2, rodY+2, rodLabel, colors.white, colors.black)

    -- Quick stats
    local statY = rodY + 4
    write(m, 2, statY,   "CORE TEMP:", colors.lightGray, colors.black)
    local tc = state.temperature >= CFG.critTemp and colors.red
               or state.temperature >= CFG.warnTemp and colors.orange
               or colors.lime
    write(m, 14, statY, string.format("%.0f K", state.temperature), tc, colors.black)

    write(m, 2, statY+1, "PRESSURE: ", colors.lightGray, colors.black)
    local pc = state.pressure >= CFG.critPressure and colors.red
               or state.pressure >= CFG.warnPressure and colors.orange
               or colors.lime
    write(m, 14, statY+1, string.format("%.1f %%", state.pressure), pc, colors.black)

    write(m, 2, statY+2, "OUTPUT:   ", colors.lightGray, colors.black)
    write(m, 14, statY+2, string.format("%.0f MW", state.powerOutput),
          colors.cyan, colors.black)

    write(m, 2, statY+3, "FUEL:     ", colors.lightGray, colors.black)
    local fc = state.fuelLevel > 25 and colors.lime or colors.red
    write(m, 14, statY+3, string.format("%.1f %%", state.fuelLevel), fc, colors.black)

    -- Event log
    local logY = statY + 5
    write(m, 2, logY, "EVENT LOG", colors.yellow, colors.black)
    hLine(m, 2, logY+1, W-2, colors.gray, colors.black)
    for i, entry in ipairs(state.eventLog) do
        local ey = logY + 1 + i
        if ey > H then break end
        local ec = entry:find("ALARM") and colors.orange
                   or entry:find("SCRAM") and colors.red
                   or entry:find("online") and colors.lime
                   or colors.lightGray
        write(m, 2, ey, entry:sub(1, W-2), ec, colors.black)
    end

    -- Footer
    fillRect(m, 1, H, W, 1, colors.gray)
    write(m, 2, H, "Click buttons to operate | SCRAM=emergency stop",
          colors.white, colors.gray)
end

-- ─── BUTTON HANDLER ─────────────────────────────────────────
local function handleButtonClick(m, mx, my)
    for _, btn in ipairs(buttons) do
        if mx >= btn.x and mx < btn.x + btn.w and
           my >= btn.y and my < btn.y + btn.h then

            if btn.id == "START" and not state.active and not state.scrammed then
                state.active       = true
                state.startupPhase = 1
                state.rodPosition  = 70  -- partial insertion for startup
                logEvent("Reactor startup initiated")

            elseif btn.id == "SCRAM" then
                state.active       = false
                state.scrammed     = true
                state.startupPhase = 0
                state.rodPosition  = 100
                state.scramReason  = "MANUAL SCRAM"
                logEvent("MANUAL SCRAM initiated")
                triggerAlarm("MANUAL SCRAM")

            elseif btn.id == "COOLANT" then
                state.coolantFlow = math.min(100, state.coolantFlow + 40)
                logEvent("Coolant boost engaged")

            elseif btn.id == "FLUSH" then
                if state.pressure > 30 then
                    state.pressure = state.pressure * 0.7
                    logEvent("Pressure flush: " .. round(state.pressure, 1) .. "%")
                end

            elseif btn.id == "ROD_IN" then
                state.rodPosition = math.min(100, state.rodPosition + 10)
                logEvent("Rods inserted: " .. round(state.rodPosition, 0) .. "%")

            elseif btn.id == "ROD_OUT" then
                if not state.scrammed then
                    state.rodPosition = math.max(0, state.rodPosition - 10)
                    logEvent("Rods withdrawn: " .. round(state.rodPosition, 0) .. "%")
                end

            elseif btn.id == "ACK" then
                clearAlarm()
                logEvent("Alarm acknowledged by operator")
            end

            -- Flash button
            btn.active = true
            drawCtrlMonitor()
            os.sleep(0.1)
            btn.active = false
            return true
        end
    end
    return false
end

-- ─── KEYBOARD CONTROLS (on the computer terminal) ───────────
local function handleKey(key)
    if key == keys.s then
        -- Start
        if not state.active and not state.scrammed then
            state.active       = true
            state.startupPhase = 1
            state.rodPosition  = 70
            logEvent("Reactor startup (keyboard)")
        end
    elseif key == keys.x then
        -- SCRAM
        state.active       = false
        state.scrammed     = true
        state.startupPhase = 0
        state.rodPosition  = 100
        logEvent("MANUAL SCRAM (keyboard)")
        triggerAlarm("MANUAL SCRAM")
    elseif key == keys.c then
        state.coolantFlow = math.min(100, state.coolantFlow + 40)
    elseif key == keys.f then
        if state.pressure > 30 then
            state.pressure = state.pressure * 0.7
        end
    elseif key == keys.up then
        state.rodPosition = math.min(100, state.rodPosition + 5)
    elseif key == keys.down then
        if not state.scrammed then
            state.rodPosition = math.max(0, state.rodPosition - 5)
        end
    elseif key == keys.a then
        clearAlarm()
    elseif key == keys.q then
        running = false
    end
end

-- ─── SETUP ──────────────────────────────────────────────────
local function setup()
    -- Try to find monitors
    for _, side in ipairs({"left", "right", "top", "bottom", "front", "back"}) do
        if peripheral.isPresent(side) and peripheral.getType(side) == "monitor" then
            if not monMain then
                monMain = peripheral.wrap(side)
            elseif not monCtrl then
                monCtrl = peripheral.wrap(side)
            end
        end
    end

    -- Also try by name
    if peripheral.isPresent(PERIPHERAL_NAMES.monMain) then
        monMain = peripheral.wrap(PERIPHERAL_NAMES.monMain)
    end
    if peripheral.isPresent(PERIPHERAL_NAMES.monCtrl) then
        monCtrl = peripheral.wrap(PERIPHERAL_NAMES.monCtrl)
    end
    if PERIPHERAL_NAMES.speaker and peripheral.isPresent(PERIPHERAL_NAMES.speaker) then
        spk = peripheral.wrap(PERIPHERAL_NAMES.speaker)
    end

    -- Configure monitors
    local function configMon(mon, scale)
        if mon then
            mon.setTextScale(scale or 0.5)
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.white)
            mon.clear()
        end
    end

    configMon(monMain, 0.5)
    configMon(monCtrl, 0.5)

    -- Initial log entries
    logEvent("System boot – NARAMO NRCS v2.4")
    logEvent("Monitors: " .. (monMain and "main OK" or "main MISSING")
             .. " / " .. (monCtrl and "ctrl OK" or "ctrl MISSING"))
    logEvent("All systems nominal – standby")

    -- Terminal info
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("=== NARAMO REACTOR CONTROL SYSTEM ===")
    print("Monitors found: " .. (monMain and "LEFT" or "none")
          .. " / " .. (monCtrl and "RIGHT" or "none"))
    print("")
    print("KEYBOARD CONTROLS:")
    print("  S       - Start reactor")
    print("  X       - SCRAM (emergency shutdown)")
    print("  C       - Coolant boost")
    print("  F       - Pressure flush")
    print("  UP/DOWN - Control rod position")
    print("  A       - Acknowledge alarm")
    print("  Q       - Quit")
    print("")
    print("Click monitor buttons to operate.")
    print("Running... (Q to quit)")
end

-- ─── MAIN LOOP ──────────────────────────────────────────────
local function main()
    setup()

    tickTimer = os.startTimer(TICK)

    while running do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == tickTimer then
            updatePhysics()
            drawMainMonitor()
            drawCtrlMonitor()
            tickTimer = os.startTimer(TICK)

        elseif event == "key" then
            handleKey(p1)

        elseif event == "monitor_touch" then
            -- p1=side, p2=x, p3=y
            local m = nil
            for _, side in ipairs({"left","right","top","bottom","front","back"}) do
                if p1 == side or p1 == PERIPHERAL_NAMES.monCtrl then
                    m = monCtrl
                    break
                end
            end
            -- Try control monitor first (buttons live there)
            if monCtrl then
                handleButtonClick(monCtrl, p2, p3)
            end
        end
    end

    -- Cleanup
    if monMain then monMain.clear() end
    if monCtrl then monCtrl.clear() end
    redstone.setOutput(REDSTONE_SIDE, false)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Reactor control system shutdown.")
end

main()
