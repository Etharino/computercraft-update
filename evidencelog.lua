--[[
=====================================================================
  EVIDENCE LOG  v2   -   Smart Glasses (Advanced Peripherals 0.8)
=====================================================================

  WHAT IT DOES
    * Watches YOUR inventory, armor and hand. When items vanish, it
      writes a line to /evidence/evidence.log with the time, your
      position, what was lost and who was nearby.
    * Finds Inventory Manager blocks around you, marks them in 3D
      (through walls) and logs where they are.
    * Shows a HUD panel with everything at a glance.
    * Press the glasses hotkey (or M) to drop a MARK in the log,
      so you can line it up with a screen recording.

  WHAT TO PUT IN THE GLASSES
    Required:  Overlay Module
    Required:  Inventory Manager upgrade, with a Memory Card
               bound to YOU (right-click the card, then insert it)
    Recommended: Geo Scanner        -> finds managers near you
    Recommended: Player Detector    -> logs who was nearby
    Optional:  Hotkey Module        -> mark key while playing
    Optional:  Environment Detector -> dimension name

    Wear the glasses in the HELMET slot. In a Curios slot, AP
    wipes the overlay after every scan (AP bug #841).

  INVENTORY FROM YOUR BASE (secure relay, optional)
    The Inventory Manager loses its owner when broken, so it can't
    go in the glasses. Instead leave it placed in your base and run
    relay_base.lua next to it. It sends your inventory to the
    glasses encrypted + signed (see securelink.lua), so others on
    the channel can't read it or feed you fake data.
      base:     relay_base setup   (prints a key)
      glasses:  evidencelog pair <key>
    Glasses then need an ender/wireless modem + securelink.lua.

  COMMANDS
    evidencelog             start
    evidencelog probe       check what your glasses can see first
    evidencelog pair <key>  link to your relay_base computer

  KEYS (glasses terminal)
    M = mark   S = summary   H = hide/show HUD   Q = quit
=====================================================================
]]

local args = { ... }

---------------------------------------------------------------------
-- 1. SETTINGS
---------------------------------------------------------------------
local SETTINGS = {
  -- Log file
  LOG_FOLDER        = "/evidence",
  LOG_NAME          = "evidence.log",
  LOG_MAX_BYTES     = 400000,          -- older lines move to evidence.old

  -- How often things run (seconds)
  CHECK_INVENTORY   = 1,
  CHECK_PLAYERS     = 2,
  CHECK_MANAGERS    = 4,

  -- When is a loss worth logging?
  LOG_IF_LOST_AT_LEAST   = 16,         -- items in one check
  SUSPECT_IF_LOST        = 64,         -- items in one check
  SUSPECT_IF_TYPES       = 4,          -- different items at once
  SUSPECT_IF_HALF_GONE   = true,       -- lost half of everything at once

  -- Ranges
  PLAYER_RANGE      = 32,
  PLAYER_MEMORY     = 15,              -- seconds a nearby player stays "recent"
  MANAGER_RADIUS    = 16,
  WATCH_BLOCKS      = { "inventory_manager" },

  -- Look
  HUD_X = 6, HUD_Y = 6, HUD_WIDTH = 230,
  ALERT_SECONDS     = 15,
  MARKER_LABELS     = true,            -- floating "INVENTORY MANAGER" text

  -- Marker alignment (same as blockvision): if boxes sit one block off,
  -- change OFFSET; half a block off, flip ANCHOR.
  ANCHOR      = "corner",
  OFFSET      = { x = 0, y = 0, z = 0 },
  SCAN_ORIGIN = "feet",
}

-- Colours (0xRRGGBB)
local COLOR = {
  panel   = 0x0B0F14, header = 0x1E3A5F, accent = 0x4FC3F7,
  label   = 0x9AA5B1, text   = 0xE6EDF3,
  good    = 0x5CE65C, warn   = 0xFFC145, bad = 0xFF4D4D,
  marker  = 0xFF3355, markerCore = 0xFFFFFF,
}

---------------------------------------------------------------------
-- 2. SMALL HELPERS
---------------------------------------------------------------------
-- Call a function safely; returns nil instead of crashing.
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
end

local function nowMs() return os.epoch("utc") end
local function timestamp()
  return os.date("!%Y-%m-%d %H:%M:%S", math.floor(nowMs() / 1000)) .. "Z"
end

local function find(...)
  for _, name in ipairs({ ... }) do
    local p = peripheral.find(name)
    if p then return p end
  end
end

local function shorten(s, n)
  s = tostring(s)
  if #s <= n then return s end
  return s:sub(1, n - 2) .. ".."
end

local function plainName(id) -- "minecraft:diamond" -> "diamond"
  return (tostring(id):gsub("^[^:]+:", ""))
end

---------------------------------------------------------------------
-- 3. HARDWARE
---------------------------------------------------------------------
local function findOverlay()
  if smartglasses and smartglasses.modules and smartglasses.modules.overlay then
    return smartglasses.modules.overlay
  end
  local g = peripheral.find("smart_glasses")
  if g and g.getModule then return try(g.getModule, "advancedperipherals:overlay") end
end

local HW = {
  overlay   = findOverlay(),
  manager   = find("inventory_manager", "inventoryManager"),
  detector  = find("player_detector", "playerDetector"),
  env       = find("environment_detector", "environmentDetector"),
  scanner   = find("geo_scanner", "geoScanner"),
}

-- Secure relay from relay_base.lua (optional).
local RELAY = { ok = false, latest = nil, rejected = 0, lastRejectLog = 0, state = {} }
do
  local hasLib, link = pcall(require, "securelink")
  if hasLib then
    RELAY.link = link
    if args[1] == "pair" then
      local key = args[2] and args[2]:gsub("%s", "")
      if not key or not link.keys(key) then
        print("Usage: evidencelog pair <32-character key from relay_base setup>")
      else
        link.saveSecret(key)
        print("Paired. Channel " .. link.keys(key).channel .. ". Now run: evidencelog")
      end
      return
    end
    local secret = link.loadSecret()
    HW.modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
    if secret and HW.modem then
      RELAY.keys = link.keys(secret)
      if RELAY.keys then
        HW.modem.open(RELAY.keys.channel)
        RELAY.ok = true
      end
    end
  elseif args[1] == "pair" then
    print("securelink.lua is missing on the glasses. Download it first.")
    return
  end
end

local RELAY_FRESH_MS = 5000
local function relayFresh()
  return RELAY.latest and (os.epoch("utc") - RELAY.latest.at) < RELAY_FRESH_MS
end

-- The wearer (you), as the glasses report it.
local function wearer()
  if smartglasses and smartglasses.getOwner then
    local o = try(smartglasses.getOwner)
    if type(o) == "table" then return o end
  end
end

local function myName()
  local w = wearer()
  return w and w.name
end

-- Who the Inventory Manager's memory card belongs to.
local function managerOwner()
  if not HW.manager then return nil end
  local a, b = try(HW.manager.getOwner)
  if type(b) == "string" then return b end   -- (uuid, name)
  if type(a) == "string" then return a end   -- name
end

local function myPosition()
  local ex, ey, ez
  if HW.overlay then ex, ey, ez = try(HW.overlay.getEyePosition) end
  local w = wearer()
  if w then
    local p = (type(w.pos) == "table" and w.pos) or w
    if type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
      return p.x, p.y, p.z, ex or p.x, ey or (p.y + 1.62), ez or p.z
    end
  end
  if ex then return ex, ey - 1.62, ez, ex, ey, ez end
end

local function myDimension()
  if HW.env then
    local d = try(HW.env.getDimension)
    if type(d) == "string" then return d end
  end
  local w = wearer()
  return (w and w.dimension) or "?"
end

local function whereText()
  local x, y, z = myPosition()
  if not x then return "pos ?" end
  return ("%d %d %d %s"):format(math.floor(x), math.floor(y), math.floor(z), plainName(myDimension()))
end

---------------------------------------------------------------------
-- 4. LOG FILE
---------------------------------------------------------------------
local LOG_PATH = fs.combine(SETTINGS.LOG_FOLDER, SETTINGS.LOG_NAME)
if not fs.exists(SETTINGS.LOG_FOLDER) then fs.makeDir(SETTINGS.LOG_FOLDER) end

local stats = { losses = 0, suspect = 0, managers = 0, marks = 0 }
local lastEvent = "started"

local function writeLog(kind, message)
  if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > SETTINGS.LOG_MAX_BYTES then
    local old = fs.combine(SETTINGS.LOG_FOLDER, "evidence.old")
    if fs.exists(old) then fs.delete(old) end
    fs.move(LOG_PATH, old)
  end
  local line = ("%s  %-8s  @ %s  |  %s"):format(timestamp(), kind, whereText(), message)
  local f = fs.open(LOG_PATH, "a")
  if f then f.writeLine(line); f.close() end
  print(line)
end

---------------------------------------------------------------------
-- 5. HUD  (panel, alert banner, 3D markers)
---------------------------------------------------------------------
local HUD = { shown = true, parts = {}, markers = {}, alertUntil = 0 }
local ROWS = {
  { key = "card",     label = "Card"     },
  { key = "inv",      label = "Inventory"},
  { key = "losses",   label = "Losses"   },
  { key = "managers", label = "Managers" },
  { key = "nearby",   label = "Nearby"   },
  { key = "last",     label = "Last"     },
}
local ROW_H, HEADER_H, PAD = 11, 15, 6
local rowValues = {}

local function removeObject(o)
  if o and HW.overlay then
    local id = try(o.getId) or o.id
    if id then pcall(HW.overlay.removeObject, id) end
  end
end

local function rect(x, y, w, h, color, opacity)
  return try(HW.overlay.createRectangle, {
    gui = true, x = x, y = y, sizeX = w, sizeY = h, color = color, opacity = opacity,
  })
end

local function text(x, y, content, color)
  return try(HW.overlay.createText, {
    gui = true, x = x, y = y, content = content, color = color, shadow = true,
  })
end

local function setText(obj, content)
  return obj and type(obj.setContent) == "function" and pcall(obj.setContent, content)
end

local function setColor(obj, color)
  if obj and type(obj.setColor) == "function" then pcall(obj.setColor, color) end
end

function HUD.build()
  if not HW.overlay then return end
  local P = HUD.parts
  local x, y, w = SETTINGS.HUD_X, SETTINGS.HUD_Y, SETTINGS.HUD_WIDTH
  local h = HEADER_H + #ROWS * ROW_H + PAD
  -- order matters: backgrounds first, text on top
  P.bg       = rect(x, y, w, h, COLOR.panel, 0.72)
  P.header   = rect(x, y, w, HEADER_H, COLOR.header, 0.9)
  P.stripe   = rect(x, y + HEADER_H, w, 1, COLOR.accent, 1)
  P.title    = text(x + PAD, y + 4, "EVIDENCE LOG", COLOR.accent)
  P.dot      = text(x + w - 40, y + 4, "* REC", COLOR.bad)
  for i, row in ipairs(ROWS) do
    local ry = y + HEADER_H + 4 + (i - 1) * ROW_H
    P["l_" .. row.key] = text(x + PAD, ry, row.label, COLOR.label)
    P["v_" .. row.key] = text(x + 70, ry, rowValues[row.key] and rowValues[row.key][1] or "-",
                             rowValues[row.key] and rowValues[row.key][2] or COLOR.text)
  end
end

-- Update one row's value (and its colour).
function HUD.row(key, value, color)
  value = shorten(value, 26)
  rowValues[key] = { value, color or COLOR.text }
  local obj = HUD.parts["v_" .. key]
  if obj then
    setText(obj, value)
    setColor(obj, color or COLOR.text)
  end
end

-- Red banner under the panel for important events.
function HUD.alert(message, color)
  HUD.alertUntil = nowMs() + SETTINGS.ALERT_SECONDS * 1000
  if not HW.overlay or not HUD.shown then return end
  removeObject(HUD.parts.alertBg); removeObject(HUD.parts.alertText)
  local x = SETTINGS.HUD_X
  local y = SETTINGS.HUD_Y + HEADER_H + #ROWS * ROW_H + PAD + 4
  HUD.parts.alertBg   = rect(x, y, SETTINGS.HUD_WIDTH, 14, color or COLOR.bad, 0.85)
  HUD.parts.alertText = text(x + PAD, y + 3, shorten(message, 38), 0xFFFFFF)
end

function HUD.tick()
  if HUD.parts.alertBg and nowMs() > HUD.alertUntil then
    removeObject(HUD.parts.alertBg); removeObject(HUD.parts.alertText)
    HUD.parts.alertBg, HUD.parts.alertText = nil, nil
  end
  -- blink the REC dot
  if HUD.parts.dot then
    setText(HUD.parts.dot, (math.floor(nowMs() / 700) % 2 == 0) and "* REC" or "  REC")
  end
end

-- 3D marker: soft outer glow + solid core + floating label, through walls.
local function markerBoxes(x, y, z, distance)
  local list = {}
  local function box(size, color, opacity)
    local o = (1 - size) / 2
    local bx, by, bz
    if SETTINGS.ANCHOR == "center" then bx, by, bz = x + 0.5, y + 0.5, z + 0.5
    else bx, by, bz = x + o, y + o, z + o end
    return try(HW.overlay.createBox, {
      x = bx + SETTINGS.OFFSET.x, y = by + SETTINGS.OFFSET.y, z = bz + SETTINGS.OFFSET.z,
      sizeX = size, sizeY = size, sizeZ = size,
      color = color, opacity = opacity, depthTest = false, depthMask = false,
    })
  end
  list[#list + 1] = box(1.08, COLOR.marker, 0.28)      -- glow
  list[#list + 1] = box(0.45, COLOR.markerCore, 0.85)  -- core
  if SETTINGS.MARKER_LABELS then
    list[#list + 1] = try(HW.overlay.createText, {
      x = x + 0.5 + SETTINGS.OFFSET.x, y = y + 1.6 + SETTINGS.OFFSET.y, z = z + 0.5 + SETTINGS.OFFSET.z,
      content = ("INVENTORY MANAGER  %dm"):format(math.floor(distance + 0.5)),
      color = COLOR.marker, shadow = true, center = true,
    })
  end
  return list
end

function HUD.setMarkers(found)   -- found: key -> {x,y,z,dist}
  if not HW.overlay then return end
  try(HW.overlay.setAutoUpdate, false)
  for key, objs in pairs(HUD.markers) do
    if not found[key] then
      for _, o in ipairs(objs) do removeObject(o) end
      HUD.markers[key] = nil
    end
  end
  if HUD.shown then
    for key, m in pairs(found) do
      if not HUD.markers[key] then HUD.markers[key] = markerBoxes(m.x, m.y, m.z, m.dist) end
    end
  end
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
end

function HUD.objectCount()
  local n = 0
  for _, o in pairs(HUD.parts) do if o then n = n + 1 end end
  for _, objs in pairs(HUD.markers) do n = n + #objs end
  return n
end

function HUD.rebuild()
  if not HW.overlay then return end
  try(HW.overlay.clear)
  HUD.parts, HUD.markers = {}, {}
  if HUD.shown then HUD.build() end
end

-- Rebuild if the overlay was wiped (Curios bug, relog, death).
function HUD.checkIntact()
  if not HW.overlay then return end
  local n = try(HW.overlay.getObjectsCount)
  if type(n) == "number" and n < HUD.objectCount() then HUD.rebuild() end
end

---------------------------------------------------------------------
-- 6. READING YOUR INVENTORY
---------------------------------------------------------------------
local invSource = "none"

-- Returns a list of {name, count} for everything on you, or nil.
local function readInventory()
  local all = {}
  local function add(list)
    if type(list) ~= "table" then return false end
    for _, it in pairs(list) do
      if type(it) == "table" and it.name then all[#all + 1] = it end
    end
    return true
  end

  -- 1st choice: secure relay from your base Inventory Manager
  if relayFresh() and RELAY.latest.online then
    for id, count in pairs(RELAY.latest.items) do all[#all + 1] = { name = id, count = count } end
    invSource = "relay"
    return all
  end

  -- 2nd choice: an Inventory Manager in the glasses (main inventory + armor)
  if HW.manager and add(try(HW.manager.getItems)) then
    add(try(HW.manager.getArmor))
    invSource = "manager"
    return all
  end
  -- 2nd: Player Detector detailed data
  local me = myName()
  if HW.detector and me then
    local p = try(HW.detector.getPlayer, me, true)
    if type(p) == "table" and add(p.inventory) then invSource = "detector"; return all end
  end
  -- 3rd: glasses wearer data
  local w = wearer()
  if w and add(w.inventory) then invSource = "glasses"; return all end

  invSource = "none"
end

local function countItems(list)
  local per, total = {}, 0
  for _, it in ipairs(list) do
    local c = tonumber(it.count or it.amount) or 0
    if c > 0 then per[it.name] = (per[it.name] or 0) + c; total = total + c end
  end
  return per, total
end

---------------------------------------------------------------------
-- 7. NEARBY PLAYERS
---------------------------------------------------------------------
local recentPlayers = {}   -- name -> last seen (ms)

local function checkPlayers()
  local me, names = myName(), {}
  if HW.detector then
    for _, p in pairs(try(HW.detector.getPlayersInRange, SETTINGS.PLAYER_RANGE) or {}) do
      names[#names + 1] = type(p) == "table" and p.name or p
    end
  elseif HW.env then
    for _, e in pairs(try(HW.env.scanEntities, SETTINGS.PLAYER_RANGE, false, "minecraft:player") or {}) do
      names[#names + 1] = type(e) == "table" and e.name
    end
  end
  for _, n in ipairs(names) do
    if type(n) == "string" and n ~= me then recentPlayers[n] = nowMs() end
  end
end

local function nearbyList()
  local cutoff, out = nowMs() - SETTINGS.PLAYER_MEMORY * 1000, {}
  for n, t in pairs(recentPlayers) do if t >= cutoff then out[#out + 1] = n end end
  table.sort(out)
  return out
end

---------------------------------------------------------------------
-- 8. FINDING INVENTORY MANAGERS
---------------------------------------------------------------------
local knownManagers = {}   -- "x,y,z" -> true (already logged)
local currentManagers = {} -- key -> {x,y,z,dist}

local function isWatched(id)
  for _, w in ipairs(SETTINGS.WATCH_BLOCKS) do
    if id:find(w, 1, true) then return true end
  end
end

local function checkManagers()
  local scan = HW.scanner and (HW.scanner.scanBlocks or HW.scanner.scan)
  if not scan then return end
  local fx, fy, fz, ex, ey, ez = myPosition()
  if not fx then return end
  if SETTINGS.SCAN_ORIGIN == "eye" then fx, fy, fz = ex, ey, ez end
  local bx, by, bz = math.floor(fx), math.floor(fy + 0.001), math.floor(fz)

  local ok, blocks = pcall(scan, SETTINGS.MANAGER_RADIUS)
  if not ok or type(blocks) ~= "table" then return end

  local found = {}
  for _, b in ipairs(blocks) do
    if type(b.name) == "string" and isWatched(b.name) then
      local x, y, z = bx + b.x, by + b.y, bz + b.z
      local key = x .. "," .. y .. "," .. z
      found[key] = { x = x, y = y, z = z, dist = math.sqrt(b.x ^ 2 + b.y ^ 2 + b.z ^ 2) }
      if not knownManagers[key] then
        knownManagers[key] = true
        stats.managers = stats.managers + 1
        writeLog("MANAGER", ("%s at %d %d %d (%dm away)"):format(plainName(b.name), x, y, z, math.floor(found[key].dist)))
        HUD.alert(("Manager found at %d %d %d"):format(x, y, z), COLOR.warn)
        lastEvent = "manager found"
      end
    end
  end
  currentManagers = found
  HUD.setMarkers(found)
end

local function managersNearText()
  local parts = {}
  for _, m in pairs(currentManagers) do parts[#parts + 1] = ("%d %d %d"):format(m.x, m.y, m.z) end
  return #parts > 0 and table.concat(parts, "; ") or "none"
end

---------------------------------------------------------------------
-- 9. WATCHING FOR LOSSES
---------------------------------------------------------------------
local before, beforeTotal
local warnedNoInventory = false

local function checkInventory()
  local list = readInventory()
  if not list then
    if not warnedNoInventory then
      warnedNoInventory = true
      if RELAY.ok then
        writeLog("WARN", "No fresh data from relay_base. Is it running, and are you online/in range?")
      else
        writeLog("WARN", "Can't read your inventory. Use relay_base, a Player Detector, or a bound Inventory Manager.")
      end
    end
    return
  end
  warnedNoInventory = false
  local now, total = countItems(list)
  if not before then before, beforeTotal = now, total; return end

  local lostItems, lostTypes, lines = 0, 0, {}
  for name, had in pairs(before) do
    local has = now[name] or 0
    if has < had then
      lostItems, lostTypes = lostItems + (had - has), lostTypes + 1
      lines[#lines + 1] = ("%dx %s"):format(had - has, plainName(name))
    end
  end
  table.sort(lines)

  if lostItems >= SETTINGS.LOG_IF_LOST_AT_LEAST then
    local suspect = lostItems >= SETTINGS.SUSPECT_IF_LOST
      or lostTypes >= SETTINGS.SUSPECT_IF_TYPES
      or (SETTINGS.SUSPECT_IF_HALF_GONE and beforeTotal >= 32 and lostItems * 2 >= beforeTotal)
    local kind = suspect and "SUSPECT" or "LOSS"
    if suspect then stats.suspect = stats.suspect + 1 else stats.losses = stats.losses + 1 end

    local what = table.concat(lines, ", ", 1, math.min(#lines, 12))
    if #lines > 12 then what = what .. (", +%d more"):format(#lines - 12) end
    local near = nearbyList()
    writeLog(kind, ("lost %d items (%d kinds): %s  |  had %d, now %d  |  players near: %s  |  managers near: %s")
      :format(lostItems, lostTypes, what, beforeTotal, total,
              #near > 0 and table.concat(near, ", ") or "none", managersNearText()))
    HUD.alert(("%s  -%d items  (%s)"):format(kind, lostItems, lines[1] or "?"),
              suspect and COLOR.bad or COLOR.warn)
    lastEvent = ("%s -%d"):format(kind:lower(), lostItems)
  end
  before, beforeTotal = now, total
end

---------------------------------------------------------------------
-- 10. HUD ROWS
---------------------------------------------------------------------
local function refreshRows()
  local me, card = myName(), managerOwner()
  if RELAY.ok and relayFresh() then
    local rc = RELAY.latest.owner
    if rc and me and rc ~= me then
      HUD.row("card", "relay bound to " .. rc .. "!", COLOR.bad)
    else
      HUD.row("card", "relay " .. tostring(rc) .. "  secure", COLOR.good)
    end
  elseif RELAY.ok then
    HUD.row("card", "relay: waiting...", COLOR.warn)
  elseif not HW.manager then
    HUD.row("card", "no manager", COLOR.warn)
  elseif not card then
    HUD.row("card", "no card / not bound", COLOR.bad)
  elseif me and card ~= me then
    HUD.row("card", "bound to " .. card .. "!", COLOR.bad)
  else
    HUD.row("card", card .. "  OK", COLOR.good)
  end

  HUD.row("inv", invSource == "none" and "can't read" or ("via " .. invSource .. "  " .. (beforeTotal or 0) .. " items"),
          invSource == "none" and COLOR.bad or COLOR.good)
  HUD.row("losses", ("%d   suspect %d"):format(stats.losses, stats.suspect),
          stats.suspect > 0 and COLOR.bad or (stats.losses > 0 and COLOR.warn or COLOR.text))

  local mc = 0
  for _ in pairs(currentManagers) do mc = mc + 1 end
  HUD.row("managers", HW.scanner and (mc .. " in range   " .. stats.managers .. " logged") or "no geo scanner",
          mc > 0 and COLOR.bad or (HW.scanner and COLOR.text or COLOR.warn))

  local near = nearbyList()
  HUD.row("nearby", #near > 0 and table.concat(near, ", ") or "nobody",
          #near > 0 and COLOR.warn or COLOR.label)
  HUD.row("last", lastEvent, COLOR.text)
end

---------------------------------------------------------------------
-- 11. PROBE MODE
---------------------------------------------------------------------
local function probe()
  local function line(label, ok, extra)
    term.setTextColour(ok and colours.lime or colours.red)
    write(ok and "[ OK ] " or "[ -- ] ")
    term.setTextColour(colours.white)
    print(label .. (extra and ("  " .. extra) or ""))
  end
  print("EVIDENCE LOG - hardware check")
  print("")
  line("Running on Smart Glasses", smartglasses ~= nil)
  line("Overlay Module", HW.overlay ~= nil, "(HUD)")
  line("Inventory Manager", HW.manager ~= nil, "(reads your inventory)")
  if HW.manager then
    local card, me = managerOwner(), myName()
    line("Memory card bound", card ~= nil, card and ("to " .. card))
    if card and me then line("Card is yours", card == me, me) end
    local items = try(HW.manager.getItems)
    line("Can read items", type(items) == "table", items and (#items .. " stacks"))
  end
  line("securelink.lua present", RELAY.link ~= nil, "(only for relay)")
  line("Ender/wireless modem", HW.modem ~= nil, "(only for relay)")
  line("Paired with relay", RELAY.ok, RELAY.keys and ("channel " .. RELAY.keys.channel))
  if RELAY.ok then
    print("  Listening 3s for your relay...")
    local t = os.startTimer(3)
    while true do
      local e, a, ch, _, msg = os.pullEvent()
      if e == "timer" and a == t then line("Relay heard", false, "(is relay_base running?)") break end
      if e == "modem_message" and ch == RELAY.keys.channel then
        local plain, why = RELAY.link.open(RELAY.keys, RELAY.state, msg)
        if plain then
          local d = RELAY.link.decodeInventory(plain)
          line("Relay heard + verified", true, "owner " .. tostring(d.owner) .. ", " .. d.total .. " items")
          break
        else
          line("Relay packet rejected", false, why)
        end
      end
    end
  end
  line("Geo Scanner", HW.scanner ~= nil, "(finds managers)")
  line("Player Detector", HW.detector ~= nil, "(who was nearby)")
  line("Environment Detector", HW.env ~= nil, "(optional)")
  line("Position known", myPosition() ~= nil)
  print("")
  print("Peripherals: " .. table.concat(peripheral.getNames(), ", "))
end

if args[1] == "probe" then probe() return end

---------------------------------------------------------------------
-- 12. MAIN LOOP
---------------------------------------------------------------------
local function mark(source)
  stats.marks = stats.marks + 1
  local near = nearbyList()
  writeLog("MARK", ("#%d (%s)  players near: %s"):format(stats.marks, source,
           #near > 0 and table.concat(near, ", ") or "none"))
  HUD.alert("MARK #" .. stats.marks .. " saved", COLOR.accent)
  lastEvent = "mark #" .. stats.marks
end

local function summary()
  print(("Losses %d | Suspect %d | Managers %d | Marks %d"):format(
    stats.losses, stats.suspect, stats.managers, stats.marks))
  print("Log: " .. LOG_PATH)
end

local function run()
  HUD.rebuild()
  local nextInv, nextPlayers, nextManagers = 0, 0, 0
  local timer = os.startTimer(0.25)
  while true do
    local ev = { os.pullEvent() }
    local event, a, b = ev[1], ev[2], ev[3]
    if event == "timer" and a == timer then
      local t = os.clock()
      if t >= nextPlayers  then nextPlayers  = t + SETTINGS.CHECK_PLAYERS;   checkPlayers()  end
      if t >= nextInv      then nextInv      = t + SETTINGS.CHECK_INVENTORY; checkInventory() end
      if t >= nextManagers then nextManagers = t + SETTINGS.CHECK_MANAGERS;  checkManagers() end
      HUD.checkIntact()
      refreshRows()
      HUD.tick()
      timer = os.startTimer(0.25)
    elseif event == "modem_message" and RELAY.ok and b == RELAY.keys.channel then
      local plain, why = RELAY.link.open(RELAY.keys, RELAY.state, ev[5])
      if plain then
        local d = RELAY.link.decodeInventory(plain)
        d.at = nowMs()
        RELAY.latest = d
      elseif why ~= "not ours" then
        -- Someone sent a forged or replayed packet on your channel: that's evidence too.
        RELAY.rejected = RELAY.rejected + 1
        if nowMs() - RELAY.lastRejectLog > 30000 then
          RELAY.lastRejectLog = nowMs()
          writeLog("TAMPER", ("rejected %s packet on relay channel (%d rejected so far)")
            :format(why, RELAY.rejected))
          HUD.alert("Fake relay packet blocked (" .. why .. ")", COLOR.bad)
          lastEvent = "tamper blocked"
        end
      end
    elseif event == "glasses_key_pressed" then
      mark("hotkey")
    elseif event == "key" then
      if a == keys.m then mark("key")
      elseif a == keys.s then summary()
      elseif a == keys.h then HUD.shown = not HUD.shown; HUD.rebuild()
      elseif a == keys.q then return end
    end
  end
end

term.clear(); term.setCursorPos(1, 1)
writeLog("START", ("you=%s card=%s manager=%s scanner=%s detector=%s")
  :format(tostring(myName()), tostring(managerOwner()), tostring(HW.manager ~= nil),
          tostring(HW.scanner ~= nil), tostring(HW.detector ~= nil)))
print("M mark  S summary  H hide HUD  Q quit")

local ok, err = pcall(run)
if HW.overlay then try(HW.overlay.clear) end
writeLog("STOP", "stopped")
if not ok and err ~= "Terminated" then printError(err) end
