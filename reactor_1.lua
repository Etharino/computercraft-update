-- ============================================================
--  NARAMO NUCLEAR POWER PLANT  –  UNIT 1 CONTROL SYSTEM
--  ComputerCraft / CC:Tweaked    v5.0
-- ============================================================
--
--  6-MONITOR LAYOUT  (matches Naramo control room):
--
--    monOver   – Central overview big board
--    monReact  – Reactor Primary  (rods / coolant / feedwater / RVs)
--    monGrid   – Grid Control     (turbines + grid terminal placeholder)
--    monECCS   – ECCS             (SCRAM + filler panels)
--    monODCS   – ODCS             (shutdown pumps + ignition)
--    monShift  – Shift Manager    (authorize ignition + power orders)
--
--  Edit PNAMES below to match your peripheral IDs.
--  Run:  peripheral.getNames()  in-game to list them.
--
--  KEYBOARD (host computer):
--    X  – SCRAM          A  – Ack alarms
--    [  – Rod -1%        ]  – Rod +1%
--    UP – Rod -5%        DN – Rod +5%
--    C  – Coolant        F  – Feedwater
--    1  – Turbine 1      2  – Turbine 2
--    ,  – Demand -100    .  – Demand +100
--    Q  – Quit
-- ============================================================

-- ╔══════════════════════════════════════════════════════╗
-- ║  CONFIG                                              ║
-- ╚══════════════════════════════════════════════════════╝
local PNAMES = {
    monOver  = "monitor_0",
    monReact = "monitor_1",
    monGrid  = "monitor_2",
    monECCS  = "monitor_3",
    monODCS  = "monitor_4",
    monShift = "monitor_5",
    speaker  = "speaker_0",  -- nil to disable
}

local SHIFT_MANAGER = "Etharino"

local RS = {
    reactor  = "back",
    turbine1 = "right",
    turbine2 = "left",
}

local TICK = 0.5  -- physics interval (seconds)

-- ╔══════════════════════════════════════════════════════╗
-- ║  PHYSICS CONSTANTS                                   ║
-- ╚══════════════════════════════════════════════════════╝
local C = {
    T_STALL      = 323,
    T_IGNITE     = 650,
    T_SYNC_OPT   = 1420,
    T_MELTDOWN   = 3120,
    T_SAVE_MAX   = 800,

    P_STALL      = 101.3,
    P_WARN       = 8274,
    P_CRIT       = 10342,
    P_MAX        = 12411,

    MW_RATED     = 3200,
    MW_TURB      = 1500,

    FW_WARN      = 60,
    FW_CRIT      = 30,

    RPM_SYNC     = 3000,
    RPM_EXPLODE  = 5000,
    FLOW_OPT     = 3.61,

    RV_RATE      = 7.5,
    RV_DURATION  = 10,
    RV_COOLDOWN  = 90,

    MELTDOWN_SAVE_TIME = 240,
}

-- ╔══════════════════════════════════════════════════════╗
-- ║  STATE                                               ║
-- ╚══════════════════════════════════════════════════════╝
local mons = {}   -- populated in setup()
local spk

local running = true

-- Authorization
local auth = {
    ignitionAuthorized = false,
    pumpsOn            = false,
    awaitingName       = false,
    nameBuffer         = "",
}

-- Reactor core
local rx = {
    phase          = 0,
    -- 0=shutdown 1=authorized 2=pumps 3=igniting 4=online 5=scram 6=meltdown
    temperature    = C.T_STALL,
    pressure       = C.P_STALL,
    rodPos         = 100,
    coolantOn      = false,
    feedwaterOn    = false,
    thermalMW      = 0,
    uptime         = 0,

    meltdownActive = false,
    meltdownTimer  = 0,
    meltdownMult   = 0,
    meltdownSaved  = false,

    rvs = {
        {active=false,timer=0,cooldown=0},
        {active=false,timer=0,cooldown=0},
        {active=false,timer=0,cooldown=0},
        {active=false,timer=0,cooldown=0},
    },
}

-- Power orders
local powerOrders = {
    { name="BASE LOAD",  mw=800,  active=true  },
    { name="MID LOAD",   mw=1500, active=false },
    { name="PEAK LOAD",  mw=2400, active=false },
    { name="FULL POWER", mw=3000, active=false },
}
local demandMW    = 800
local generatedMW = 0

-- Turbines
local turbines = {
    {
        id=1, name="TG-1",
        online=false, synced=false, broken=false,
        rpm=0, load=0, steamFlow=0, breaker=false,
        scopeAngle=0, rpmDelta=0,
        flowRate=0, flowStep=0, rpmSpeed="S",
        repairPrompt=false, repairScreen=nil, repairTimer=0,
    },
    {
        id=2, name="TG-2",
        online=false, synced=false, broken=false,
        rpm=0, load=0, steamFlow=0, breaker=false,
        scopeAngle=0, rpmDelta=0,
        flowRate=0, flowStep=0, rpmSpeed="S",
        repairPrompt=false, repairScreen=nil, repairTimer=0,
    },
}

-- Alarms & log
local alarms   = {}
local alarmFlash = false
local eventLog = {}
local LOG_MAX  = 16

-- Screen names for random repair prompts
local screenNames = {"monOver","monReact","monGrid","monECCS","monODCS","monShift"}

-- ╔══════════════════════════════════════════════════════╗
-- ║  UTILITIES                                           ║
-- ╚══════════════════════════════════════════════════════╝
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function lerp(a,b,t)  return a+(b-a)*t end
local function rnd(v,d)
    local f=10^(d or 0); return math.floor(v*f+0.5)/f
end

local function log(msg)
    local ts=string.format("[%02d:%02d:%02d]",
        math.floor(rx.uptime/3600),
        math.floor((rx.uptime%3600)/60),
        math.floor(rx.uptime%60))
    table.insert(eventLog,1,ts.." "..msg)
    while #eventLog>LOG_MAX do table.remove(eventLog) end
end

local function alarm(id,msg)
    for _,a in ipairs(alarms) do if a.id==id then return end end
    table.insert(alarms,{id=id,msg=msg})
    log("ALARM: "..msg)
end

local function clearAlarm(id)
    for i,a in ipairs(alarms) do
        if a.id==id then table.remove(alarms,i); return end
    end
end

local function ackAll()
    alarms={}
    log("All alarms acknowledged")
end

local function hasAlarms() return #alarms>0 end
local function alarmLevel()
    for _,a in ipairs(alarms) do
        if a.id:find("MELT") or a.id:find("SCRAM") or a.id:find("EXPLO") then
            return "CRIT"
        end
    end
    if hasAlarms() then return "WARN" end
    return nil
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  SCRAM                                               ║
-- ╚══════════════════════════════════════════════════════╝
local function doSCRAM(reason)
    if rx.phase==5 or rx.phase==0 then return end
    rx.rodPos       = 100
    rx.meltdownMult = 0
    rx.phase        = 5
    for _,t in ipairs(turbines) do
        if not t.broken then
            t.synced=false; t.breaker=false; t.online=false
        end
    end
    alarm("SCRAM","SCRAM: "..reason)
    log("*** SCRAM: "..reason.." ***")
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  RELIEF VALVES                                       ║
-- ╚══════════════════════════════════════════════════════╝
local function fireRV(i)
    local rv=rx.rvs[i]
    if rv.active or rv.cooldown>0 then return end
    rv.active=true; rv.timer=C.RV_DURATION
    log("RV-"..i.." opened")
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  TURBINE EXPLOSION                                   ║
-- ╚══════════════════════════════════════════════════════╝
local function explodeTurbine(t)
    if t.broken then return end
    t.broken=true; t.online=false; t.synced=false
    t.breaker=false; t.rpm=0; t.load=0
    alarm("EXPLO_"..t.id, t.name.." DESTROYED – OVERSPEED")
    log(t.name.." EXPLODED at overspeed!")
    t.repairTimer=5; t.repairPrompt=false
    t.repairScreen=screenNames[math.random(1,#screenNames)]
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  PHYSICS                                             ║
-- ╚══════════════════════════════════════════════════════╝
local function updatePhysics()
    local dt=TICK
    if rx.phase>=3 and rx.phase~=5 then rx.uptime=rx.uptime+dt end

    -- ── Relief valves ────────────────────────────────────
    local rvCool=0
    for i,rv in ipairs(rx.rvs) do
        if rv.active then
            rv.timer=rv.timer-dt
            rvCool=rvCool+C.RV_RATE*dt
            if rv.timer<=0 then
                rv.active=false; rv.cooldown=C.RV_COOLDOWN
                log("RV-"..i.." closed")
            end
        elseif rv.cooldown>0 then
            rv.cooldown=math.max(0,rv.cooldown-dt)
        end
    end
    rx.temperature=math.max(C.T_STALL,rx.temperature-rvCool)

    -- ── Meltdown ─────────────────────────────────────────
    if rx.meltdownActive then
        rx.meltdownTimer=rx.meltdownTimer+dt
        rx.meltdownMult=rx.meltdownMult+(0.002+rx.meltdownMult*0.15)*dt
        rx.temperature=rx.temperature+rx.meltdownMult*80*dt

        local saving=rx.coolantOn and rx.feedwaterOn
                     and rx.rodPos>=99 and rx.phase==5
        if saving then
            rx.meltdownMult=math.max(0,rx.meltdownMult-0.8*dt)
        end

        if rx.temperature<C.T_SAVE_MAX then
            rx.meltdownActive=false; rx.meltdownSaved=true
            rx.meltdownMult=0
            clearAlarm("MELT")
            alarm("MELT_SAVED","MELTDOWN AVERTED")
            log("MELTDOWN AVERTED – under 800K")
        end
        if rx.meltdownTimer>C.MELTDOWN_SAVE_TIME
           and rx.temperature>=C.T_SAVE_MAX then
            rx.phase=6
            alarm("MELT_FAIL","CATASTROPHIC MELTDOWN")
            log("MELTDOWN: CONTAINMENT BREACHED")
        end
    end

    -- ── Core temperature ─────────────────────────────────
    local rodEffect=clamp((100-rx.rodPos)/100,0,1)

    if rx.phase==3 then
        rx.temperature=rx.temperature+8*dt
        rx.pressure=lerp(rx.pressure,C.P_STALL+200,dt*0.05)
        if rx.temperature>=C.T_IGNITE then
            rx.phase=4
            log("Reactor critical – nominal power")
        end

    elseif rx.phase==4 then
        local coolF=rx.coolantOn and 0.55 or 0
        local tgt=lerp(C.T_STALL,C.T_MELTDOWN*0.88,rodEffect)
                  *(1-coolF*0.5)
        tgt=math.max(C.T_STALL,tgt)
        rx.temperature=lerp(rx.temperature,tgt,dt*0.018)

        local pTgt=lerp(C.P_STALL,C.P_CRIT*0.9,
            clamp((rx.temperature-C.T_STALL)/(C.T_MELTDOWN-C.T_STALL),0,1))
        rx.pressure=lerp(rx.pressure,pTgt,dt*0.03)

        local tf=clamp((rx.temperature-C.T_STALL)/(C.T_SYNC_OPT-C.T_STALL),0,1.1)
        rx.thermalMW=lerp(rx.thermalMW,C.MW_RATED*rodEffect*tf,dt*0.04)

        if rx.temperature>=C.T_MELTDOWN and not rx.meltdownActive
           and not rx.meltdownSaved then
            rx.meltdownActive=true; rx.meltdownTimer=0; rx.meltdownMult=0.001
            alarm("MELT","MELTDOWN – SCRAM IMMEDIATELY")
            log("!!! MELTDOWN at "..rnd(rx.temperature,0).."K !!!")
        end
        if rx.pressure>=C.P_MAX then
            doSCRAM("OVER PRESSURE "..rnd(rx.pressure,0).."kPa")
        end

    elseif rx.phase==5 then
        local cr=rx.coolantOn and 0.05 or 0.025
        rx.temperature=lerp(rx.temperature,C.T_STALL,dt*cr)
        rx.pressure=lerp(rx.pressure,C.P_STALL,dt*0.04)
        rx.thermalMW=lerp(rx.thermalMW,0,dt*0.08)

    elseif rx.phase<=2 then
        rx.temperature=C.T_STALL; rx.pressure=C.P_STALL; rx.thermalMW=0
    end

    if rx.feedwaterOn and rx.phase==4 then
        rx.temperature=rx.temperature-12*dt
    end

    -- ── Alarms ───────────────────────────────────────────
    if rx.phase==4 or rx.phase==5 then
        if rx.temperature>=2800 then alarm("CRIT_T","CRITICAL TEMP "..rnd(rx.temperature,0).."K")
        elseif rx.temperature>=2000 then alarm("WARN_T","HIGH TEMP "..rnd(rx.temperature,0).."K")
        else clearAlarm("CRIT_T"); clearAlarm("WARN_T") end

        if rx.pressure>=C.P_CRIT then alarm("CRIT_P","CRITICAL PRESSURE")
        elseif rx.pressure>=C.P_WARN then alarm("WARN_P","HIGH PRESSURE")
        else clearAlarm("CRIT_P"); clearAlarm("WARN_P") end
    end

    -- ── Turbines ─────────────────────────────────────────
    generatedMW=0

    for _,t in ipairs(turbines) do
        -- Repair prompt countdown
        if t.broken and not t.repairPrompt and t.repairTimer>0 then
            t.repairTimer=t.repairTimer-dt
            if t.repairTimer<=0 then t.repairPrompt=true end
        end

        if t.broken or not t.online then
            t.rpm=lerp(t.rpm,0,dt*0.06)
            t.load=0; t.synced=false; t.breaker=false
        else
            local tempDiff=(rx.temperature-C.T_SYNC_OPT)/1000
            local flowDrift=tempDiff*0.08*dt
            local stepFlow={[-2]=C.FLOW_OPT-1.2,[-1]=C.FLOW_OPT-0.5,
                [0]=C.FLOW_OPT,[1]=C.FLOW_OPT+0.5,[2]=C.FLOW_OPT+1.2}
            local fTgt=stepFlow[t.flowStep] or C.FLOW_OPT
            t.flowRate=lerp(t.flowRate,clamp(fTgt+flowDrift,0.5,8.0),dt*0.1)

            local sMult=t.rpmSpeed=="S" and 0.4
                        or t.rpmSpeed=="M" and 1.0 or 2.5
            local flowErr=t.flowRate-C.FLOW_OPT
            local rpmTgt=C.RPM_SYNC+flowErr*300

            if t.synced then
                t.rpm=lerp(t.rpm,C.RPM_SYNC,dt*0.3)
            else
                t.rpm=lerp(t.rpm,rpmTgt,dt*0.015*sMult)
            end
            t.rpm=math.max(0,t.rpm)

            t.rpmDelta=t.rpm-C.RPM_SYNC
            if not t.synced then
                local spinRPS=t.rpmDelta/60
                t.scopeAngle=(t.scopeAngle+spinRPS*360*dt)%360
                if t.scopeAngle<0 then t.scopeAngle=t.scopeAngle+360 end
            end

            if t.rpm>=C.RPM_EXPLODE then explodeTurbine(t) end

            if t.synced and t.breaker then
                local sc=0
                for _,tt in ipairs(turbines) do
                    if tt.synced and tt.breaker and not tt.broken then sc=sc+1 end
                end
                local share=sc>0 and demandMW/sc or 0
                t.load=lerp(t.load,clamp(share/C.MW_TURB*100,0,100),dt*0.04)
                t.steamFlow=t.load/100*480
            else
                t.load=0; t.steamFlow=0
            end

            if not rx.feedwaterOn and t.synced then
                t.synced=false; t.breaker=false; t.online=false
                alarm("FW_TRIP_"..t.id,t.name.." TRIPPED – FEEDWATER LOST")
                log(t.name.." tripped: feedwater lost")
            end
        end

        if t.synced and t.breaker then
            generatedMW=generatedMW+(t.load/100)*C.MW_TURB
        end
    end

    alarmFlash=not alarmFlash

    redstone.setOutput(RS.reactor,  rx.phase==4)
    redstone.setOutput(RS.turbine1, turbines[1].synced)
    redstone.setOutput(RS.turbine2, turbines[2].synced)

    if spk and hasAlarms() and alarmFlash then
        local lvl=alarmLevel()
        pcall(function()
            if lvl=="CRIT" then spk.playNote("bit",1,24)
            else spk.playNote("bit",0.4,14) end
        end)
    end
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  DRAW HELPERS                                        ║
-- ╚══════════════════════════════════════════════════════╝
local function mw(m,x,y,txt,fg,bg)
    if not m then return end
    if bg then m.setBackgroundColor(bg) end
    if fg then m.setTextColor(fg) end
    m.setCursorPos(x,y)
    m.write(txt)
end

local function mfill(m,x,y,w,h,bg,fg,ch)
    if not m then return end
    ch=ch or " "
    m.setBackgroundColor(bg)
    if fg then m.setTextColor(fg) end
    for r=y,y+h-1 do
        m.setCursorPos(x,r)
        m.write(string.rep(ch,w))
    end
end

local function mcenter(m,y,txt,fg,bg)
    if not m then return end
    local W=select(1,m.getSize())
    local x=math.max(1,math.floor((W-#txt)/2)+1)
    mw(m,x,y,txt,fg,bg)
end

local function mbar(m,x,y,w,pct,cf,ce)
    if not m then return end
    pct=clamp(pct,0,100)
    local f=math.floor(pct/100*w)
    m.setCursorPos(x,y)
    m.setBackgroundColor(cf)
    m.write(string.rep("\127",f))
    m.setBackgroundColor(ce or colors.gray)
    m.write(string.rep(" ",w-f))
end

local function mhline(m,y,fg,bg)
    if not m then return end
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

-- Header bar helper
local function mheader(m,title,statusTxt,statusBG)
    if not m then return end
    local W=select(1,m.getSize())
    mfill(m,1,1,W,1,colors.gray)
    mw(m,2,1,title,colors.white,colors.gray)
    if statusTxt then
        local s=" "..statusTxt.." "
        mw(m,W-#s,1,s,colors.black,statusBG or colors.gray)
    end
end

-- Phase badge helpers
local PHASE_NAME={[0]="SHUTDOWN",[1]="AUTHORIZED",[2]="PUMPS ON",
    [3]="IGNITING",[4]="ONLINE",[5]="SCRAM",[6]="MELTDOWN"}
local PHASE_BG  ={[0]=colors.gray,[1]=colors.blue,[2]=colors.cyan,
    [3]=colors.yellow,[4]=colors.lime,[5]=colors.orange,[6]=colors.red}

local function phaseBadge()
    local ph=rx.phase
    local nm=PHASE_NAME[ph] or "???"
    local bg=PHASE_BG[ph] or colors.gray
    if ph==5 and alarmFlash then bg=colors.red end
    if ph==6 then bg=alarmFlash and colors.red or colors.orange end
    return nm,bg
end

-- Alarm banner on any monitor (row 2)
local function mAlarmBanner(m)
    if not m then return end
    local W=select(1,m.getSize())
    local lvl=alarmLevel()
    if lvl then
        local abg=(lvl=="CRIT" and alarmFlash) and colors.red or colors.orange
        mfill(m,1,2,W,1,abg)
        local atxt="\7 "
        for i,a in ipairs(alarms) do
            atxt=atxt..a.msg
            if i<#alarms then atxt=atxt.."  |  " end
            if #atxt>W-4 then atxt=atxt:sub(1,W-6).."..."; break end
        end
        mcenter(m,2,atxt.." \7",colors.white,abg)
    else
        mfill(m,1,2,W,1,colors.black)
        mw(m,2,2,"\4 All systems nominal",colors.lime,colors.black)
    end
end

-- Button drawing (stateless – pass current bg/fg)
local function drawBtn(m,x,y,w,h,lines,bg,fg)
    if not m then return end
    mfill(m,x,y,w,h,bg)
    local midY=y+math.floor(h/2)
    local half=math.floor(#lines/2)
    for i,ln in ipairs(lines) do
        local lx=x+math.floor((w-#ln)/2)
        mw(m,lx,midY-half+i-1,ln,fg,bg)
    end
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  BUTTON REGISTRIES  (per screen)                     ║
-- ╚══════════════════════════════════════════════════════╝
-- Each entry: {id, x,y,w,h}  – built fresh each draw,
-- so hit-test can just walk the list.
local btnReact  = {}
local btnGrid   = {}
local btnECCS   = {}
local btnODCS   = {}
local btnShift  = {}
local repairBtns= {}  -- {t=turbine,x,y,w,h,screen}

local function regBtn(tbl,id,x,y,w,h)
    table.insert(tbl,{id=id,x=x,y=y,w=w,h=h})
end

local function hitTest(tbl,mx,my)
    for _,b in ipairs(tbl) do
        if mx>=b.x and mx<b.x+b.w and my>=b.y and my<b.y+b.h then
            return b.id
        end
    end
    return nil
end

local function hitRepair(screen,mx,my)
    for _,b in ipairs(repairBtns) do
        if b.screen==screen
           and mx>=b.x and mx<b.x+b.w
           and my>=b.y and my<b.y+b.h then
            return b.t
        end
    end
    return nil
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  OVERVIEW MONITOR                                    ║
-- ╚══════════════════════════════════════════════════════╝
local function drawOverview()
    local m=mons.monOver
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()

    local phN,phB=phaseBadge()
    mheader(m,"NARAMO NUCLEAR POWER PLANT  –  UNIT 1  OVERVIEW",phN,phB)
    mAlarmBanner(m)

    -- 3-column layout
    local c1W=math.floor(W/3)
    local c2X=c1W+2; local c2W=c1W-1
    local c3X=c1W*2+2; local c3W=W-c3X+1
    local r=3

    -- ── Col 1: Reactor Core ───────────────────────────
    mfill(m,1,r,c1W,1,colors.blue)
    mw(m,2,r,"  REACTOR CORE",colors.white,colors.blue); r=r+1

    local tc=valC(rx.temperature,2000,2800,true)
    mw(m,2,r,"TEMP    ",colors.lightGray,colors.black)
    mw(m,c1W-9,r,string.format("%6.0fK",rx.temperature),tc,colors.black); r=r+1
    mbar(m,2,r,c1W-2,rx.temperature/C.T_MELTDOWN*100,tc,colors.gray); r=r+1

    local pc=valC(rx.pressure,C.P_WARN,C.P_CRIT,true)
    mw(m,2,r,"PRESSURE",colors.lightGray,colors.black)
    mw(m,c1W-9,r,string.format("%4.0fkPa",rx.pressure),pc,colors.black); r=r+1
    mbar(m,2,r,c1W-2,rx.pressure/C.P_MAX*100,pc,colors.gray); r=r+1

    local rodC=rx.rodPos>85 and colors.gray
               or rx.rodPos<20 and colors.red or colors.yellow
    mw(m,2,r,"CTRL ROD",colors.lightGray,colors.black)
    mw(m,c1W-9,r,string.format("%3.0f%% IN",rx.rodPos),rodC,colors.black); r=r+1
    mbar(m,2,r,c1W-2,rx.rodPos,colors.purple,colors.gray); r=r+1

    local cwC=rx.coolantOn and colors.lime or colors.red
    local fwC=rx.feedwaterOn and colors.lime or colors.red
    mw(m,2,r,"COOLANT ",colors.lightGray,colors.black)
    mw(m,12,r,rx.coolantOn and " ON  " or " OFF ",colors.black,cwC); r=r+1
    mw(m,2,r,"FEEDWATR",colors.lightGray,colors.black)
    mw(m,12,r,rx.feedwaterOn and " ON  " or " OFF ",colors.black,fwC); r=r+1

    -- RV status
    mhline(m,r,colors.gray,colors.black); r=r+1
    mw(m,2,r,"RELIEF VALVES",colors.yellow,colors.black); r=r+1
    for i,rv in ipairs(rx.rvs) do
        if r>H-2 then break end
        local rvc=rv.active and colors.lime or rv.cooldown>0 and colors.orange or colors.gray
        local rvt=rv.active and string.format("RV-%d OPEN  %.0fs",i,rv.timer)
                 or rv.cooldown>0 and string.format("RV-%d CDN   %.0fs",i,rv.cooldown)
                 or string.format("RV-%d READY",i)
        mw(m,2,r,rvt,rvc,colors.black); r=r+1
    end

    if rx.meltdownActive and r<=H-1 then
        local rem=C.MELTDOWN_SAVE_TIME-rx.meltdownTimer
        mw(m,2,r,string.format("MELT T-%3.0fs X%.2f",rem,rx.meltdownMult),
           alarmFlash and colors.red or colors.orange,colors.black)
    end

    -- ── Col 2: Primary loop + Power ───────────────────
    local mr=3
    mfill(m,c2X,mr,c2W,1,colors.blue)
    mw(m,c2X+1,mr,"  PRIMARY / POWER",colors.white,colors.blue); mr=mr+1

    mw(m,c2X,mr,"SHUTDOWN PUMPS",colors.lightGray,colors.black)
    local ppbg=auth.pumpsOn and colors.lime or colors.red
    mw(m,c2X+c2W-6,mr,auth.pumpsOn and " RUN  " or " STOP ",
       colors.black,ppbg); mr=mr+1

    local thC=rx.thermalMW>C.MW_RATED*0.8 and colors.orange or colors.lime
    mw(m,c2X,mr,"THERMAL  ",colors.lightGray,colors.black)
    mw(m,c2X+c2W-8,mr,string.format("%5.0f MW",rx.thermalMW),thC,colors.black); mr=mr+1

    mhline(m,mr,colors.gray,colors.black); mr=mr+1
    mfill(m,c2X,mr,c2W,1,colors.blue)
    mw(m,c2X+1,mr,"  POWER & DEMAND",colors.white,colors.blue); mr=mr+1

    mw(m,c2X,mr,"ORDERED  ",colors.lightGray,colors.black)
    mw(m,c2X+c2W-8,mr,string.format("%5.0f MW",demandMW),colors.cyan,colors.black); mr=mr+1

    local gmC=math.abs(generatedMW-demandMW)<100 and colors.lime or colors.orange
    mw(m,c2X,mr,"GENERATED",colors.lightGray,colors.black)
    mw(m,c2X+c2W-8,mr,string.format("%5.0f MW",generatedMW),gmC,colors.black); mr=mr+1
    mbar(m,c2X,mr,c2W,generatedMW/(C.MW_TURB*2)*100,gmC,colors.gray); mr=mr+1

    mhline(m,mr,colors.gray,colors.black); mr=mr+1
    mfill(m,c2X,mr,c2W,1,colors.blue)
    mw(m,c2X+1,mr,"  TURBINES",colors.white,colors.blue); mr=mr+1

    for _,t in ipairs(turbines) do
        if mr>H-2 then break end
        local tbg=t.broken and colors.red or t.synced and colors.lime
                  or t.online and colors.yellow or colors.gray
        local tst=t.broken and "FAULT"
                  or t.synced and string.format("SYNC %4.0fRPM %3.0f%%",t.rpm,t.load)
                  or t.online and string.format("SPIN %4.0fRPM",t.rpm)
                  or "OFFLINE"
        mfill(m,c2X,mr,c2W,1,tbg)
        mw(m,c2X,mr,string.format(" %s %s ",t.name,tst):sub(1,c2W),
           colors.black,tbg); mr=mr+1

        -- Repair prompt on overview
        if t.repairPrompt and t.repairScreen=="monOver" and mr<=H-1 then
            mfill(m,c2X,mr,c2W,1,colors.red)
            mw(m,c2X,mr," >> CLICK TO REPAIR "..t.name.." <<",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=c2X,y=mr,w=c2W,h=1,screen="monOver"})
            mr=mr+1
        end
    end

    -- ── Col 3: Event log ──────────────────────────────
    local pr=3
    mfill(m,c3X,pr,c3W,1,colors.blue)
    mw(m,c3X+1,pr,"  EVENT LOG",colors.white,colors.blue); pr=pr+1

    local upStr=string.format("UP %02d:%02d:%02d",
        math.floor(rx.uptime/3600),
        math.floor((rx.uptime%3600)/60),
        math.floor(rx.uptime%60))
    mw(m,c3X,pr,upStr,colors.lightGray,colors.black); pr=pr+2

    for i,entry in ipairs(eventLog) do
        if pr+i-1>H-1 then break end
        local ec=entry:find("SCRAM") and colors.red
                 or entry:find("MELT") and colors.orange
                 or entry:find("ALARM") and colors.orange
                 or entry:find("online") and colors.lime
                 or entry:find("sync") and colors.cyan
                 or colors.lightGray
        mw(m,c3X,pr+i-1,entry:sub(1,c3W),ec,colors.black)
    end

    -- Footer
    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,string.format(
        "T:%5.0fK  P:%6.0fkPa  MW:%5.0f/%5.0f  ROD:%3.0f%%  FW:%s  COOL:%s",
        rx.temperature,rx.pressure,generatedMW,demandMW,rx.rodPos,
        rx.feedwaterOn and "ON" or "OFF",
        rx.coolantOn   and "ON" or "OFF"),
       colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  REACTOR PRIMARY MONITOR                             ║
-- ╚══════════════════════════════════════════════════════╝
local function drawReactorPrimary()
    local m=mons.monReact
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    btnReact={}

    local phN,phB=phaseBadge()
    mheader(m,"REACTOR PRIMARY",phN,phB)
    mAlarmBanner(m)

    local row=3

    -- ── ROD CONTROL ───────────────────────────────────
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  CONTROL RODS",colors.white,colors.blue); row=row+1

    -- Rod position bar + value
    local rodC=rx.rodPos>85 and colors.gray
               or rx.rodPos<20 and colors.red or colors.yellow
    mw(m,2,row,"POSITION",colors.lightGray,colors.black)
    mw(m,W-9,row,string.format("%3.0f%% IN",rx.rodPos),rodC,colors.black); row=row+1
    mbar(m,2,row,W-2,rx.rodPos,colors.purple,colors.gray); row=row+1

    -- Tick marks 0-100
    for pct=0,100,10 do
        local tx=2+math.floor(pct/100*(W-3))
        if tx<=W then
            mw(m,tx,row,tostring(pct),colors.lightGray,colors.black)
        end
    end
    row=row+2

    -- Rod adjust buttons: -5, -1, +1, +5
    local bw=math.floor((W-2)/4)
    local btns={
        {id="ROD_W5",lbl={"-5%","WDRW"},bg=colors.yellow,fg=colors.black},
        {id="ROD_W1",lbl={"-1%","WDRW"},bg=colors.yellow,fg=colors.black},
        {id="ROD_I1",lbl={"+1%","INST"},bg=colors.orange,fg=colors.black},
        {id="ROD_I5",lbl={"+5%","INST"},bg=colors.orange,fg=colors.black},
    }
    for i,b in ipairs(btns) do
        local bx=2+(i-1)*bw
        drawBtn(m,bx,row,bw-1,3,b.lbl,b.bg,b.fg)
        regBtn(btnReact,b.id,bx,row,bw-1,3)
    end
    row=row+4

    -- ── COOLANT ───────────────────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  COOLANT SYSTEM",colors.white,colors.blue); row=row+1

    local cbg=rx.coolantOn and colors.lime or colors.cyan
    drawBtn(m,2,row,math.floor(W/2)-2,3,
            {rx.coolantOn and "COOLANT" or "COOLANT","ON/OFF"},cbg,colors.black)
    regBtn(btnReact,"COOLANT",2,row,math.floor(W/2)-2,3)

    -- Coolant status indicator
    local cstatBG=rx.coolantOn and colors.lime or colors.gray
    mfill(m,math.floor(W/2)+1,row,math.floor(W/2)-2,3,cstatBG)
    mw(m,math.floor(W/2)+2,row+1,
       rx.coolantOn and "  FLOWING  " or "  STOPPED  ",
       colors.black,cstatBG)
    row=row+4

    -- ── FEEDWATER ─────────────────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  FEEDWATER SYSTEM",colors.white,colors.blue); row=row+1

    local fbg=rx.feedwaterOn and colors.lime or colors.blue
    local ffg=rx.feedwaterOn and colors.black or colors.white
    drawBtn(m,2,row,math.floor(W/2)-2,3,
            {rx.feedwaterOn and "FEEDWATER" or "FEEDWATER","ON/OFF"},fbg,ffg)
    regBtn(btnReact,"FEEDWTR",2,row,math.floor(W/2)-2,3)

    local fstatBG=rx.feedwaterOn and colors.lime or colors.gray
    mfill(m,math.floor(W/2)+1,row,math.floor(W/2)-2,3,fstatBG)
    mw(m,math.floor(W/2)+2,row+1,
       rx.feedwaterOn and "  PUMPING  " or "  OFFLINE  ",
       colors.black,fstatBG)
    row=row+4

    -- ── RELIEF VALVES ─────────────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  RELIEF VALVES  (4x RV)",colors.white,colors.blue); row=row+1

    local rvW=math.floor((W-2)/4)
    for i,rv in ipairs(rx.rvs) do
        local rvx=2+(i-1)*rvW
        local rvbg=rv.active and colors.lime
                   or rv.cooldown>0 and colors.orange or colors.gray
        local rvfg=colors.black
        local rvlbl
        if rv.active then
            rvlbl={"RV-"..i,string.format("%.0fs",rv.timer)}
        elseif rv.cooldown>0 then
            rvlbl={"RV-"..i,string.format("CDN%.0f",rv.cooldown)}
        else
            rvlbl={"RV-"..i,"READY"}
        end
        drawBtn(m,rvx,row,rvW-1,3,rvlbl,rvbg,rvfg)
        regBtn(btnReact,"RV"..i,rvx,row,rvW-1,3)
    end
    row=row+4

    -- Live values bar at bottom
    if row<=H-2 then
        mhline(m,row,colors.gray,colors.black); row=row+1
        local tc=valC(rx.temperature,2000,2800,true)
        mw(m,2,row,string.format("T: %5.0fK",rx.temperature),tc,colors.black)
        local pc=valC(rx.pressure,C.P_WARN,C.P_CRIT,true)
        mw(m,14,row,string.format("P: %5.0fkPa",rx.pressure),pc,colors.black)
        mw(m,30,row,string.format("MW: %5.0f",rx.thermalMW),colors.cyan,colors.black)
    end

    -- Repair prompt
    for _,t in ipairs(turbines) do
        if t.repairPrompt and t.repairScreen=="monReact" then
            mfill(m,1,H-2,W,2,colors.red)
            mw(m,2,H-2," !! "..t.name.." FAULT – CLICK TO REPAIR !!",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=1,y=H-2,w=W,h=2,screen="monReact"})
        end
    end

    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,"Reactor Primary Control",colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  GRID CONTROL MONITOR  (turbines + grid placeholder) ║
-- ╚══════════════════════════════════════════════════════╝

-- Synchroscope dot positions (12 o'clock = index 1)
local scopeDots={
    {0,-2},{1,-2},{2,-1},{2,0},{2,1},{1,2},
    {0,2},{-1,2},{-2,1},{-2,0},{-2,-1},{-1,-2}
}

local function drawSynchroscope(m,cx,cy,angle,online,synced,broken)
    local n=#scopeDots
    local litIdx=math.floor(angle/360*n)%n+1
    mfill(m,cx-3,cy-2,7,5,colors.black)
    for i,pos in ipairs(scopeDots) do
        local px=cx+pos[1]; local py=cy+pos[2]
        if px>=1 and py>=1 then
            local ch,fg,bg="\7",colors.gray,colors.black
            if broken then fg=colors.red
            elseif not online then fg=colors.gray
            elseif i==1 then
                fg=colors.lime
                ch=synced and "\4" or "\7"
            elseif i==litIdx then fg=colors.white
            end
            mw(m,px,py,ch,fg,bg)
        end
    end
    if online and not broken then
        mw(m,cx,cy,synced and "S" or "\4",
           synced and colors.lime or colors.yellow,colors.black)
    elseif broken then
        mw(m,cx,cy,"X",colors.red,colors.black)
    end
end

local flowLabels={[-2]="--",[-1]="-",[0]="N",[1]="+",[2]="++"}

local function drawTurbinePanel(m,t,px,py,pW,pH)
    -- Header
    local hbg=t.broken and colors.red or t.synced and colors.lime
              or t.online and colors.yellow or colors.gray
    mfill(m,px,py,pW,pH,colors.black)
    mfill(m,px,py,pW,1,hbg)
    local hst=t.broken and "FAULT" or t.synced and "SYNCED"
              or t.online and "SPINNING" or "OFFLINE"
    mw(m,px,py,string.format(" %s  %s ",t.name,hst):sub(1,pW),
       colors.black,hbg)

    local r=py+1

    -- Synchroscope
    local scx=px+math.floor(pW/2)
    local scy=r+2
    drawSynchroscope(m,scx,scy,t.scopeAngle,t.online,t.synced,t.broken)
    r=scy+3

    -- RPM
    local rpmC=t.rpm>=4500 and colors.red or t.rpm>=3500 and colors.orange
               or t.rpm>=2800 and colors.lime or colors.cyan
    mw(m,px,r,"RPM",colors.lightGray,colors.black)
    mw(m,px+pW-6,r,string.format("%4.0f",t.rpm),rpmC,colors.black); r=r+1
    mbar(m,px,r,pW,t.rpm/C.RPM_SYNC*100,rpmC,colors.gray); r=r+1

    -- Flow rate
    local fwC=math.abs(t.flowRate-C.FLOW_OPT)<0.1 and colors.lime
              or math.abs(t.flowRate-C.FLOW_OPT)<0.5 and colors.yellow or colors.orange
    mw(m,px,r,"FLOW",colors.lightGray,colors.black)
    mw(m,px+pW-9,r,string.format("%.2fm\179/s",t.flowRate),fwC,colors.black); r=r+1
    local optMark=math.abs(t.flowRate-C.FLOW_OPT)<0.15 and "\4 OPTIMAL" or "  OPT=3.61"
    mw(m,px,r,optMark,fwC,colors.black); r=r+1

    -- Load
    mw(m,px,r,"LOAD",colors.lightGray,colors.black)
    mw(m,px+pW-6,r,string.format("%4.1f%%",t.load),colors.white,colors.black); r=r+1

    -- Grid breaker status
    local brkBG=t.broken and colors.red or t.breaker and colors.lime
                or t.synced and colors.yellow or colors.gray
    local brkTxt=t.broken and " FAULT  " or t.breaker and " CLOSED "
                 or t.synced and " OPEN   " or " OPEN   "
    mfill(m,px,r,pW,1,brkBG)
    mw(m,px,r,"BREAKER"..brkTxt,colors.black,brkBG); r=r+1

    if r>py+pH-1 then return r end

    -- Speed selector
    mw(m,px,r,"SPD:",colors.lightGray,colors.black)
    local sps={"S","M","F"}
    for i,sp in ipairs(sps) do
        local sx=px+5+(i-1)*3
        mw(m,sx,r," "..sp.." ",colors.black,
           t.rpmSpeed==sp and colors.yellow or colors.gray)
    end
    r=r+1

    if r>py+pH-1 then return r end

    -- Flow step buttons
    mw(m,px,r,"FLW:",colors.lightGray,colors.black)
    local bx=px+5
    local steps={{-2,"--"},{-1,"-"},{0,"N"},{1,"+"},{2,"++"}}
    for _,s in ipairs(steps) do
        local sbg=t.flowStep==s[1] and colors.cyan or colors.gray
        mw(m,bx,r,s[2],colors.black,sbg)
        bx=bx+#s[2]+1
    end
    r=r+1

    if r>py+pH-1 then return r end

    -- Sync switch
    if t.online and not t.synced and not t.broken then
        local angN=t.scopeAngle%360
        local nearSync=(angN<30 or angN>330) and math.abs(t.rpm-C.RPM_SYNC)<120
        local sbg=nearSync and colors.lime or colors.gray
        mfill(m,px,r,pW,1,sbg)
        mw(m,px,r,nearSync and "[ SYNC NOW ]" or "[ SYNC WHEN READY ]",
           colors.black,sbg); r=r+1
    elseif t.synced then
        mfill(m,px,r,pW,1,colors.lime)
        mw(m,px,r,"[ SYNCHRONIZED ]",colors.black,colors.lime); r=r+1
    end

    -- Online/trip toggle
    if r<=py+pH-1 then
        local tbg=t.online and colors.orange or colors.cyan
        local ttxt=t.online and "[ TRIP TURBINE ]" or "[ START TURBINE ]"
        if t.broken then tbg=colors.red; ttxt="[ TURBINE FAULT ]" end
        mfill(m,px,r,pW,1,tbg)
        mw(m,px,r,ttxt,colors.black,tbg)
    end

    return r
end

local syncBtns={}

local function drawGridControl()
    local m=mons.monGrid
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    btnGrid={}
    syncBtns={}

    mheader(m,"GRID CONTROL","UNIT 1",colors.blue)
    mAlarmBanner(m)

    -- Split: left 2/3 = turbines, right 1/3 = grid terminal
    local turbW=math.floor(W*2/3)
    local gridX=turbW+2
    local gridW=W-gridX

    -- Turbine panels side by side
    local pW=math.floor((turbW-1)/2)
    for i,t in ipairs(turbines) do
        local px=1+(i-1)*(pW+1)
        local pH=H-3
        drawTurbinePanel(m,t,px,3,pW,pH)

        -- Register interactive regions
        -- Speed row: r = 3+1+5+2+2+1 = 14  (header+scope+rpm2+flow2+load+breaker)
        local baseR=3+1   -- after header
        local scopeH=5
        local statsH=6    -- rpm bar, flow, optmark, load, breaker = 5
        local speedR=baseR+scopeH+statsH

        -- Speed buttons
        local sps={"S","M","F"}
        for si,sp in ipairs(sps) do
            local sx=px+5+(si-1)*3
            table.insert(syncBtns,{type="speed",t=t,val=sp,
                x=sx,y=speedR,w=3,h=1})
        end

        -- Flow buttons
        local flowR=speedR+1
        local bx=px+5
        local steps={{-2,"--"},{-1,"-"},{0,"N"},{1,"+"},{2,"++"}}
        for _,s in ipairs(steps) do
            table.insert(syncBtns,{type="flow",t=t,val=s[1],
                x=bx,y=flowR,w=#s[2],h=1})
            bx=bx+#s[2]+1
        end

        -- Sync switch
        local syncR=flowR+1
        if t.online and not t.synced and not t.broken then
            table.insert(syncBtns,{type="sync",t=t,
                x=px,y=syncR,w=pW,h=1})
            syncR=syncR+1
        elseif t.synced then
            syncR=syncR+1
        end

        -- Online/trip
        table.insert(syncBtns,{type="online",t=t,
            x=px,y=syncR,w=pW,h=1})

        -- Grid breaker (the breaker status row is at baseR+scopeH+5)
        local brkR=baseR+scopeH+5
        table.insert(syncBtns,{type="breaker",t=t,
            x=px,y=brkR,w=pW,h=1})

        -- Repair prompt
        if t.repairPrompt and t.repairScreen=="monGrid" then
            local rr=H-2
            mfill(m,px,rr,pW,2,colors.red)
            mw(m,px,rr,"!! CLICK TO REPAIR "..t.name.." !!",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=px,y=rr,w=pW,h=2,screen="monGrid"})
        end
    end

    -- ── Grid Terminal (right panel) ───────────────────
    local gr=3
    mfill(m,gridX,gr,gridW,H-gr,colors.black)
    mfill(m,gridX,gr,gridW,1,colors.blue)
    mw(m,gridX+1,gr,"GRID",colors.white,colors.blue); gr=gr+1

    -- Vertical separator
    for vr=3,H-1 do
        mw(m,gridX-1,vr,"\149",colors.gray,colors.black)
    end

    -- Grid terminal placeholder
    mw(m,gridX,gr,"GRID TERMINAL",colors.yellow,colors.black); gr=gr+1
    mhline(m,gr,colors.gray,colors.black); gr=gr+1

    mw(m,gridX,gr,"STATUS",colors.lightGray,colors.black)
    mw(m,gridX,gr+1,"[OFFLINE]",colors.gray,colors.black)
    gr=gr+3

    mw(m,gridX,gr,"CONNECTIONS",colors.lightGray,colors.black); gr=gr+1
    mw(m,gridX,gr,"No grids",colors.gray,colors.black); gr=gr+1
    mw(m,gridX,gr,"connected.",colors.gray,colors.black); gr=gr+2

    mw(m,gridX,gr,"FREQ",colors.lightGray,colors.black)
    mw(m,gridX,gr+1,"50.00 Hz",colors.cyan,colors.black); gr=gr+2

    mw(m,gridX,gr,"VOLTAGE",colors.lightGray,colors.black)
    mw(m,gridX,gr+1,"400 kV",colors.cyan,colors.black); gr=gr+2

    -- Total gen
    mhline(m,gr,colors.gray,colors.black); gr=gr+1
    mw(m,gridX,gr,"OUTPUT",colors.lightGray,colors.black); gr=gr+1
    local gc=math.abs(generatedMW-demandMW)<100 and colors.lime or colors.orange
    mw(m,gridX,gr,string.format("%4.0f MW",generatedMW),gc,colors.black); gr=gr+1
    mw(m,gridX,gr,"DEMAND",colors.lightGray,colors.black); gr=gr+1
    mw(m,gridX,gr,string.format("%4.0f MW",demandMW),colors.cyan,colors.black); gr=gr+1

    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,string.format("SYNC: %d RPM  OPT FLOW: %.2f m3/s  OPT TEMP: %dK",
       C.RPM_SYNC,C.FLOW_OPT,C.T_SYNC_OPT),colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  ECCS MONITOR                                        ║
-- ╚══════════════════════════════════════════════════════╝
local function drawECCS()
    local m=mons.monECCS
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    btnECCS={}

    local phN,phB=phaseBadge()
    mheader(m,"ECCS  –  EMERGENCY CORE COOLING SYSTEM",phN,phB)
    mAlarmBanner(m)

    local row=3

    -- ── SCRAM button (big, centred) ───────────────────
    local sbW=math.min(W-4,24)
    local sbX=math.floor((W-sbW)/2)+1
    local scramBG
    if rx.phase==5 then
        scramBG=alarmFlash and colors.orange or colors.red
    elseif rx.meltdownActive then
        scramBG=alarmFlash and colors.red or colors.orange
    else
        scramBG=colors.red
    end
    mfill(m,sbX,row,sbW,5,scramBG)
    mw(m,sbX+math.floor((sbW-9)/2),row+1,"EMERGENCY",colors.white,scramBG)
    mw(m,sbX+math.floor((sbW-5)/2),row+2,"SCRAM",colors.white,scramBG)
    if rx.phase==5 then
        mw(m,sbX+math.floor((sbW-9)/2),row+3,"[ACTIVATED]",colors.black,scramBG)
    end
    regBtn(btnECCS,"SCRAM",sbX,row,sbW,5)
    row=row+6

    mhline(m,row,colors.gray,colors.black); row=row+1

    -- ── Filler indicator panels ────────────────────────
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  ECCS INDICATORS",colors.white,colors.blue); row=row+1

    -- Simulated indicator lights (non-functional, decorative)
    local indicators={
        {"HI-PRESS INJ",  true},
        {"LO-PRESS INJ",  true},
        {"ACC FLOW A",    true},
        {"ACC FLOW B",    true},
        {"SUMP RECIRC",   false},
        {"BORATION",      false},
        {"SPRAY SYS",     false},
        {"CONT ISOL",     rx.phase==5 or rx.phase==6},
    }
    local iW=math.floor(W/2)-1
    for i,ind in ipairs(indicators) do
        if row>H-2 then break end
        local col=(i-1)%2
        local ix=2+col*(iW+1)
        local indBG=ind[2] and colors.lime or colors.gray
        mfill(m,ix,row,iW,1,indBG)
        mw(m,ix+1,row,ind[1]:sub(1,iW-2),colors.black,indBG)
        if col==1 then row=row+1 end
    end
    row=row+2

    -- Core temp readout on ECCS
    if row<=H-2 then
        mhline(m,row,colors.gray,colors.black); row=row+1
        local tc=valC(rx.temperature,2000,2800,true)
        mw(m,2,row,"CORE TEMP",colors.lightGray,colors.black)
        mw(m,W-9,row,string.format("%6.0fK",rx.temperature),tc,colors.black); row=row+1
        mbar(m,2,row,W-2,rx.temperature/C.T_MELTDOWN*100,tc,colors.gray)
    end

    -- Repair prompt
    for _,t in ipairs(turbines) do
        if t.repairPrompt and t.repairScreen=="monECCS" then
            mfill(m,1,H-2,W,2,colors.red)
            mw(m,2,H-2," !! "..t.name.." FAULT – CLICK TO REPAIR !!",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=1,y=H-2,w=W,h=2,screen="monECCS"})
        end
    end

    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,"Emergency Core Cooling System",colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  ODCS MONITOR  (Startup Control)                     ║
-- ╚══════════════════════════════════════════════════════╝
local function drawODCS()
    local m=mons.monODCS
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    btnODCS={}

    local phN,phB=phaseBadge()
    mheader(m,"ODCS  –  STARTUP CONTROL",phN,phB)
    mAlarmBanner(m)

    local row=3

    -- Startup sequence header
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  STARTUP SEQUENCE",colors.white,colors.blue); row=row+1

    -- Step indicators
    local steps={
        {n="1. AUTHORIZE IGNITION", ok=auth.ignitionAuthorized},
        {n="2. START SHUTDOWN PUMPS",ok=auth.pumpsOn},
        {n="3. IGNITE REACTOR",      ok=rx.phase>=3},
    }
    for _,s in ipairs(steps) do
        local sbg=s.ok and colors.lime or colors.gray
        mfill(m,2,row,W-2,1,sbg)
        mw(m,3,row,(s.ok and "\4 " or "  ")..s.n,colors.black,sbg)
        row=row+1
    end
    row=row+1

    -- ── Step 2: Shutdown pumps ────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  SHUTDOWN PUMPS",colors.white,colors.blue); row=row+1

    local pbg=auth.pumpsOn and colors.lime or colors.cyan
    local pLbl={auth.pumpsOn and "SHUTDOWN PUMPS" or "SHUTDOWN PUMPS",
                auth.pumpsOn and "[ RUNNING ]" or "[ STOPPED ]"}
    drawBtn(m,2,row,W-2,3,pLbl,pbg,colors.black)
    regBtn(btnODCS,"PUMPS",2,row,W-2,3); row=row+4

    -- ── Step 3: Ignite ────────────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  REACTOR IGNITION",colors.white,colors.blue); row=row+1

    local ready=auth.ignitionAuthorized and auth.pumpsOn
                and (rx.phase==0 or rx.phase==1 or rx.phase==2)
    local igbg=ready and colors.lime or colors.gray
    local igfg=ready and colors.black or colors.lightGray
    drawBtn(m,2,row,W-2,4,
            {ready and "IGNITE REACTOR" or "IGNITE REACTOR",
             ready and "(ARMED)" or "(LOCKED)"},
            igbg,igfg)
    regBtn(btnODCS,"IGNITE",2,row,W-2,4); row=row+5

    -- Auth status reminder
    if row<=H-2 then
        mhline(m,row,colors.gray,colors.black); row=row+1
        if auth.ignitionAuthorized then
            mw(m,2,row,"\4 Ignition authorized by "..SHIFT_MANAGER,
               colors.lime,colors.black)
        else
            mw(m,2,row,"! Awaiting ignition authorization",
               colors.orange,colors.black)
            row=row+1
            mw(m,2,row,"  (Shift Manager must authorize)",
               colors.lightGray,colors.black)
        end
    end

    -- Repair prompt
    for _,t in ipairs(turbines) do
        if t.repairPrompt and t.repairScreen=="monODCS" then
            mfill(m,1,H-2,W,2,colors.red)
            mw(m,2,H-2," !! "..t.name.." FAULT – CLICK TO REPAIR !!",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=1,y=H-2,w=W,h=2,screen="monODCS"})
        end
    end

    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,"Operator Display & Control System",colors.white,colors.gray)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  SHIFT MANAGER MONITOR                               ║
-- ╚══════════════════════════════════════════════════════╝
local function drawAuthPromptOverlay(m)
    if not m then return end
    local W,H=m.getSize()
    local bx=2; local bw=W-3
    local by=math.floor(H/2)-4; local bh=8
    mfill(m,bx,by,bw,bh,colors.gray)
    mfill(m,bx+1,by+1,bw-2,bh-2,colors.black)
    mcenter(m,by+1,"IGNITION AUTHORIZATION",colors.yellow,colors.black)
    mcenter(m,by+2,"Enter shift manager name:",colors.white,colors.black)
    mcenter(m,by+3,"("..SHIFT_MANAGER..")",colors.lightGray,colors.black)
    mfill(m,bx+2,by+4,bw-4,1,colors.white)
    mw(m,bx+2,by+4,auth.nameBuffer,colors.black,colors.white)
    mw(m,bx+2+#auth.nameBuffer,by+4,"_",colors.gray,colors.white)
    mcenter(m,by+6,"[ENTER confirm   ESC cancel]",colors.gray,colors.black)
end

local function drawShiftManager()
    local m=mons.monShift
    if not m then return end
    local W,H=m.getSize()
    m.setBackgroundColor(colors.black)
    m.clear()
    btnShift={}

    local phN,phB=phaseBadge()
    mheader(m,"SHIFT MANAGER",phN,phB)
    mAlarmBanner(m)

    local row=3

    -- ── Authorization ─────────────────────────────────
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  IGNITION AUTHORIZATION",colors.white,colors.blue); row=row+1

    local authBG=auth.ignitionAuthorized and colors.lime or colors.blue
    local authFG=auth.ignitionAuthorized and colors.black or colors.white
    local authLbl={
        auth.ignitionAuthorized and "AUTHORIZED" or "AUTHORIZE",
        auth.ignitionAuthorized and "["..SHIFT_MANAGER.."]" or "IGNITION",
    }
    drawBtn(m,2,row,W-2,3,authLbl,authBG,authFG)
    regBtn(btnShift,"AUTH",2,row,W-2,3); row=row+4

    -- ── Power orders ──────────────────────────────────
    mhline(m,row,colors.gray,colors.black); row=row+1
    mfill(m,1,row,W,1,colors.blue)
    mw(m,2,row,"  POWER ORDER DEMAND",colors.white,colors.blue); row=row+1

    for i,po in ipairs(powerOrders) do
        if row>H-4 then break end
        local pobg=po.active and colors.lime or colors.gray
        local pofg=po.active and colors.black or colors.white
        local poW=W-2
        mfill(m,2,row,poW,2,pobg)
        mw(m,3,row,(po.active and "\4 " or "  ")..po.name,pofg,pobg)
        mw(m,poW-5,row,string.format("%4.0fMW",po.mw),pofg,pobg)
        mw(m,3,row+1,po.active and "[ ACTIVE ORDER ]" or "[ CLICK TO SET ]",
           pofg,pobg)
        regBtn(btnShift,"ORDER"..i,2,row,poW,2)
        row=row+3
    end

    -- Custom demand buttons
    if row<=H-4 then
        mhline(m,row,colors.gray,colors.black); row=row+1
        local hw=math.floor((W-3)/2)
        drawBtn(m,2,row,hw,2,{"DEMAND","-100MW"},colors.gray,colors.white)
        drawBtn(m,hw+3,row,hw,2,{"DEMAND","+100MW"},colors.gray,colors.white)
        regBtn(btnShift,"DEM_DN",2,row,hw,2)
        regBtn(btnShift,"DEM_UP",hw+3,row,hw,2)
        row=row+3
    end

    -- Current demand display
    if row<=H-2 then
        mhline(m,row,colors.gray,colors.black); row=row+1
        local gc=math.abs(generatedMW-demandMW)<100 and colors.lime or colors.orange
        mw(m,2,row,"CURRENT ORDER:",colors.lightGray,colors.black)
        mw(m,17,row,string.format("%4.0f MW",demandMW),colors.cyan,colors.black)
        row=row+1
        mw(m,2,row,"GENERATED:    ",colors.lightGray,colors.black)
        mw(m,17,row,string.format("%4.0f MW",generatedMW),gc,colors.black)
    end

    -- Repair prompt
    for _,t in ipairs(turbines) do
        if t.repairPrompt and t.repairScreen=="monShift" then
            mfill(m,1,H-2,W,2,colors.red)
            mw(m,2,H-2," !! "..t.name.." FAULT – CLICK TO REPAIR !!",
               colors.white,colors.red)
            table.insert(repairBtns,{t=t,x=1,y=H-2,w=W,h=2,screen="monShift"})
        end
    end

    mfill(m,1,H,W,1,colors.gray)
    mw(m,2,H,"Shift Manager Station",colors.white,colors.gray)

    if auth.awaitingName then drawAuthPromptOverlay(m) end
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  DRAW ALL                                            ║
-- ╚══════════════════════════════════════════════════════╝
local function drawAll()
    repairBtns={}
    drawOverview()
    drawReactorPrimary()
    drawGridControl()
    drawECCS()
    drawODCS()
    drawShiftManager()
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  ACTIONS                                             ║
-- ╚══════════════════════════════════════════════════════╝
local function repairTurbine(t)
    if not t.broken then return end
    t.broken=false; t.repairPrompt=false
    t.repairScreen=nil; t.repairTimer=0
    t.rpm=0; t.scopeAngle=0; t.flowRate=0; t.flowStep=0
    clearAlarm("EXPLO_"..t.id)
    log(t.name.." repaired – ready for restart")
end

local function doAction(id)
    local ph=rx.phase

    -- Reactor Primary actions
    if id=="ROD_W1" then
        if ph~=5 then rx.rodPos=clamp(rx.rodPos-1,0,100)
            log("Rod -1% → "..rnd(rx.rodPos,0).."%") end
    elseif id=="ROD_I1" then
        rx.rodPos=clamp(rx.rodPos+1,0,100)
        log("Rod +1% → "..rnd(rx.rodPos,0).."%")
    elseif id=="ROD_W5" then
        if ph~=5 then rx.rodPos=clamp(rx.rodPos-5,0,100)
            log("Rod -5% → "..rnd(rx.rodPos,0).."%") end
    elseif id=="ROD_I5" then
        rx.rodPos=clamp(rx.rodPos+5,0,100)
        log("Rod +5% → "..rnd(rx.rodPos,0).."%")
    elseif id=="COOLANT" then
        rx.coolantOn=not rx.coolantOn
        log("Coolant "..(rx.coolantOn and "ON" or "OFF"))
    elseif id=="FEEDWTR" then
        rx.feedwaterOn=not rx.feedwaterOn
        log("Feedwater "..(rx.feedwaterOn and "ON" or "OFF"))
    elseif id=="RV1" then fireRV(1)
    elseif id=="RV2" then fireRV(2)
    elseif id=="RV3" then fireRV(3)
    elseif id=="RV4" then fireRV(4)

    -- ECCS
    elseif id=="SCRAM" then
        doSCRAM("MANUAL OPERATOR SCRAM")

    -- ODCS
    elseif id=="PUMPS" then
        if auth.ignitionAuthorized or auth.pumpsOn then
            auth.pumpsOn=not auth.pumpsOn
            log("Shutdown pumps "..(auth.pumpsOn and "STARTED" or "STOPPED"))
            if ph==2 and not auth.pumpsOn then rx.phase=1 end
            if ph<=1 and auth.pumpsOn then rx.phase=2 end
        else
            log("Pumps blocked: ignition not authorized")
        end
    elseif id=="IGNITE" then
        if auth.ignitionAuthorized and auth.pumpsOn
           and (ph==0 or ph==1 or ph==2) then
            rx.phase=3; rx.temperature=C.T_STALL; rx.rodPos=100
            log("IGNITION – reactor rising to criticality")
        else
            log("Ignition blocked: check authorization and pumps")
        end

    -- Shift Manager
    elseif id=="AUTH" then
        if not auth.ignitionAuthorized then
            auth.awaitingName=true; auth.nameBuffer=""
        end
    elseif id=="DEM_UP" then
        demandMW=math.min(C.MW_TURB*2,demandMW+100)
        log("Demand "..rnd(demandMW,0).." MW")
        -- Deactivate all preset orders
        for _,po in ipairs(powerOrders) do po.active=false end
    elseif id=="DEM_DN" then
        demandMW=math.max(0,demandMW-100)
        log("Demand "..rnd(demandMW,0).." MW")
        for _,po in ipairs(powerOrders) do po.active=false end
    else
        -- Power order presets
        for i,po in ipairs(powerOrders) do
            if id=="ORDER"..i then
                for _,p in ipairs(powerOrders) do p.active=false end
                po.active=true
                demandMW=po.mw
                log("Power order: "..po.name.." "..po.mw.." MW")
                break
            end
        end
    end
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  INPUT HANDLING                                      ║
-- ╚══════════════════════════════════════════════════════╝
local function handleMonitorTouch(monName,mx,my)
    -- Repair prompts (any screen)
    local rt=hitRepair(monName,mx,my)
    if rt then repairTurbine(rt); return end

    if monName==PNAMES.monReact then
        local id=hitTest(btnReact,mx,my)
        if id then doAction(id) end

    elseif monName==PNAMES.monGrid then
        -- Synchroscope interactive buttons
        for _,btn in ipairs(syncBtns) do
            if mx>=btn.x and mx<btn.x+btn.w and
               my>=btn.y and my<btn.y+btn.h then
                if btn.type=="speed" then
                    btn.t.rpmSpeed=btn.val
                    log(btn.t.name.." speed: "..btn.val)
                elseif btn.type=="flow" then
                    btn.t.flowStep=btn.val
                    log(btn.t.name.." flow: "..flowLabels[btn.val])
                elseif btn.type=="sync" then
                    local angN=btn.t.scopeAngle%360
                    local nearTop=(angN<25 or angN>335)
                    local nearRPM=math.abs(btn.t.rpmDelta)<60
                    if nearTop and nearRPM and not btn.t.broken then
                        btn.t.synced=true; btn.t.breaker=true
                        log(btn.t.name.." synchronized to grid")
                    else
                        log(btn.t.name.." sync failed – wait for green dot")
                    end
                elseif btn.type=="online" then
                    if not btn.t.broken then
                        btn.t.online=not btn.t.online
                        if not btn.t.online then
                            btn.t.synced=false; btn.t.breaker=false
                        else
                            log(btn.t.name.." started")
                        end
                    end
                elseif btn.type=="breaker" then
                    local t=btn.t
                    if t.broken then
                        log(t.name.." breaker locked: turbine fault")
                    elseif not t.synced then
                        log(t.name.." breaker blocked: not synced")
                    else
                        t.breaker=not t.breaker
                        log(t.name.." breaker "..
                            (t.breaker and "CLOSED" or "OPENED"))
                        if not t.breaker then t.load=0 end
                    end
                end
                return
            end
        end
        -- Grid panel buttons
        local id=hitTest(btnGrid,mx,my)
        if id then doAction(id) end

    elseif monName==PNAMES.monECCS then
        local id=hitTest(btnECCS,mx,my)
        if id then doAction(id) end

    elseif monName==PNAMES.monODCS then
        local id=hitTest(btnODCS,mx,my)
        if id then doAction(id) end

    elseif monName==PNAMES.monShift then
        if auth.awaitingName then return end
        local id=hitTest(btnShift,mx,my)
        if id then doAction(id) end
    end
end

local function handleKey(key)
    if auth.awaitingName then
        if key==keys.escape then
            auth.awaitingName=false; auth.nameBuffer=""
        end
        return
    end
    if key==keys.x               then doSCRAM("MANUAL OPERATOR SCRAM")
    elseif key==keys.a           then ackAll()
    elseif key==keys.leftBracket then doAction("ROD_W1")
    elseif key==keys.rightBracket then doAction("ROD_I1")
    elseif key==keys.up          then doAction("ROD_W5")
    elseif key==keys.down        then doAction("ROD_I5")
    elseif key==keys.c           then doAction("COOLANT")
    elseif key==keys.f           then doAction("FEEDWTR")
    elseif key==keys.one         then
        turbines[1].online=not turbines[1].online
        if not turbines[1].online then
            turbines[1].synced=false; turbines[1].breaker=false end
    elseif key==keys.two         then
        turbines[2].online=not turbines[2].online
        if not turbines[2].online then
            turbines[2].synced=false; turbines[2].breaker=false end
    elseif key==keys.comma       then doAction("DEM_DN")
    elseif key==keys.period      then doAction("DEM_UP")
    elseif key==keys.q           then running=false
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
            if rx.phase==0 then rx.phase=1 end
            log("Ignition authorized by "..auth.nameBuffer)
        else
            log("Authorization DENIED")
            alarm("AUTH_FAIL","AUTHORIZATION DENIED")
        end
        auth.nameBuffer=""
    end
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  SETUP                                               ║
-- ╚══════════════════════════════════════════════════════╝
local function setup()
    local function tryWrap(name)
        if name and peripheral.isPresent(name) then
            return peripheral.wrap(name) end
        return nil
    end

    mons.monOver  = tryWrap(PNAMES.monOver)
    mons.monReact = tryWrap(PNAMES.monReact)
    mons.monGrid  = tryWrap(PNAMES.monGrid)
    mons.monECCS  = tryWrap(PNAMES.monECCS)
    mons.monODCS  = tryWrap(PNAMES.monODCS)
    mons.monShift = tryWrap(PNAMES.monShift)
    spk           = tryWrap(PNAMES.speaker)

    -- Auto-discover any monitors not found by name
    local found={}
    for _,name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name)=="monitor" then
            found[name]=peripheral.wrap(name)
        end
    end
    local auto={}
    for name,wrap in pairs(found) do
        local matched=false
        for _,pn in pairs(PNAMES) do if name==pn then matched=true end end
        if not matched then table.insert(auto,wrap) end
    end
    local ai=1
    local slots={"monOver","monReact","monGrid","monECCS","monODCS","monShift"}
    for _,slot in ipairs(slots) do
        if not mons[slot] and auto[ai] then
            mons[slot]=auto[ai]; ai=ai+1
        end
    end

    local function cfg(mon)
        if not mon then return end
        mon.setTextScale(0.5)
        mon.setBackgroundColor(colors.black)
        mon.setTextColor(colors.white)
        mon.clear()
    end
    for _,m in pairs(mons) do cfg(m) end

    math.randomseed(os.time())

    log("NRCS v5.0 boot – NARAMO Unit 1")
    log("Monitors: OVR="..(mons.monOver and "OK" or "--")..
        " RX="..(mons.monReact and "OK" or "--")..
        " GD="..(mons.monGrid and "OK" or "--")..
        " EC="..(mons.monECCS and "OK" or "--")..
        " OD="..(mons.monODCS and "OK" or "--")..
        " SM="..(mons.monShift and "OK" or "--"))
    log("Awaiting shift manager authorization")

    -- Fancy terminal splash screen
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1,1)

    local W,H = term.getSize()

    local function tCenter(y, txt, fg, bg)
        if bg then term.setBackgroundColor(bg) end
        term.setTextColor(fg or colors.white)
        local x = math.max(1, math.floor((W - #txt) / 2) + 1)
        term.setCursorPos(x, y)
        term.write(txt)
    end

    local function tFill(y, bg)
        term.setBackgroundColor(bg)
        term.setCursorPos(1, y)
        term.write(string.rep(" ", W))
    end

    -- Background
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Top banner
    tFill(1,  colors.blue)
    tFill(2,  colors.blue)
    tFill(3,  colors.blue)
    tCenter(2, "NARAMO  NUCLEAR  POWER  PLANT", colors.white, colors.blue)

    -- Logo block
    tFill(4,  colors.black)
    tFill(5,  colors.black)
    tFill(6,  colors.black)
    tFill(7,  colors.black)
    tFill(8,  colors.black)
    tCenter(5, "\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127",  colors.blue,   colors.black)
    tCenter(6, "  UNIT  1  CONTROL  SYSTEM  ",                                                                      colors.white,  colors.black)
    tCenter(7, "\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127\127",  colors.blue,   colors.black)

    -- Subtitle
    tFill(9,  colors.black)
    tCenter(9, "Nuclear Reactor Control System  v5.0", colors.lightGray, colors.black)

    -- Divider
    tFill(10, colors.black)
    tCenter(10, string.rep("\140", W - 4), colors.gray, colors.black)

    -- System status
    local statusY = 12
    term.setBackgroundColor(colors.black)

    local monList = {
        {"monOver",  "OVERVIEW         "},
        {"monReact", "REACTOR PRIMARY  "},
        {"monGrid",  "GRID CONTROL     "},
        {"monECCS",  "ECCS             "},
        {"monODCS",  "ODCS / STARTUP   "},
        {"monShift", "SHIFT MANAGER    "},
    }

    tCenter(statusY, "PERIPHERAL STATUS", colors.yellow, colors.black)
    statusY = statusY + 1

    for _,entry in ipairs(monList) do
        local key, label = entry[1], entry[2]
        local ok = mons[key] ~= nil
        local dot = ok and "\7" or "\7"
        local dotC = ok and colors.lime or colors.red
        local statTxt = ok and "ONLINE " or "OFFLINE"
        local statC   = ok and colors.lime or colors.red

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        local lx = math.floor((W - 28) / 2) + 1
        term.setCursorPos(lx, statusY)
        term.write("  ")
        term.setTextColor(dotC)
        term.write(dot.." ")
        term.setTextColor(colors.lightGray)
        term.write(label)
        term.setTextColor(statC)
        term.write("["..statTxt.."]")
        statusY = statusY + 1
    end

    -- Bottom bar
    local botY = H - 1
    tFill(botY,   colors.blue)
    tFill(botY+1, colors.blue)
    tCenter(botY,   "SYSTEM NOMINAL  –  AWAITING AUTHORIZATION", colors.white, colors.blue)
    tCenter(botY+1, "All operations performed via monitor panels", colors.lightGray, colors.blue)
end

-- ╔══════════════════════════════════════════════════════╗
-- ║  MAIN LOOP                                           ║
-- ╚══════════════════════════════════════════════════════╝
local function main()
    setup()
    local tick=os.startTimer(TICK)

    while running do
        local ev,p1,p2,p3=os.pullEvent()

        if ev=="timer" and p1==tick then
            updatePhysics()
            drawAll()
            tick=os.startTimer(TICK)

        elseif ev=="monitor_touch" then
            handleMonitorTouch(p1,p2,p3)

        elseif ev=="key" then
            handleKey(p1)
            if p1==keys.enter then handleEnter() end

        elseif ev=="char" then
            handleChar(p1)
        end
    end

    -- Cleanup
    redstone.setOutput(RS.reactor,  false)
    redstone.setOutput(RS.turbine1, false)
    redstone.setOutput(RS.turbine2, false)
    for _,m in pairs(mons) do if m then m.clear() end end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    local W2 = select(1, term.getSize())
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(1,1)
    term.write(string.rep(" ", W2))
    term.setTextColor(colors.white)
    local shut = "NARAMO UNIT 1  –  SYSTEM SHUTDOWN"
    term.setCursorPos(math.floor((W2-#shut)/2)+1, 1)
    term.write(shut)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(1,3)
    term.write("  All systems offline.")
    term.setCursorPos(1,4)
    term.write("  Reactor control system terminated.")
end

main()
