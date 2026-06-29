-- ============================================================
--  NARAMO NUCLEAR POWER PLANT CONTROL SYSTEM  v4.0
--  ComputerCraft / CC:Tweaked  –  Multi-Monitor Edition
-- ============================================================
--
--  MONITOR LAYOUT (3 monitors):
--    monOver  – Large central OVERVIEW screen
--    monCtrl  – Operator CONTROL PANEL
--    monSync  – SYNCHROSCOPE / TURBINE panel
--
--  PERIPHERAL NAMES: edit PNAMES below.
--  Use peripheral.getNames() in-game to list peripherals.
--
--  STARTUP SEQUENCE:
--    1. Shift manager authorizes ignition (password prompt)
--    2. Operator starts shutdown pumps
--    3. Operator hits IGNITE
--
--  KEYBOARD (host computer terminal):
--    A   – Ack all alarms
--    Q   – Quit
-- ============================================================

-- ╔══════════════════════════════════════════╗
-- ║  CONFIG                                  ║
-- ╚══════════════════════════════════════════╝
local PNAMES = {
    monOver = "monitor_0",
    monCtrl = "monitor_1",
    monSync = "monitor_2",
    speaker = "speaker_0",   -- set nil to disable
}

local SHIFT_MANAGER = "Etharino"   -- authorization name

local RS = {
    reactor  = "back",
    turbine1 = "right",
    turbine2 = "left",
}

local TICK = 0.5  -- seconds per physics update

-- ╔══════════════════════════════════════════╗
-- ║  PHYSICS CONSTANTS                       ║
-- ╚══════════════════════════════════════════╝
local C = {
    -- Temperatures (K)
    T_ROOM      = 293,
    T_STALL     = 323,
    T_IGNITE    = 650,    -- rods/coolant take over above this
    T_SYNC_OPT  = 1420,   -- optimal turbine sync temperature
    T_MELTDOWN  = 3120,
    T_SAVE_MAX  = 800,    -- must reach this within 4 min of meltdown
    T_SCRAM_TARGET = 100, -- rod effect target during scram cooling

    -- Pressure (kPa)
    P_STALL     = 101.3,
    P_OPER      = 6895,
    P_WARN      = 8274,
    P_CRIT      = 10342,
    P_MAX       = 12411,

    -- Power
    MW_RATED    = 3200,
    MW_TURB     = 1500,   -- per turbine at full load

    -- Feedwater
    FW_WARN     = 60,
    FW_CRIT     = 30,
    FW_MAX      = 100,

    -- Turbine
    RPM_SYNC    = 3000,
    RPM_EXPLODE = 5000,
    FLOW_OPT    = 3.61,   -- m3/s optimal sync flow

    -- Relief valves
    RV_COOL     = 75,     -- total K removed
    RV_RATE     = 7.5,    -- K/s
    RV_DURATION = 10,     -- seconds
    RV_COOLDOWN = 90,     -- seconds

    -- Meltdown save window
    MELTDOWN_SAVE_TIME = 240,  -- 4 minutes in seconds
}

-- ╔══════════════════════════════════════════╗
-- ║  STATE                                   ║
-- ╚══════════════════════════════════════════╝
local monOver, monCtrl, monSync, spk

local running = true

-- Startup authorization
local auth = {
    ignitionAuthorized = false,
    pumpsOn            = false,
    awaitingName       = false,   -- showing name input prompt
    nameBuffer         = "",
}

-- Reactor core
local reactor = {
    phase          = 0,   -- 0=off 1=authorized 2=pumps 3=igniting 4=online 5=scram 6=meltdown
    temperature    = C.T_STALL,
    pressure       = C.P_STALL,
    rodPos         = 100,         -- % inserted (100=full in)
    coolantOn      = false,
    feedwaterOn    = false,
    neutronFlux    = 0,
    thermalMW      = 0,
    uptime         = 0,

    -- Meltdown
    meltdownActive   = false,
    meltdownTimer    = 0,    -- seconds since meltdown started
    meltdownMult     = 0,    -- starts near 0, rises over time
    meltdownSaved    = false,

    -- Relief valves (4 total)
    rvs = {
        { active=false, timer=0, cooldown=0 },
        { active=false, timer=0, cooldown=0 },
        { active=false, timer=0, cooldown=0 },
        { active=false, timer=0, cooldown=0 },
    },
}

-- Turbines (2 units)
local turbines = {
    {
        id=1, name="TG-1",
        online=false, synced=false, broken=false,
        rpm=0, load=0, steamFlow=0, breaker=false,
        -- Synchroscope
        scopeAngle   = 0,    -- 0..360 degrees, 0=top=green dot
        rpmDelta     = 0,    -- RPM above/below sync
        flowRate     = 0,    -- m3/s
        flowStep     = 0,    -- -2,-1,0,1,2  (--,-,N,+,++)
        rpmSpeed     = "S",  -- S/M/F
        -- Repair
        repairPrompt = false,
        repairScreen = nil,
        repairTimer  = 0,
    },
    {
        id=2, name="TG-2",
        online=false, synced=false, broken=false,
        rpm=0, load=0, steamFlow=0, breaker=false,
        scopeAngle   = 0,
        rpmDelta     = 0,
        flowRate     = 0,
        flowStep     = 0,
        rpmSpeed     = "S",
        repairPrompt = false,
        repairScreen = nil,
        repairTimer  = 0,
    },
}

-- Demand
local demandMW    = 800
local generatedMW = 0

-- Alarms
local alarms    = {}
local alarmFlash = false

-- Event log
local eventLog  = {}
local LOG_MAX   = 14

-- ╔══════════════════════════════════════════╗
-- ║  UTILITIES                               ║
-- ╚══════════════════════════════════════════╝
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function lerp(a,b,t)  return a+(b-a)*t end
local function rnd(v,d)
    local f=10^(d or 0); return math.floor(v*f+0.5)/f
end

local function log(msg)
    local ts = string.format("[%02d:%02d:%02d]",
        math.floor(reactor.uptime/3600),
        math.floor((reactor.uptime%3600)/60),
        math.floor(reactor.uptime%60))
    table.insert(eventLog, 1, ts.." "..msg)
    while #eventLog > LOG_MAX do table.remove(eventLog) end
end

local function alarm(id, msg)
    for _,a in ipairs(alarms) do if a.id==id then return end end
    table.insert(alarms, {id=id, msg=msg})
    log("ALARM: "..msg)
end

local function clearAlarm(id)
    for i,a in ipairs(alarms) do
        if a.id==id then table.remove(alarms,i); return end
    end
end

local function ackAll()
    alarms = {}
    log("All alarms acknowledged")
end

local function hasAlarms() return #alarms > 0 end
local function alarmLevel()
    for _,a in ipairs(alarms) do
        if a.id:find("MELT") or a.id:find("SCRAM") or a.id:find("EXPLO") then
            return "CRIT"
        end
    end
    if hasAlarms() then return "WARN" end
    return nil
end

-- ╔══════════════════════════════════════════╗
-- ║  SCRAM                                   ║
-- ╚══════════════════════════════════════════╝
local function doSCRAM(reason)
    if reactor.phase == 5 then return end  -- already scrammed
    reactor.rodPos        = 100
    reactor.meltdownMult  = 0
    local wasOnline = reactor.phase >= 3
    reactor.phase         = 5
    -- Trip turbines
    for _,t in ipairs(turbines) do
        if not t.broken then
            t.synced  = false
            t.breaker = false
            t.online  = false
        end
    end
    if wasOnline then
        alarm("SCRAM", "SCRAM: "..reason)
        log("*** SCRAM ACTIVATED: "..reason.." ***")
    end
end

-- ╔══════════════════════════════════════════╗
-- ║  RELIEF VALVES                           ║
-- ╚══════════════════════════════════════════╝
local function fireRV(i)
    local rv = reactor.rvs[i]
    if rv.active or rv.cooldown > 0 then return false end
    rv.active = true
    rv.timer  = C.RV_DURATION
    rv.cooldown = 0
    log("RV-"..i.." opened")
    return true
end

-- ╔══════════════════════════════════════════╗
-- ║  TURBINE EXPLOSION                       ║
-- ╚══════════════════════════════════════════╝
local screenNames = {"monOver","monCtrl","monSync"}

local function explodeTurbine(t)
    if t.broken then return end
    t.broken  = true
    t.online  = false
    t.synced  = false
    t.breaker = false
    t.rpm     = 0
    t.load    = 0
    alarm("EXPLO_"..t.id, t.name.." DESTROYED – OVERSPEED")
    log(t.name.." EXPLODED at overspeed!")
    -- Schedule repair prompt 5 seconds later
    t.repairTimer  = 5
    t.repairPrompt = false
    t.repairScreen = screenNames[math.random(1,3)]
end

-- ╔══════════════════════════════════════════╗
-- ║  PHYSICS                                 ║
-- ╚══════════════════════════════════════════╝
local function updatePhysics()
    local dt = TICK

    -- Uptime
    if reactor.phase >= 3 and reactor.phase ~= 5 then
        reactor.uptime = reactor.uptime + dt
    end

    -- ── Relief valve timers ──────────────────────────────
    local rvCooling = 0
    for i,rv in ipairs(reactor.rvs) do
        if rv.active then
            rv.timer = rv.timer - dt
            rvCooling = rvCooling + C.RV_RATE * dt
            if rv.timer <= 0 then
                rv.active   = false
                rv.cooldown = C.RV_COOLDOWN
                log("RV-"..i.." closed")
            end
        elseif rv.cooldown > 0 then
            rv.cooldown = math.max(0, rv.cooldown - dt)
        end
    end
    reactor.temperature = math.max(C.T_STALL,
        reactor.temperature - rvCooling)

    -- ── Meltdown ─────────────────────────────────────────
    if reactor.meltdownActive then
        reactor.meltdownTimer = reactor.meltdownTimer + dt

        -- Multiplier rises faster over time (quadratic growth)
        reactor.meltdownMult = reactor.meltdownMult +
            (0.002 + reactor.meltdownMult * 0.15) * dt

        -- Apply multiplier to temperature
        reactor.temperature = reactor.temperature +
            reactor.meltdownMult * 80 * dt

        -- Check save condition: coolant+feedwater+rods+scram
        local saving = reactor.coolantOn and reactor.feedwaterOn
                       and reactor.rodPos >= 99 and reactor.phase == 5
        if saving then
            reactor.meltdownMult = math.max(0,
                reactor.meltdownMult - 0.8 * dt)
        end

        -- Saved?
        if reactor.temperature < C.T_SAVE_MAX then
            reactor.meltdownActive = false
            reactor.meltdownSaved  = true
            reactor.meltdownMult   = 0
            clearAlarm("MELT")
            alarm("MELT_SAVED","MELTDOWN AVERTED – REACTOR SAFE")
            log("MELTDOWN AVERTED – temperature under 800K")
        end

        -- Failed (time exceeded and still hot)
        if reactor.meltdownTimer > C.MELTDOWN_SAVE_TIME and
           reactor.temperature >= C.T_SAVE_MAX then
            reactor.phase = 6  -- catastrophic
            alarm("MELT_FAIL","CATASTROPHIC MELTDOWN – CONTAINMENT BREACH")
            log("MELTDOWN: CONTAINMENT BREACHED")
        end
    end

    -- ── Core temperature physics ──────────────────────────
    local rodEffect = clamp((100 - reactor.rodPos) / 100, 0, 1)

    if reactor.phase == 3 then
        -- Igniting: rises at constant rate to 650K
        reactor.temperature = reactor.temperature + 8 * dt
        reactor.pressure    = lerp(reactor.pressure, C.P_STALL + 200, dt*0.05)
        if reactor.temperature >= C.T_IGNITE then
            reactor.phase = 4
            log("Reactor critical – nominal power")
        end

    elseif reactor.phase == 4 then
        -- Online: rods and coolant control temperature
        local coolFactor = reactor.coolantOn and 0.55 or 0
        local tTarget = lerp(C.T_STALL,
                             C.T_MELTDOWN * 0.88,
                             rodEffect) * (1 - coolFactor * 0.5)
        tTarget = math.max(C.T_STALL, tTarget)

        reactor.temperature = lerp(reactor.temperature, tTarget, dt*0.018)

        -- Pressure tracks temp
        local pTarget = lerp(C.P_STALL, C.P_CRIT * 0.9,
                             clamp((reactor.temperature-C.T_STALL)/
                                   (C.T_MELTDOWN-C.T_STALL),0,1))
        reactor.pressure = lerp(reactor.pressure, pTarget, dt*0.03)

        -- Neutron flux
        reactor.neutronFlux = lerp(reactor.neutronFlux,
            rodEffect * 100, dt*0.12)

        -- Thermal MW
        local tf = clamp((reactor.temperature-C.T_STALL)/
                         (C.T_SYNC_OPT-C.T_STALL), 0, 1.1)
        reactor.thermalMW = lerp(reactor.thermalMW,
            C.MW_RATED * rodEffect * tf, dt*0.04)

        -- Meltdown trigger
        if reactor.temperature >= C.T_MELTDOWN and
           not reactor.meltdownActive and not reactor.meltdownSaved then
            reactor.meltdownActive = true
            reactor.meltdownTimer  = 0
            reactor.meltdownMult   = 0.001
            alarm("MELT","MELTDOWN INITIATED – SCRAM IMMEDIATELY")
            log("!!! MELTDOWN TRIGGERED at "..
                rnd(reactor.temperature,0).."K !!!")
        end

        -- Auto-scram on over-pressure
        if reactor.pressure >= C.P_MAX then
            doSCRAM("OVER PRESSURE "..rnd(reactor.pressure,0).."kPa")
        end

    elseif reactor.phase == 5 then
        -- Scrammed: cool down; rods at 100, coolant helps
        local coolRate = reactor.coolantOn and 0.05 or 0.025
        reactor.temperature = lerp(reactor.temperature,
            C.T_STALL, dt * coolRate)
        reactor.pressure = lerp(reactor.pressure, C.P_STALL, dt*0.04)
        reactor.neutronFlux = lerp(reactor.neutronFlux, 0, dt*0.2)
        reactor.thermalMW   = lerp(reactor.thermalMW,   0, dt*0.08)

        -- Ready to reset when cool
        if reactor.temperature < C.T_STALL + 30 and
           reactor.pressure < C.P_STALL + 50 then
            -- Don't auto-reset; operator must re-authorize
        end

    elseif reactor.phase == 0 or reactor.phase == 1 or reactor.phase == 2 then
        reactor.temperature = C.T_STALL
        reactor.pressure    = C.P_STALL
        reactor.neutronFlux = 0
        reactor.thermalMW   = 0
    end

    -- Feedwater effect on temperature (bonus cooling when on)
    if reactor.feedwaterOn and reactor.phase == 4 then
        reactor.temperature = reactor.temperature - 12 * dt
    end

    -- ── Alarm conditions ──────────────────────────────────
    if reactor.phase == 4 or reactor.phase == 5 then
        if reactor.temperature >= 2800 then
            alarm("CRIT_TEMP","CRITICAL TEMPERATURE "..
                  rnd(reactor.temperature,0).."K")
        elseif reactor.temperature >= 2000 then
            alarm("WARN_TEMP","HIGH TEMPERATURE "..
                  rnd(reactor.temperature,0).."K")
        else
            clearAlarm("WARN_TEMP"); clearAlarm("CRIT_TEMP")
        end
        if reactor.pressure >= C.P_CRIT then
            alarm("CRIT_PRES","CRITICAL PRESSURE")
        elseif reactor.pressure >= C.P_WARN then
            alarm("WARN_PRES","HIGH PRESSURE")
        else
            clearAlarm("WARN_PRES"); clearAlarm("CRIT_PRES")
        end
    end

    -- ── Turbine physics ───────────────────────────────────
    local steamAvail = clamp(reactor.thermalMW / C.MW_RATED, 0, 1)
    generatedMW = 0

    for _,t in ipairs(turbines) do
        -- Repair prompt timer
        if t.broken and not t.repairPrompt and t.repairTimer > 0 then
            t.repairTimer = t.repairTimer - dt
            if t.repairTimer <= 0 then
                t.repairPrompt = true
            end
        end

        if t.broken or not t.online then
            -- Spin down
            t.rpm  = lerp(t.rpm, 0, dt*0.06)
            t.load = 0
            t.synced  = false
            t.breaker = false
        else
            -- ── Flow rate drifts with temperature ──
            -- At T_SYNC_OPT flow is stable; away from it, it drifts
            local tempDiff = (reactor.temperature - C.T_SYNC_OPT) / 1000
            local flowDrift = tempDiff * 0.08 * dt

            -- Flow step target: each step maps to a target flow
            local stepFlow = {
                [-2] = C.FLOW_OPT - 1.2,
                [-1] = C.FLOW_OPT - 0.5,
                [0]  = C.FLOW_OPT,
                [1]  = C.FLOW_OPT + 0.5,
                [2]  = C.FLOW_OPT + 1.2,
            }
            local fTarget = stepFlow[t.flowStep] or C.FLOW_OPT
            t.flowRate = lerp(t.flowRate,
                clamp(fTarget + flowDrift, 0.5, 8.0), dt*0.1)

            -- ── RPM control ──────────────────────
            -- Flow rate drives RPM toward sync; speed setting
            -- controls how fast RPM changes
            local speedMult = t.rpmSpeed == "S" and 0.4
                           or t.rpmSpeed == "M" and 1.0
                           or 2.5  -- F

            -- Flow above optimal pushes RPM up, below pulls down
            local flowError  = t.flowRate - C.FLOW_OPT
            local rpmTarget  = C.RPM_SYNC + flowError * 300

            -- If already synced, lock RPM
            if t.synced then
                rpmTarget = C.RPM_SYNC
                t.rpm = lerp(t.rpm, rpmTarget, dt * 0.3)
            else
                t.rpm = lerp(t.rpm, rpmTarget,
                             dt * 0.015 * speedMult)
            end
            t.rpm = math.max(0, t.rpm)

            -- ── Synchroscope angle ────────────────
            -- Angle spins at a rate proportional to RPM delta
            t.rpmDelta = t.rpm - C.RPM_SYNC
            -- Spin speed: rpm_delta / 60 rotations per second
            -- angle in degrees
            if not t.synced then
                local spinRPS = t.rpmDelta / 60
                t.scopeAngle = (t.scopeAngle + spinRPS * 360 * dt) % 360
                -- Wrap negative
                if t.scopeAngle < 0 then
                    t.scopeAngle = t.scopeAngle + 360
                end
            end

            -- Overspeed explosion
            if t.rpm >= C.RPM_EXPLODE then
                explodeTurbine(t)
            end

            -- ── Load when synced ──────────────────
            if t.synced and t.breaker then
                local syncedCount = 0
                for _,tt in ipairs(turbines) do
                    if tt.synced and tt.breaker and not tt.broken then
                        syncedCount = syncedCount + 1
                    end
                end
                local share = syncedCount > 0
                              and demandMW / syncedCount or 0
                t.load = lerp(t.load,
                    clamp(share / C.MW_TURB * 100, 0, 100),
                    dt * 0.04)
                t.steamFlow = t.load / 100 * 480
            else
                t.load = 0
                t.steamFlow = 0
            end

            -- Feedwater trip: if feedwater off, desync
            if not reactor.feedwaterOn and t.synced then
                t.synced  = false
                t.breaker = false
                t.online  = false
                alarm("FW_TRIP_"..t.id,
                      t.name.." TRIPPED – FEEDWATER LOST")
                log(t.name.." tripped: feedwater lost")
            end
        end

        if t.synced and t.breaker then
            generatedMW = generatedMW + (t.load/100) * C.MW_TURB
        end
    end

    -- ── Flash ticker ──────────────────────────────────────
    alarmFlash = not alarmFlash

    -- ── Redstone ──────────────────────────────────────────
    local rxOn = reactor.phase == 4
    redstone.setOutput(RS.reactor,  rxOn)
    redstone.setOutput(RS.turbine1, turbines[1].synced)
    redstone.setOutput(RS.turbine2, turbines[2].synced)

    -- ── Speaker ───────────────────────────────────────────
    if spk and hasAlarms() and alarmFlash then
        local lvl = alarmLevel()
        pcall(function()
            if lvl == "CRIT" then spk.playNote("bit",1,24)
            else spk.playNote("bit",0.4,14) end
        end)
    end
end

-- ╔══════════════════════════════════════════╗
-- ║  DRAW HELPERS                            ║
-- ╚══════════════════════════════════════════╝
local function mw(m,x,y,txt,fg,bg)
    if bg then m.setBackgroundColor(bg) end
    if fg then m.setTextColor(fg) end
    m.setCursorPos(x,y)
    m.write(txt)
end

local function mfill(m,x,y,w,h,bg,fg,ch)
    ch = ch or " "
    m.setBackgroundColor(bg)
    if fg then m.setTextColor(fg) end
    for r=y,y+h-1 do
        m.setCursorPos(x,r)
        m.write(string.rep(ch,w))
    end
end

local function mcenter(m,y,txt,fg,bg)
    local W = select(1,m.getSize())
    local x = math.max(1, math.floor((W-#txt)/2)+1)
    mw(m,x,y,txt,fg,bg)
end

local function bar(m,x,y,w,pct,cf,ce)
    pct = clamp(pct,0,100)
    local f = math.floor(pct/100*w)
    m.setCursorPos(x,y)
    m.setBackgroundColor(cf)
    m.write(string.rep("\127",f))
    m.setBackgroundColor(ce or colors.gray)
    m.write(string.rep(" ",w-f))
end

local function hline(m,y,fg,bg)
    local W=select(1,m.getSize())
    mfill(m,1,y,W,1,bg or colors.black,fg or colors.gray,"\140")
end

local function valC(v,warn,crit,inv)
    if inv then
        if v>=crit then return colors.red
        elseif v>=warn then return colors.orange
        else return colors.lime end
    else
        if v<=crit then return colors.red
        elseif v<=warn then return colors.orange
        else return colors.lime end
    end
end

-- ╔══════════════════════════════════════════╗
-- ║  OVERVIEW MONITOR                        ║
-- ╚══════════════════════════════════════════╝
-- Track repair prompts for overview screen
local overviewRepairBtn = nil  -- {t=turbine, x,y,w,h}

local function drawOverview()
    local m = monOver
    if not m then return end
    local W,H = m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    overviewRepairBtn = nil

    -- ── Header ────────────────────────────────────────────
    mfill(m,1,1,W,1,colors.gray)
    mw(m,2,1,"NARAMO NUCLEAR POWER PLANT  –  UNIT 1",
       colors.white,colors.gray)

    local phaseNames = {[0]="SHUTDOWN",[1]="AUTHORIZED",[2]="PUMPS ON",
        [3]="IGNITING",[4]="ONLINE",[5]="SCRAM",[6]="MELTDOWN"}
    local phaseBGs   = {[0]=colors.gray,[1]=colors.blue,[2]=colors.cyan,
        [3]=colors.yellow,[4]=colors.lime,[5]=colors.orange,[6]=colors.red}
    local ph  = reactor.phase
    local phN = phaseNames[ph] or "???"
    local phB = phaseBGs[ph]   or colors.gray
    if ph==5 and alarmFlash then phB=colors.red end
    if ph==6 then phB = alarmFlash and colors.red or colors.orange end
    local badge=" "..phN.." "
    mw(m,W-#badge,1,badge,colors.black,phB)

    -- ── Alarm banner ──────────────────────────────────────
    local row=2
    local lvl=alarmLevel()
    if lvl then
        local abg=(lvl=="CRIT" and alarmFlash) and colors.red or colors.orange
        mfill(m,1,row,W,1,abg)
        local atxt="\7 "
        for i,a in ipairs(alarms) do
            atxt=atxt..a.msg
            if i<#alarms then atxt=atxt.."  |  " end
            if #atxt>W-4 then atxt=atxt:sub(1,W-6).."..." break end
        end
        atxt=atxt.." \7"
        mcenter(m,row,atxt,colors.white,abg)
    else
        mfill(m,1,row,W,1,colors.black)
        mw(m,2,row,"\4 All systems nominal",colors.lime,colors.black)
    end
    row=row+1

    -- ── Layout: 3 columns ─────────────────────────────────
    local col1W = math.floor(W/3)
    local col2X = col1W+2
    local col2W = col1W-1
    local col3X = col1W*2+2
    local col3W = W-col3X+1

    -- ─── COL 1: REACTOR CORE ─────────────────────────────
    local r=row
    mfill(m,1,r,col1W,1,colors.blue)
    mw(m,2,r,"  REACTOR CORE",colors.white,colors.blue)
    r=r+1

    -- Temperature
    local tc=valC(reactor.temperature,2000,2800,true)
    mw(m,2,r,"TEMP     ",colors.lightGray,colors.black)
    mw(m,col1W-9,r,string.format("%6.0fK",reactor.temperature),tc,colors.black)
    r=r+1
    bar(m,2,r,col1W-2,
        reactor.temperature/C.T_MELTDOWN*100,tc,colors.gray)
    r=r+1

    -- Pressure
    local pc=valC(reactor.pressure,C.P_WARN,C.P_CRIT,true)
    mw(m,2,r,"PRESSURE ",colors.lightGray,colors.black)
    mw(m,col1W-9,r,string.format("%4.0fkPa",reactor.pressure),pc,colors.black)
    r=r+1
    bar(m,2,r,col1W-2,
        reactor.pressure/C.P_MAX*100,pc,colors.gray)
    r=r+1

    -- Rod position
    local rodC = reactor.rodPos>85 and colors.gray
                 or reactor.rodPos<20 and colors.red or colors.yellow
    mw(m,2,r,"CTRL RODS",colors.lightGray,colors.black)
    mw(m,col1W-9,r,string.format("%3.0f%% IN",reactor.rodPos),rodC,colors.black)
    r=r+1
    bar(m,2,r,col1W-2,reactor.rodPos,colors.purple,colors.gray)
    r=r+1

    -- Neutron flux
    local fc=reactor.neutronFlux>80 and colors.orange
             or reactor.neutronFlux>50 and colors.yellow or colors.lime
    mw(m,2,r,"N-FLUX   ",colors.lightGray,colors.black)
    mw(m,col1W-9,r,string.format("%5.1f nu",reactor.neutronFlux),fc,colors.black)
    r=r+1
    bar(m,2,r,col1W-2,reactor.neutronFlux,fc,colors.gray)
    r=r+1

    -- Coolant / Feedwater
    local cwc=reactor.coolantOn and colors.lime or colors.red
    local fwc=reactor.feedwaterOn and colors.lime or colors.red
    mw(m,2,r,"COOLANT  ",colors.lightGray,colors.black)
    mw(m,12,r,reactor.coolantOn and " ON  " or " OFF ",
       colors.black,cwc)
    r=r+1
    mw(m,2,r,"FEEDWATER",colors.lightGray,colors.black)
    mw(m,12,r,reactor.feedwaterOn and " ON  " or " OFF ",
       colors.black,fwc)
    r=r+1

    -- Meltdown timer
    if reactor.meltdownActive then
        local remaining = C.MELTDOWN_SAVE_TIME - reactor.meltdownTimer
        local tc2 = remaining < 60 and colors.red or colors.orange
        mw(m,2,r,"MELTDOWN ",colors.red,colors.black)
        mw(m,12,r,string.format("T-%3.0fs MULT=%.2f",
           remaining, reactor.meltdownMult),tc2,colors.black)
        r=r+1
    end

    -- Relief valves
    hline(m,r,colors.gray,colors.black); r=r+1
    mw(m,2,r,"RELIEF VALVES",colors.yellow,colors.black); r=r+1
    for i,rv in ipairs(reactor.rvs) do
        local rvc,rvtxt
        if rv.active then
            rvc=colors.lime; rvtxt=string.format("RV-%d OPEN %.0fs",i,rv.timer)
        elseif rv.cooldown>0 then
            rvc=colors.orange; rvtxt=string.format("RV-%d CDN  %.0fs",i,rv.cooldown)
        else
            rvc=colors.gray; rvtxt=string.format("RV-%d READY",i)
        end
        mw(m,2,r,rvtxt,rvc,colors.black); r=r+1
        if r>H-2 then break end
    end

    -- ─── COL 2: PRIMARY/SECONDARY ────────────────────────
    local mr=row
    mfill(m,col2X,mr,col2W,1,colors.blue)
    mw(m,col2X+1,mr,"  PRIMARY LOOP",colors.white,colors.blue)
    mr=mr+1

    -- Primary pump
    local ppOK=auth.pumpsOn
    mw(m,col2X,mr,"SHUTDOWN PUMPS",colors.lightGray,colors.black)
    mw(m,col2X+col2W-7,mr,
       ppOK and " RUN  " or " STOP ",
       colors.black, ppOK and colors.lime or colors.red)
    mr=mr+1

    -- Thermal output
    local thC=reactor.thermalMW>C.MW_RATED*0.8 and colors.orange or colors.lime
    mw(m,col2X,mr,"THERMAL MW",colors.lightGray,colors.black)
    mw(m,col2X+col2W-8,mr,
       string.format("%5.0f MW",reactor.thermalMW),thC,colors.black)
    mr=mr+1

    hline(m,mr,colors.gray,colors.black); mr=mr+1
    mfill(m,col2X,mr,col2W,1,colors.blue)
    mw(m,col2X+1,mr,"  POWER & DEMAND",colors.white,colors.blue)
    mr=mr+1

    -- Demand
    mw(m,col2X,mr,"ORDERED  ",colors.lightGray,colors.black)
    mw(m,col2X+col2W-8,mr,
       string.format("%5.0f MW",demandMW),colors.cyan,colors.black)
    mr=mr+1

    -- Generated
    local gmC=math.abs(generatedMW-demandMW)<100
              and colors.lime or colors.orange
    mw(m,col2X,mr,"GENERATED",colors.lightGray,colors.black)
    mw(m,col2X+col2W-8,mr,
       string.format("%5.0f MW",generatedMW),gmC,colors.black)
    mr=mr+1
    bar(m,col2X,mr,col2W,
        generatedMW/(C.MW_TURB*2)*100,gmC,colors.gray)
    mr=mr+1

    hline(m,mr,colors.gray,colors.black); mr=mr+1

    -- ── Turbine summary in col2 ────────────────────────────
    mfill(m,col2X,mr,col2W,1,colors.blue)
    mw(m,col2X+1,mr,"  TURBINES",colors.white,colors.blue)
    mr=mr+1

    for _,t in ipairs(turbines) do
        local tbg
        if t.broken then tbg=colors.red
        elseif t.synced then tbg=colors.lime
        elseif t.online then tbg=colors.yellow
        else tbg=colors.gray end

        local tst
        if t.broken then tst="FAULT"
        elseif t.synced then tst=string.format("SYNC %4.0fRPM %3.0f%%",t.rpm,t.load)
        elseif t.online then tst=string.format("SPIN %4.0fRPM",t.rpm)
        else tst="OFFLINE" end

        local tline=string.format(" %s %s ",t.name,tst)
        mfill(m,col2X,mr,col2W,1,tbg)
        mw(m,col2X,mr,tline:sub(1,col2W),colors.black,tbg)
        mr=mr+1

        -- Repair prompt on overview screen
        if t.repairPrompt and t.repairScreen=="monOver" then
            mfill(m,col2X,mr,col2W,1,colors.red)
            mw(m,col2X,mr," >> CLICK TO REPAIR "..t.name.." <<",
               colors.white,colors.red)
            overviewRepairBtn = {t=t,x=col2X,y=mr,w=col2W,h=1}
            mr=mr+1
        end
    end

    -- ─── COL 3: UPTIME / EVENT LOG ───────────────────────
    local pr=row
    mfill(m,col3X,pr,col3W,1,colors.blue)
    mw(m,col3X+1,pr,"  SYSTEM LOG",colors.white,colors.blue)
    pr=pr+1

    local upStr=string.format("UPTIME: %02d:%02d:%02d",
        math.floor(reactor.uptime/3600),
        math.floor((reactor.uptime%3600)/60),
        math.floor(reactor.uptime%60))
    mw(m,col3X,pr,upStr,colors.lightGray,colors.black)
    pr=pr+2

    for i,entry in ipairs(eventLog) do
        local ey=pr+i-1
        if ey>H-1 then break end
        local ec=entry:find("SCRAM") and colors.red
                 or entry:find("MELT") and colors.orange
                 or entry:find("ALARM") and colors.orange
                 or entry:find("online") and colors.lime
                 or entry:find("sync") and colors.cyan
                 or colors.lightGray
        mw(m,col3X,ey,entry:sub(1,col3W),ec,colors.black)
    end

    -- Footer
    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,
       string.format("T:%5.0fK  P:%6.0fkPa  MW:%5.0f/%5.0f  ROD:%3.0f%%  FW:%s  COOL:%s",
           reactor.temperature,reactor.pressure,
           generatedMW,demandMW,reactor.rodPos,
           reactor.feedwaterOn and "ON" or "OFF",
           reactor.coolantOn and "ON" or "OFF"),
       colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════╗
-- ║  CONTROL PANEL MONITOR                   ║
-- ╚══════════════════════════════════════════╝
-- Button registry
local ctrlBtns = {}
local ctrlRepairBtns = {}  -- repair prompts on ctrl screen

local function defBtn(id,x,y,w,h,lbl,bg,fg)
    table.insert(ctrlBtns,{
        id=id,x=x,y=y,w=w,h=h,
        label=lbl,bg=bg,fg=fg or colors.black,
        flash=false
    })
end

local function buildCtrlBtns()
    ctrlBtns={}
    -- Startup sequence
    defBtn("AUTH",     2, 3,13,3,"AUTHORIZE\nIGNITION",  colors.blue,   colors.white)
    defBtn("PUMPS",   17, 3,13,3,"SHUTDOWN\nPUMPS",      colors.cyan,   colors.black)
    defBtn("IGNITE",   2, 7,13,3,"IGNITE\nREACTOR",      colors.lime,   colors.black)
    defBtn("SCRAM",   17, 7,13,3,"EMERGENCY\nSCRAM",     colors.red,    colors.white)

    -- Systems
    defBtn("COOLANT",  2,11,13,3,"COOLANT\nSYSTEM",      colors.cyan,   colors.black)
    defBtn("FEEDWTR", 17,11,13,3,"FEEDWATER\nSYSTEM",    colors.blue,   colors.white)

    -- Rod control: 1% and 5% steps
    defBtn("ROD_W1",   2,15, 7,3,"-1%\nWITHDRAW",       colors.yellow, colors.black)
    defBtn("ROD_I1",  10,15, 7,3,"+1%\nINSERT",         colors.orange, colors.black)
    defBtn("ROD_W5",  18,15, 7,3,"-5%\nWITHDRAW",       colors.yellow, colors.black)
    defBtn("ROD_I5",  26,15, 7,3,"+5%\nINSERT",         colors.orange, colors.black)

    -- Relief valves
    defBtn("RV1",      2,19, 7,3,"RV-1\nFIRE",          colors.gray,   colors.white)
    defBtn("RV2",     10,19, 7,3,"RV-2\nFIRE",          colors.gray,   colors.white)
    defBtn("RV3",     18,19, 7,3,"RV-3\nFIRE",          colors.gray,   colors.white)
    defBtn("RV4",     26,19, 7,3,"RV-4\nFIRE",          colors.gray,   colors.white)

    -- Demand
    defBtn("DEM_UP",   2,23,13,3,"DEMAND\n+100 MW",     colors.gray,   colors.white)
    defBtn("DEM_DN",  17,23,13,3,"DEMAND\n-100 MW",     colors.gray,   colors.white)

    -- Alarm ack
    defBtn("ACK",      2,27,28,3,"ACKNOWLEDGE ALL ALARMS",colors.purple,colors.white)
end

local function drawCtrlPanel()
    local m=monCtrl
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    ctrlRepairBtns={}

    -- Header
    mfill(m,1,1,W,1,colors.gray)
    mw(m,2,1,"OPERATOR CONTROL PANEL",colors.white,colors.gray)

    local ph=reactor.phase
    local phNames={[0]="SHUTDOWN",[1]="AUTHORIZED",[2]="PUMPS ON",
        [3]="IGNITING",[4]="ONLINE",[5]="SCRAM",[6]="MELTDOWN"}
    local phBGs={[0]=colors.gray,[1]=colors.blue,[2]=colors.cyan,
        [3]=colors.yellow,[4]=colors.lime,[5]=colors.orange,[6]=colors.red}
    local st=" "..(phNames[ph] or "???").." "
    local stBG=phBGs[ph] or colors.gray
    mw(m,W-#st,1,st,colors.black,stBG)

    -- Draw buttons
    for _,btn in ipairs(ctrlBtns) do
        local bg=btn.flash and colors.white or btn.bg
        local fg=btn.flash and btn.bg or btn.fg

        -- Dynamic overrides
        if btn.id=="AUTH" then
            if auth.ignitionAuthorized then bg=colors.lime; fg=colors.black
            else bg=colors.blue; fg=colors.white end
        elseif btn.id=="PUMPS" then
            bg=auth.pumpsOn and colors.lime or colors.cyan
            fg=colors.black
        elseif btn.id=="IGNITE" then
            local ready=auth.ignitionAuthorized and auth.pumpsOn
                        and (ph==0 or ph==1 or ph==2)
            bg=ready and colors.lime or colors.gray
            fg=ready and colors.black or colors.lightGray
        elseif btn.id=="SCRAM" then
            if ph==5 then bg=colors.orange end
        elseif btn.id=="COOLANT" then
            bg=reactor.coolantOn and colors.lime or colors.cyan
            fg=colors.black
        elseif btn.id=="FEEDWTR" then
            bg=reactor.feedwaterOn and colors.lime or colors.blue
            fg=reactor.feedwaterOn and colors.black or colors.white
        end

        -- RV buttons: color by state
        for i=1,4 do
            if btn.id=="RV"..i then
                local rv=reactor.rvs[i]
                if rv.active then bg=colors.lime; fg=colors.black
                elseif rv.cooldown>0 then bg=colors.orange; fg=colors.black
                else bg=colors.gray; fg=colors.white end
            end
        end

        mfill(m,btn.x,btn.y,btn.w,btn.h,bg)
        local lines={}
        for ln in btn.label:gmatch("[^\n]+") do table.insert(lines,ln) end
        local midY=btn.y+math.floor(btn.h/2)
        local half=math.floor(#lines/2)
        for i,ln in ipairs(lines) do
            local lx=btn.x+math.floor((btn.w-#ln)/2)
            mw(m,lx,midY-half+i-1,ln,fg,bg)
        end
    end

    -- Rod position display
    local rodY=31
    if rodY+2<=H then
        mw(m,2,rodY,"CONTROL ROD POSITION",colors.lightGray,colors.black)
        mw(m,W-8,rodY,string.format("%3.0f%% IN",reactor.rodPos),
           colors.white,colors.black)
        rodY=rodY+1
        bar(m,2,rodY,W-2,reactor.rodPos,colors.purple,colors.gray)
        rodY=rodY+1
        -- tick marks
        for pct=0,100,10 do
            local tx=2+math.floor(pct/100*(W-3))
            if tx<=W then
                mw(m,tx,rodY,
                   string.format("%3d",pct):gsub(" ",""),
                   colors.lightGray,colors.black)
            end
        end
        rodY=rodY+2
    end

    -- Repair prompts on ctrl screen
    for _,t in ipairs(turbines) do
        if t.repairPrompt and t.repairScreen=="monCtrl" and rodY<=H-1 then
            mfill(m,2,rodY,W-2,2,colors.red)
            mw(m,2,rodY," !! "..t.name.." FAULT – CLICK TO REPAIR !!",
               colors.white,colors.red)
            mw(m,2,rodY+1,
               "  Turbine destroyed – needs maintenance  ",
               colors.yellow,colors.red)
            table.insert(ctrlRepairBtns,{t=t,x=2,y=rodY,w=W-2,h=2})
            rodY=rodY+3
        end
    end

    -- Footer
    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,"[/] rod 1%  UP/DN rod 5%  1/2 turbines  A=ack",
       colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════╗
-- ║  SYNCHROSCOPE / TURBINE MONITOR          ║
-- ╚══════════════════════════════════════════╝
-- Repair buttons on sync screen
local syncRepairBtns={}

-- Synchroscope drawing – circle of 16 dots, one is green (top=0)
local function drawSynchroscope(m, cx, cy, angle, online, synced, broken)
    -- 16 positions around a circle, radius 4 chars wide 2 chars tall
    -- Positions as (dx,dy) offsets from center
    local positions = {
        {0,-2},  {1,-2},  {2,-1},  {2,0},
        {2,1},   {1,2},   {0,2},   {-1,2},
        {-2,1},  {-2,0},  {-2,-1}, {-1,-2},
        -- fill gaps for rounder look
    }
    -- Use 12-position clock face
    local clockDots = {
        { 0,-2},  -- 12
        { 1,-2},  -- 1
        { 2,-1},  -- 2
        { 2, 0},  -- 3
        { 2, 1},  -- 4
        { 1, 2},  -- 5
        { 0, 2},  -- 6
        {-1, 2},  -- 7
        {-2, 1},  -- 8
        {-2, 0},  -- 9
        {-2,-1},  -- 10
        {-1,-2},  -- 11
    }
    local n = #clockDots

    -- Which dot is "lit" based on angle
    local litIdx = math.floor(angle / 360 * n) % n + 1

    -- Clear scope area
    mfill(m,cx-3,cy-2,7,5,colors.black)

    for i,pos in ipairs(clockDots) do
        local px = cx + pos[1]
        local py = cy + pos[2]
        local ch, dotFG, dotBG

        if broken then
            dotFG=colors.red; dotBG=colors.black; ch="\7"
        elseif not online then
            dotFG=colors.gray; dotBG=colors.black; ch="\7"
        elseif i==1 then
            -- Top dot is the sync marker (always green)
            dotBG=colors.black
            if synced then
                dotFG=colors.lime; ch="\4"
            else
                dotFG=colors.lime; ch="\7"
            end
        elseif i==litIdx then
            -- Spinning lit dot
            dotFG=colors.white; dotBG=colors.black; ch="\7"
        else
            dotFG=colors.gray; dotBG=colors.black; ch="\7"
        end
        if px>=1 and py>=1 then
            mw(m,px,py,ch,dotFG,dotBG)
        end
    end

    -- Center: show RPM delta
    if online and not broken then
        if synced then
            mw(m,cx,cy,"S",colors.lime,colors.black)
        else
            mw(m,cx,cy,"\4",colors.yellow,colors.black)
        end
    elseif broken then
        mw(m,cx,cy,"X",colors.red,colors.black)
    end
end

-- Flow step labels
local flowLabels = {[-2]="--",[-1]="-",[0]="N",[1]="+",[2]="++"}

local function drawTurbinePanel(m, t, panX, panY, panW, panH)
    -- Panel background
    local pbg = t.broken and colors.black
                or t.synced and colors.black or colors.black

    mfill(m,panX,panY,panW,panH,pbg)

    -- Header bar
    local hbg = t.broken and colors.red
                or t.synced and colors.lime
                or t.online and colors.yellow or colors.gray
    mfill(m,panX,panY,panW,1,hbg)
    local hst = t.broken and "FAULT"
                or t.synced and "SYNCED"
                or t.online and "SPINNING" or "OFFLINE"
    mw(m,panX,panY,string.format(" %s  %s ",t.name,hst):sub(1,panW),
       colors.black,hbg)

    local r=panY+1

    -- Synchroscope
    local scopeCX = panX + math.floor(panW/2)
    local scopeCY = r+2
    drawSynchroscope(m, scopeCX, scopeCY,
                     t.scopeAngle, t.online, t.synced, t.broken)
    r=scopeCY+3

    -- RPM
    local rpmC = t.rpm >= 4500 and colors.red
                 or t.rpm >= 3500 and colors.orange
                 or t.rpm >= 2800 and colors.lime or colors.cyan
    mw(m,panX,r,"RPM",colors.lightGray,colors.black)
    mw(m,panX+panW-7,r,string.format("%4.0f",t.rpm),rpmC,colors.black)
    r=r+1
    bar(m,panX,r,panW,t.rpm/C.RPM_SYNC*100,rpmC,colors.gray)
    r=r+1

    -- RPM delta
    local deltaC = math.abs(t.rpmDelta)<30 and colors.lime
                   or math.abs(t.rpmDelta)<150 and colors.yellow or colors.orange
    mw(m,panX,r,"DELTA",colors.lightGray,colors.black)
    mw(m,panX+panW-8,r,string.format("%+5.0f rpm",t.rpmDelta),deltaC,colors.black)
    r=r+1

    -- Flow rate
    local fwC = math.abs(t.flowRate-C.FLOW_OPT)<0.1 and colors.lime
                or math.abs(t.flowRate-C.FLOW_OPT)<0.5 and colors.yellow
                or colors.orange
    mw(m,panX,r,"FLOW",colors.lightGray,colors.black)
    mw(m,panX+panW-9,r,string.format("%4.2fm\179/s",t.flowRate),fwC,colors.black)
    r=r+1

    -- Optimal flow indicator
    local optMarker = math.abs(t.flowRate-C.FLOW_OPT)<0.15
                      and "\4 OPTIMAL" or "  OPT=3.61"
    mw(m,panX,r,optMarker,fwC,colors.black)
    r=r+1

    -- Load
    mw(m,panX,r,"LOAD",colors.lightGray,colors.black)
    mw(m,panX+panW-6,r,string.format("%4.1f%%",t.load),colors.white,colors.black)
    r=r+1

    if r > panY+panH-1 then return r end

    -- ── Speed selector: S / M / F ─────────────────────────
    mw(m,panX,r,"SPEED:",colors.lightGray,colors.black)
    local speeds={"S","M","F"}
    for i,sp in ipairs(speeds) do
        local sx=panX+7+(i-1)*3
        local sbg=t.rpmSpeed==sp and colors.yellow or colors.gray
        mw(m,sx,r," "..sp.." ",colors.black,sbg)
    end
    r=r+1

    if r > panY+panH-1 then return r end

    -- ── Flow step buttons: -- - N + ++ ────────────────────
    mw(m,panX,r,"FLOW:",colors.lightGray,colors.black)
    local steps={{-2,"--"},{-1,"-"},{0,"N"},{1,"+"},{2,"++"}}
    local bx=panX+6
    for _,s in ipairs(steps) do
        local sbg=t.flowStep==s[1] and colors.cyan or colors.gray
        mw(m,bx,r,s[2],colors.black,sbg)
        bx=bx+#s[2]+1
    end
    r=r+1

    if r > panY+panH-1 then return r end

    -- ── Sync switch ───────────────────────────────────────
    if t.online and not t.synced and not t.broken then
        local nearSync=math.abs(t.rpmDelta)<50
        local sbg=nearSync and colors.lime or colors.gray
        local stxt=nearSync and "[ SYNC NOW ]" or "[ SYNC WHEN READY ]"
        mfill(m,panX,r,panW,1,sbg)
        mw(m,panX,r,stxt,colors.black,sbg)
        r=r+1
    elseif t.synced then
        mfill(m,panX,r,panW,1,colors.lime)
        mw(m,panX,r,"[ SYNCHRONIZED ]",colors.black,colors.lime)
        r=r+1
    end

    -- Online/offline toggle
    if r <= panY+panH-1 then
        local tbg=t.online and colors.orange or colors.cyan
        local ttxt=t.online and "[ TRIP TURBINE ]" or "[ START TURBINE ]"
        if t.broken then tbg=colors.red; ttxt="[ TURBINE FAULT ]" end
        mfill(m,panX,r,panW,1,tbg)
        mw(m,panX,r,ttxt,colors.black,tbg)
        r=r+1
    end

    return r
end

-- Buttons detected on sync screen (rebuilt each draw)
local syncBtns = {}

local function drawSyncMonitor()
    local m=monSync
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    syncBtns={}
    syncRepairBtns={}

    mfill(m,1,1,W,1,colors.gray)
    mcenter(m,1,"TURBINE GENERATOR SYNCHROSCOPE PANEL",
            colors.white,colors.gray)

    local pW=math.floor((W-3)/2)

    for i,t in ipairs(turbines) do
        local px=1+(i-1)*(pW+2)
        local py=2

        drawTurbinePanel(m, t, px, py, pW, H-py-1)

        -- Register clickable areas
        -- Speed buttons
        local speedRow=py+1+2+3+1+2+1+1+1  -- approximate; walk down
        -- We'll do hit-testing by scanning the known layout rows
        -- Easier: record regions during draw with fixed offsets
        -- Speed: row py+10, cols px+7, px+10, px+13
        local baseR = py+1  -- after header
        local scopeRows = 5  -- synchroscope takes 5 rows
        local statsRows = 6  -- rpm, delta, flow, opt, load = 5 rows
        local speedR = baseR + scopeRows + statsRows

        if speedR<=H then
            local sps={"S","M","F"}
            for si,sp in ipairs(sps) do
                local sx=px+7+(si-1)*3
                table.insert(syncBtns,{
                    type="speed", t=t, val=sp,
                    x=sx, y=speedR, w=3, h=1
                })
            end
        end

        -- Flow buttons row
        local flowR=speedR+1
        if flowR<=H then
            local steps={{-2,"--"},{-1,"-"},{0,"N"},{1,"+"},{2,"++"}}
            local bx=px+6
            for _,s in ipairs(steps) do
                table.insert(syncBtns,{
                    type="flow", t=t, val=s[1],
                    x=bx, y=flowR, w=#s[2], h=1
                })
                bx=bx+#s[2]+1
            end
        end

        -- Sync switch row
        local syncR=flowR+1
        if syncR<=H and t.online and not t.synced and not t.broken then
            table.insert(syncBtns,{
                type="sync", t=t,
                x=px, y=syncR, w=pW, h=1
            })
            syncR=syncR+1
        elseif syncR<=H and t.synced then
            syncR=syncR+1
        end

        -- Online/trip toggle
        local onlineR=syncR
        if onlineR<=H then
            table.insert(syncBtns,{
                type="online", t=t,
                x=px, y=onlineR, w=pW, h=1
            })
        end

        -- Repair prompt on sync screen
        if t.repairPrompt and t.repairScreen=="monSync" then
            local rr=H-2
            mfill(m,px,rr,pW,2,colors.red)
            mw(m,px,rr,"!! CLICK TO REPAIR "..t.name.." !!",
               colors.white,colors.red)
            table.insert(syncRepairBtns,{t=t,x=px,y=rr,w=pW,h=2})
        end
    end

    -- Footer
    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,
       string.format("SYNC TARGET: %d RPM  |  OPT FLOW: %.2f m3/s  |  OPT TEMP: %dK",
           C.RPM_SYNC, C.FLOW_OPT, C.T_SYNC_OPT),
       colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════╗
-- ║  AUTHORIZATION INPUT                     ║
-- ╚══════════════════════════════════════════╝
-- Shows a name input overlay on monCtrl
local function drawAuthPrompt()
    local m=monCtrl
    if not m then return end
    local W,H=m.getSize()
    -- Overlay box in center
    local bx=3; local bw=W-4; local by=math.floor(H/2)-3; local bh=7
    mfill(m,bx,by,bw,bh,colors.gray)
    mfill(m,bx+1,by+1,bw-2,bh-2,colors.black)
    mcenter(m,by+1,"IGNITION AUTHORIZATION",colors.yellow,colors.black)
    mcenter(m,by+2,"Enter shift manager name:",colors.white,colors.black)
    mcenter(m,by+3,"Expected: "..SHIFT_MANAGER,colors.lightGray,colors.black)
    -- Input field
    mfill(m,bx+2,by+4,bw-4,1,colors.white)
    mw(m,bx+2,by+4,auth.nameBuffer,colors.black,colors.white)
    mw(m,bx+2+#auth.nameBuffer,by+4,"_",colors.gray,colors.white)
    mcenter(m,by+5,"[ENTER to confirm  ESC to cancel]",colors.gray,colors.black)
end

-- ╔══════════════════════════════════════════╗
-- ║  ACTIONS                                 ║
-- ╚══════════════════════════════════════════╝
local function doAction(id)
    local ph=reactor.phase

    if id=="AUTH" then
        if not auth.ignitionAuthorized then
            auth.awaitingName=true
            auth.nameBuffer=""
        end

    elseif id=="PUMPS" then
        if auth.ignitionAuthorized or auth.pumpsOn then
            auth.pumpsOn = not auth.pumpsOn
            log("Shutdown pumps "..(auth.pumpsOn and "STARTED" or "STOPPED"))
            if ph==2 and not auth.pumpsOn then reactor.phase=1 end
            if ph<=1 and auth.pumpsOn then reactor.phase=2 end
        else
            log("Cannot start pumps: ignition not authorized")
        end

    elseif id=="IGNITE" then
        if auth.ignitionAuthorized and auth.pumpsOn and
           (ph==0 or ph==1 or ph==2) then
            reactor.phase=3
            reactor.temperature=C.T_STALL
            reactor.rodPos=100
            log("IGNITION – reactor rising to criticality")
        else
            log("Ignition blocked: check authorization and pumps")
        end

    elseif id=="SCRAM" then
        doSCRAM("MANUAL OPERATOR SCRAM")
        -- Allow re-arm: reset auth after scram only if user wants
        -- (keep auth state so they can re-ignite after cooling)

    elseif id=="COOLANT" then
        reactor.coolantOn = not reactor.coolantOn
        log("Coolant "..(reactor.coolantOn and "ON" or "OFF"))

    elseif id=="FEEDWTR" then
        reactor.feedwaterOn = not reactor.feedwaterOn
        log("Feedwater "..(reactor.feedwaterOn and "ON" or "OFF"))
        -- If turning off, turbines will trip in physics loop

    elseif id=="ROD_W1" then
        if ph~=5 then
            reactor.rodPos=clamp(reactor.rodPos-1,0,100)
            log("Rod withdrawn "..rnd(reactor.rodPos,0).."%")
        end
    elseif id=="ROD_I1" then
        reactor.rodPos=clamp(reactor.rodPos+1,0,100)
        log("Rod inserted "..rnd(reactor.rodPos,0).."%")
    elseif id=="ROD_W5" then
        if ph~=5 then
            reactor.rodPos=clamp(reactor.rodPos-5,0,100)
            log("Rod withdrawn "..rnd(reactor.rodPos,0).."%")
        end
    elseif id=="ROD_I5" then
        reactor.rodPos=clamp(reactor.rodPos+5,0,100)
        log("Rod inserted "..rnd(reactor.rodPos,0).."%")

    elseif id=="RV1" then fireRV(1)
    elseif id=="RV2" then fireRV(2)
    elseif id=="RV3" then fireRV(3)
    elseif id=="RV4" then fireRV(4)

    elseif id=="DEM_UP" then
        demandMW=math.min(C.MW_TURB*2, demandMW+100)
        log("Demand "..rnd(demandMW,0).." MW")
    elseif id=="DEM_DN" then
        demandMW=math.max(0, demandMW-100)
        log("Demand "..rnd(demandMW,0).." MW")

    elseif id=="ACK" then
        ackAll()
    end
end

local function repairTurbine(t)
    if not t.broken then return end
    t.broken      = false
    t.repairPrompt= false
    t.repairScreen= nil
    t.repairTimer = 0
    t.rpm         = 0
    t.scopeAngle  = 0
    t.flowRate    = 0
    t.flowStep    = 0
    clearAlarm("EXPLO_"..t.id)
    log(t.name.." repaired – ready for restart")
end

-- ╔══════════════════════════════════════════╗
-- ║  INPUT HANDLING                          ║
-- ╚══════════════════════════════════════════╝
local function handleCtrlTouch(mx,my)
    -- Auth prompt takes priority
    if auth.awaitingName then return end

    -- Check ctrl panel buttons
    for _,btn in ipairs(ctrlBtns) do
        if mx>=btn.x and mx<btn.x+btn.w and
           my>=btn.y and my<btn.y+btn.h then
            doAction(btn.id)
            btn.flash=true
            drawCtrlPanel()
            os.sleep(0.08)
            btn.flash=false
            return
        end
    end

    -- Repair prompts on ctrl screen
    for _,rb in ipairs(ctrlRepairBtns) do
        if mx>=rb.x and mx<rb.x+rb.w and
           my>=rb.y and my<rb.y+rb.h then
            repairTurbine(rb.t)
            return
        end
    end
end

local function handleSyncTouch(mx,my)
    -- Repair prompts
    for _,rb in ipairs(syncRepairBtns) do
        if mx>=rb.x and mx<rb.x+rb.w and
           my>=rb.y and my<rb.y+rb.h then
            repairTurbine(rb.t)
            return
        end
    end

    -- Sync panel buttons
    for _,btn in ipairs(syncBtns) do
        if mx>=btn.x and mx<btn.x+btn.w and
           my>=btn.y and my<btn.y+btn.h then

            if btn.type=="speed" then
                btn.t.rpmSpeed=btn.val
                log(btn.t.name.." speed: "..btn.val)

            elseif btn.type=="flow" then
                btn.t.flowStep=btn.val
                log(btn.t.name.." flow step: "..flowLabels[btn.val])

            elseif btn.type=="sync" then
                -- Manual sync: only if green dot near top (angle near 0 or 360)
                local angNorm=btn.t.scopeAngle % 360
                local nearTop=(angNorm<25 or angNorm>335)
                local nearRPM=math.abs(btn.t.rpmDelta)<60
                if nearTop and nearRPM and not btn.t.broken then
                    btn.t.synced=true
                    btn.t.breaker=true
                    log(btn.t.name.." synchronized to grid")
                else
                    log(btn.t.name.." sync attempt failed – wait for green dot")
                end

            elseif btn.type=="online" then
                if not btn.t.broken then
                    btn.t.online=not btn.t.online
                    if not btn.t.online then
                        btn.t.synced=false
                        btn.t.breaker=false
                    else
                        log(btn.t.name.." started")
                    end
                end
            end
            return
        end
    end
end

local function handleOverviewTouch(mx,my)
    if overviewRepairBtn then
        local rb=overviewRepairBtn
        if mx>=rb.x and mx<rb.x+rb.w and
           my>=rb.y and my<rb.y+rb.h then
            repairTurbine(rb.t)
        end
    end
end

local function handleMonitorTouch(monName,mx,my)
    if monName==PNAMES.monCtrl then
        handleCtrlTouch(mx,my)
    elseif monName==PNAMES.monSync then
        handleSyncTouch(mx,my)
    elseif monName==PNAMES.monOver then
        handleOverviewTouch(mx,my)
    else
        -- Try all monitors (peripheral might report side name)
        handleCtrlTouch(mx,my)
        handleSyncTouch(mx,my)
        handleOverviewTouch(mx,my)
    end
end

local function handleKey(key)
    if auth.awaitingName then
        -- Name input handled in char event
        if key==keys.escape then
            auth.awaitingName=false
            auth.nameBuffer=""
        end
        return
    end

    if key==keys.a           then ackAll()
    elseif key==keys.q       then running=false
    elseif key==keys.leftBracket  then doAction("ROD_W1")
    elseif key==keys.rightBracket then doAction("ROD_I1")
    elseif key==keys.up      then doAction("ROD_W5")
    elseif key==keys.down    then doAction("ROD_I5")
    elseif key==keys.one     then
        turbines[1].online=not turbines[1].online
        if not turbines[1].online then
            turbines[1].synced=false; turbines[1].breaker=false
        end
    elseif key==keys.two     then
        turbines[2].online=not turbines[2].online
        if not turbines[2].online then
            turbines[2].synced=false; turbines[2].breaker=false
        end
    elseif key==keys.c       then doAction("COOLANT")
    elseif key==keys.f       then doAction("FEEDWTR")
    elseif key==keys.x       then doAction("SCRAM")
    elseif key==keys.period  then doAction("DEM_UP")
    elseif key==keys.comma   then doAction("DEM_DN")
    end
end

local function handleChar(ch)
    if auth.awaitingName then
        auth.nameBuffer=auth.nameBuffer..ch
    end
end

local function handleEnter()
    if auth.awaitingName then
        auth.awaitingName=false
        if auth.nameBuffer==SHIFT_MANAGER then
            auth.ignitionAuthorized=true
            if reactor.phase==0 then reactor.phase=1 end
            log("Ignition authorized by "..auth.nameBuffer)
        else
            log("Authorization DENIED: invalid name")
            alarm("AUTH_FAIL","AUTHORIZATION DENIED")
        end
        auth.nameBuffer=""
    end
end

-- ╔══════════════════════════════════════════╗
-- ║  SETUP                                   ║
-- ╚══════════════════════════════════════════╝
local function setup()
    local function tryWrap(name)
        if name and peripheral.isPresent(name) then
            return peripheral.wrap(name)
        end
        return nil
    end

    monOver=tryWrap(PNAMES.monOver)
    monCtrl=tryWrap(PNAMES.monCtrl)
    monSync=tryWrap(PNAMES.monSync)
    spk    =tryWrap(PNAMES.speaker)

    -- Auto-discover if names missed
    if not monOver or not monCtrl then
        local found={}
        for _,name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name)=="monitor" then
                table.insert(found,{name=name,wrap=peripheral.wrap(name)})
            end
        end
        if not monOver and found[1] then monOver=found[1].wrap end
        if not monCtrl and found[2] then monCtrl=found[2].wrap end
        if not monSync and found[3] then monSync=found[3].wrap end
    end

    local function cfg(mon,scale)
        if not mon then return end
        mon.setTextScale(scale or 0.5)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.clear()
    end
    cfg(monOver,0.5)
    cfg(monCtrl,0.5)
    cfg(monSync,0.5)

    buildCtrlBtns()
    math.randomseed(os.time())

    log("NRCS v4.0 boot – NARAMO Unit 1")
    log("Awaiting shift manager authorization")

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lime)
    term.clear()
    term.setCursorPos(1,1)
    print("====================================")
    print("  NARAMO NRCS v4.0  –  Unit 1")
    print("====================================")
    print("OVR="..(monOver and "OK" or "MISS")..
          " CTL="..(monCtrl and "OK" or "MISS")..
          " SYN="..(monSync and "OK" or "MISS"))
    print("")
    print("KEYBOARD:")
    print("  X         SCRAM")
    print("  A         Ack all alarms")
    print("  [  ]      Rod -1% / +1%")
    print("  UP DN     Rod -5% / +5%")
    print("  1 2       Toggle turbine")
    print("  C         Coolant toggle")
    print("  F         Feedwater toggle")
    print("  , .       Demand -/+100MW")
    print("  Q         Quit")
    print("")
    print("Running... touch monitors to operate")
end

-- ╔══════════════════════════════════════════╗
-- ║  MAIN LOOP                               ║
-- ╚══════════════════════════════════════════╝
local function main()
    setup()
    local tick=os.startTimer(TICK)

    while running do
        local ev,p1,p2,p3=os.pullEvent()

        if ev=="timer" and p1==tick then
            updatePhysics()
            if auth.awaitingName then
                drawCtrlPanel()
                drawAuthPrompt()
            else
                drawOverview()
                drawCtrlPanel()
                drawSyncMonitor()
            end
            tick=os.startTimer(TICK)

        elseif ev=="monitor_touch" then
            handleMonitorTouch(p1,p2,p3)

        elseif ev=="key" then
            handleKey(p1)

        elseif ev=="char" then
            handleChar(p1)

        elseif ev=="key" and p1==keys.enter then
            handleEnter()

        -- CC sends key event for enter, check here too
        end

        -- Handle enter key via key event
        if ev=="key" and p1==keys.enter then
            handleEnter()
        end
    end

    -- Cleanup
    redstone.setOutput(RS.reactor,  false)
    redstone.setOutput(RS.turbine1, false)
    redstone.setOutput(RS.turbine2, false)
    if monOver then monOver.clear() end
    if monCtrl then monCtrl.clear() end
    if monSync then monSync.clear() end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Reactor system shutdown.")
end

main()