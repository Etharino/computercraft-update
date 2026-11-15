--[[
=====================================================================
  EVIDENCE LOG   -   Smart Glasses (Advanced Peripherals 0.8)
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
    Inventory: wearer data, a linked manager, or the optional base relay
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

  COMMANDS (type on the glasses terminal)
    mark        save a MARK line (glasses hotkey does this too)
    summary     counts so far
    hide        hide/show everything
    q           quit
  Built-in HUD tools (no extra files needed):
    ores | highlight <blocks> | nearest <block>
    players [names] | wp add/go/del/list <name> | stop
    dark | bright | clear [blocks|players|all]
  Type 'help' for the full list.
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
  MANAGER_RADIUS    = 8,
  WATCH_BLOCKS      = { "inventory_manager" },

  -- Look
  HUD_X = 6, HUD_Y = 6, HUD_WIDTH = 158,
  ALERT_SECONDS     = 15,
  MARKER_LABELS     = true,            -- floating "INVENTORY MANAGER" text

  -- Marker alignment (same as blockvision): if boxes sit one block off,
  -- change OFFSET; half a block off, flip ANCHOR.
  ANCHOR      = "center",
  OFFSET      = { x = 0, y = 0, z = 0 },
  SCAN_ORIGIN = "eye",
}

-- Colours (0xRRGGBB)
local COLOR = {
  panel   = 0x09151C, header = 0x12303E, accent = 0x73F2E5,
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
  if not w then return end
  return w.username or w.customName or (type(w.name) == "string" and not w.name:find(":", 1, true) and w.name) or nil
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
  { key = "card",     label = "Source"   },
  { key = "inv",      label = "Inventory"},
  { key = "losses",   label = "Losses"   },
  { key = "managers", label = "Managers" },
  { key = "nearby",   label = "Nearby"   },
  { key = "supply",   label = "Supply"   },
}
local ROW_H, HEADER_H, PAD = 11, 19, 7
local rowValues = {}

local function removeObject(o)
  if o and HW.overlay then
    local id = try(o.getId) or o.id
    if id then pcall(HW.overlay.removeObject, id) end
  end
end

local function rect(x, y, w, h, color, opacity)
  return try(HW.overlay.createRectangle, {
    gui = true, x = x + w / 2, y = y + h / 2, sizeX = w, sizeY = h, color = color, opacity = opacity,
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
  P.bg       = rect(x, y + HEADER_H, w, h - HEADER_H, COLOR.panel, 0.82)
  P.header   = rect(x, y, w, HEADER_H, COLOR.header, 0.94)
  P.stripe   = rect(x, y, 2, h, COLOR.accent, 0.95)
  P.title    = text(x + PAD, y + 5, "EVIDENCE LOG", COLOR.accent)
  P.dot      = text(x + w - 33, y + 5, "REC", COLOR.bad)
  P.rule     = rect(x + PAD, y + HEADER_H, w - 2 * PAD, 1, COLOR.accent, 0.34)
  for i, row in ipairs(ROWS) do
    local ry = y + HEADER_H + 4 + (i - 1) * ROW_H
    P["l_" .. row.key] = text(x + PAD, ry, row.label, COLOR.label)
    P["v_" .. row.key] = text(x + 61, ry, rowValues[row.key] and rowValues[row.key][1] or "-",
                             rowValues[row.key] and rowValues[row.key][2] or COLOR.text)
  end
end

-- Update one row's value (and its colour).
function HUD.row(key, value, color)
  value = shorten(value, 15)
  color = color or COLOR.text
  local old = rowValues[key]
  if old and old[1] == value and old[2] == color then return end
  rowValues[key] = { value, color }
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
  HUD.parts.alertText = text(x + PAD, y + 3, shorten(message, 24), 0xFFFFFF)
end

function HUD.tick()
  if HUD.parts.alertBg and nowMs() > HUD.alertUntil then
    removeObject(HUD.parts.alertBg); removeObject(HUD.parts.alertText)
    HUD.parts.alertBg, HUD.parts.alertText = nil, nil
  end
  -- blink the REC dot
  if HUD.parts.dot then
    local blink = math.floor(nowMs() / 700) % 2 == 0
    if HUD.blink ~= blink then
      HUD.blink = blink
      setColor(HUD.parts.dot, blink and COLOR.bad or COLOR.label)
    end
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
      color = COLOR.marker, shadow = true, center = true, fontSize = 0.025, depthTest = false,
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
  -- remove only our own objects, so the HUD toolkit's stay put
  try(HW.overlay.setAutoUpdate, false)
  for _, o in pairs(HUD.parts) do removeObject(o) end
  for _, objs in pairs(HUD.markers) do for _, o in ipairs(objs) do removeObject(o) end end
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
  HUD.parts, HUD.markers, HUD.blink = {}, {}, nil
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
  if HW.manager and add(try(HW.manager.getItems or HW.manager.list)) then
    add(try(HW.manager.getArmor))
    local offhand = try(HW.manager.getItemInOffHand)
    if offhand and offhand.name then all[#all + 1] = offhand end
    invSource = "manager"
    return all
  end
  -- 2nd: Player Detector detailed data
  local me = myName()
  if HW.detector and me then
    local p = try(HW.detector.getPlayer or HW.detector.getPlayerLua, me, true)
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
  local self, me, names = wearer(), myName(), {}
  if not self and smartglasses and smartglasses.getOwner then return end
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
    if type(n) == "string" and n ~= me then
      local info = self and self.uuid and not me and HW.detector
        and try(HW.detector.getPlayer or HW.detector.getPlayerLua, n)
      if not (info and info.uuid == self.uuid) then recentPlayers[n] = nowMs() end
    end
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
local toolkit              -- hud.lua module, loaded in section 13 if present
local knownManagers = {}   -- "x,y,z" -> true (already logged)
local currentManagers = {} -- key -> {x,y,z,dist}

local function isWatched(id)
  for _, w in ipairs(SETTINGS.WATCH_BLOCKS) do
    if id:find(w, 1, true) then return true end
  end
end

-- One scan, shared: if the HUD toolkit is loaded, reuse its cached scan
-- (absolute coords) so both don't fight over the scanner's cooldown.
local function scanBlocksAbsolute()
  if toolkit and toolkit.scan then
    local blocks = toolkit.scan()
    return blocks
  end
  local scan = HW.scanner and (HW.scanner.scanBlocks or HW.scanner.scan)
  if not scan then return nil end
  local fx, fy, fz, ex, ey, ez = myPosition()
  if not fx then return nil end
  if SETTINGS.SCAN_ORIGIN == "eye" then fx, fy, fz = ex, ey, ez end
  local bx, by, bz = math.floor(fx), math.floor(fy + 0.001), math.floor(fz)
  local ok, raw = pcall(scan, SETTINGS.MANAGER_RADIUS)
  if not ok or type(raw) ~= "table" then return nil end
  local out = {}
  for _, b in ipairs(raw) do
    if type(b.name) == "string" and b.x then
      out[#out + 1] = { name = b.name, x = bx + b.x, y = by + b.y, z = bz + b.z,
                        d = b.x * b.x + b.y * b.y + b.z * b.z }
    end
  end
  return out
end

local function checkManagers()
  local blocks = scanBlocksAbsolute()
  if type(blocks) ~= "table" then return end

  local found = {}
  for _, b in ipairs(blocks) do
    if type(b.name) == "string" and isWatched(b.name) then
      local x, y, z = b.x, b.y, b.z
      local key = x .. "," .. y .. "," .. z
      found[key] = { x = x, y = y, z = z, dist = math.sqrt(b.d or 0) }
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
local before, beforeTotal, beforeSource
local supplyWatch = settings.get("evidence.supplies", {})
local supplyLow = {}
local supplyReadout = "-"

local function checkSupplies(stock)
  local lowest, fraction
  for item, threshold in pairs(supplyWatch) do
    local count = stock[item] or 0
    if count < threshold and not supplyLow[item] then
      writeLog("SUPPLY", ("%s low: %d/%d"):format(item, count, threshold))
      HUD.alert(("%s low: %d"):format(plainName(item), count), COLOR.warn)
    end
    supplyLow[item] = count < threshold
    local ratio = count / threshold
    if not fraction or ratio < fraction or (ratio == fraction and item < lowest) then
      lowest, fraction = item, ratio
    end
  end
  supplyReadout = lowest and (plainName(lowest) .. " " .. (stock[lowest] or 0)) or "-"
  return fraction and fraction < 1
end

local supplyIsLow
local warnedNoInventory = false

local function checkInventory()
  local list = readInventory()
  if not list then
    before, beforeTotal, beforeSource = nil, nil, nil
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
  supplyIsLow = checkSupplies(now)
  if not before or beforeSource ~= invSource then
    before, beforeTotal, beforeSource = now, total, invSource
    return
  end

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
  HUD.row("card", invSource == "none" and "waiting" or invSource,
    invSource == "none" and COLOR.warn or COLOR.accent)
  HUD.row("inv", beforeTotal and ("%s items"):format(beforeTotal) or "unavailable",
    beforeTotal and COLOR.text or COLOR.warn)
  HUD.row("losses", ("%d   suspect %d"):format(stats.losses, stats.suspect),
          stats.suspect > 0 and COLOR.bad or (stats.losses > 0 and COLOR.warn or COLOR.text))

  local mc = 0
  for _ in pairs(currentManagers) do mc = mc + 1 end
  HUD.row("managers", HW.scanner and (mc .. " in range   " .. stats.managers .. " logged") or "no geo scanner",
          mc > 0 and COLOR.bad or (HW.scanner and COLOR.text or COLOR.warn))

  local near = nearbyList()
  HUD.row("nearby", #near > 0 and table.concat(near, ", ") or "nobody",
          #near > 0 and COLOR.warn or COLOR.label)
  HUD.row("supply", beforeTotal and supplyReadout or "-", supplyIsLow and COLOR.warn or COLOR.text)
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
    local items = try(HW.manager.getItems or HW.manager.list)
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
      if type(b) == "number" and b >= 550 then
        HUD.shown = not HUD.shown
        HUD.rebuild()
        if toolkit then toolkit.setShown(HUD.shown) end
      else
        mark("hotkey")
      end
    end
  end
end

---------------------------------------------------------------------
-- 13a. HUD TOOLKIT (built in; formerly hud.lua)
-- Highlights, nearest-block finder, players, waypoints, dark mode,
-- info bar. Runs in its own scope and returns a small API.
---------------------------------------------------------------------
local function HUD_TOOLKIT(...)
  -- Always "embedded" here: evidencelog calls HUD_TOOLKIT("hud").
  local EMBEDDED = (... == "hud")

  ---------------------------------------------------------------------
  -- SETTINGS
  ---------------------------------------------------------------------
  local AI_URL       = nil    -- e.g. "http://192.168.1.50:8777" to enable the AI
  local SCAN_RADIUS  = 8
  local PLAYER_RANGE = 48
  local MAX_BOXES    = 300
  local SCAN_EVERY   = 3      -- seconds, only while block highlights are on
  local INFO_EVERY   = 0.5
  local WAYPOINT_FILE = "/.waypoints"

  local PALETTE = {
    ancient_debris = 0xFF5A00, diamond = 0x00FFFF, emerald = 0x00FF50,
    gold = 0xFFD700, lapis = 0x2E5BFF, redstone = 0xFF1010, iron = 0xE8B48A,
    copper = 0xFF8040, coal = 0x707070, quartz = 0xF0F0F0, obsidian = 0x9B30FF,
    uranium = 0x7CFC00, osmium = 0x8FB4FF, zinc = 0xB0E0C0, spawner = 0xFF00AA,
    chest = 0xFFAA00, barrel = 0xFFAA00,
  }
  local DEFAULT_BLOCK_COLOR = 0xFF00FF
  local ORES = { "c:ores", "forge:ores", "_ore", "ancient_debris" }

  local COLOR = {
    panel = 0x0B0F14, bar = 0x1E3A5F, accent = 0x4FC3F7, text = 0xE6EDF3,
    label = 0x9AA5B1, good = 0x5CE65C, warn = 0xFFC145, bad = 0xFF4D4D,
    player = 0xFF2244, waypoint = 0xFFE14D, nav = 0x7CF0FF,
  }

  ---------------------------------------------------------------------
  -- Helpers
  ---------------------------------------------------------------------
  local unpack = table.unpack or unpack
  local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if r[1] then return unpack(r, 2) end
  end
  local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
  local function plain(id) return (tostring(id):gsub("^[^:]+:", "")) end

  local function colorFor(name)
    for key, c in pairs(PALETTE) do
      if name:find(key, 1, true) then return c end
    end
    return DEFAULT_BLOCK_COLOR
  end

  ---------------------------------------------------------------------
  -- Hardware
  ---------------------------------------------------------------------
  local function findOverlay()
    if smartglasses and smartglasses.modules and smartglasses.modules.overlay then
      return smartglasses.modules.overlay
    end
    local g = peripheral.find("smart_glasses")
    if g and g.getModule then return try(g.getModule, "advancedperipherals:overlay") end
  end

  local overlay  = findOverlay()
  local scanner  = peripheral.find("geo_scanner") or peripheral.find("geoScanner")
  local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
  if not overlay then error("Needs the Overlay Module in the glasses.", 0) end

  local function me()
    if smartglasses and smartglasses.getOwner then
      local o = try(smartglasses.getOwner)
      if type(o) == "table" then return o end
    end
    return {}
  end

  local function myPos()
    local o = me()
    if type(o.x) == "number" then return o.x, o.y, o.z end
    local ex, ey, ez = try(overlay.getEyePosition)
    if ex then return ex, ey - 1.62, ez end
  end

  ---------------------------------------------------------------------
  -- Overlay object groups
  ---------------------------------------------------------------------
  local groups = { blocks = {}, players = {}, waypoint = {}, nearest = {} }
  local dimObj
  local hud = {}
  local hudShown = true

  local function removeObj(o)
    local id = o and (try(o.getId) or o.id)
    if id then pcall(overlay.removeObject, id) end
  end

  local function clearGroup(name)
    try(overlay.setAutoUpdate, false)
    for _, objs in pairs(groups[name]) do
      for _, o in ipairs(objs) do removeObj(o) end
    end
    groups[name] = {}
    try(overlay.update); try(overlay.setAutoUpdate, true)
  end

  local function box(x, y, z, sx, sy, sz, color, opacity)
    return try(overlay.createBox, {
      x = x, y = y, z = z, sizeX = sx, sizeY = sy, sizeZ = sz,
      color = color, opacity = opacity or 0.5, depthTest = false, depthMask = false,
    })
  end

  local function blockBox(x, y, z, color)
    return box(x + 0.5, y + 0.5, z + 0.5, 1.02, 1.02, 1.02, color, 0.5)
  end

  local function label(x, y, z, content, color)
    return try(overlay.createText, {
      x = x, y = y, z = z, content = content, color = color, shadow = true, center = true, fontSize = 0.025, depthTest = false,
    })
  end

  -- A tall light beam you can see from far away.
  local function beacon(x, y, z, color, text)
    return {
      box(x + 0.5, y + 24, z + 0.5, 0.3, 48, 0.3, color, 0.35),
      blockBox(x, y, z, color),
      label(x + 0.5, y + 1.8, z + 0.5, text, color),
    }
  end

  ---------------------------------------------------------------------
  -- HUD panel
  ---------------------------------------------------------------------
  local PANEL_X, PANEL_Y, PANEL_W = 6, 6, 158
  local panelFallbackY = PANEL_Y

  local function text(x, y, content, color)
    return try(overlay.createText, { gui = true, x = x, y = y, content = content, color = color, shadow = true })
  end
  local function rect(x, y, w, h, color, opacity)
    return try(overlay.createRectangle, { gui = true, x = x + w / 2, y = y + h / 2, sizeX = w, sizeY = h, color = color, opacity = opacity })
  end

  local function buildHud()
    for _, o in pairs(hud) do removeObj(o) end
    hud = {}
    if not hudShown then return end
    local screenW, _, scale = try(overlay.getGuiSize)
    local guiW = type(screenW) == "number" and screenW / math.max(1, scale or 1) or 0
    PANEL_X, PANEL_Y = 6, panelFallbackY
    if guiW >= SETTINGS.HUD_WIDTH + PANEL_W + 24 then PANEL_X, PANEL_Y = math.floor(guiW) - PANEL_W - 6, 6 end
    local x, y, w = PANEL_X, PANEL_Y, PANEL_W
    hud.bg     = rect(x, y + 19, w, 62, COLOR.panel, 0.82)
    hud.bg     = rect(x, y + 19, w, 75, COLOR.panel, 0.82)
    hud.bar    = rect(x, y, w, 19, 0x12303E, 0.94)
    hud.stripe = rect(x + w - 2, y, 2, 81, 0x73F2E5, 0.95)
    hud.stripe = rect(x + w - 2, y, 2, 94, 0x73F2E5, 0.95)
    hud.title  = text(x + 7, y + 5, "NAVIGATION", 0x73F2E5)
    hud.clock  = text(x + w - 46, y + 5, "", COLOR.label)
    hud.pos    = text(x + 6, y + 26, "", COLOR.text)
    hud.vitals = text(x + 6, y + 37, "", COLOR.text)
    hud.nav    = text(x + 6, y + 56, "", COLOR.nav)
    hud.hpBase = rect(x + 7, y + 48, w - 14, 3, 0x254352, 1)
    hud.hpBar  = rect(x + 7, y + 48, w - 14, 3, 0x73F2E5, 1)
    hud.guide  = text(x + 6, y + 68, "", COLOR.nav)
    hud.msg    = text(x + 6, y + 68, "", COLOR.label)
    hud.msg    = text(x + 6, y + 81, "", COLOR.label)
  end

  -- Panel is PANEL_W wide; at ~6px/char that's room for ~ (PANEL_W/6 - 2) chars.
  local textCache = setmetatable({}, {__mode = "k"})
  local LINE_CHARS = math.floor(PANEL_W / 6) - 2
  local function set(obj, content, color)
    if not obj then return end
    if type(content) == "string" then content = shorten(content, LINE_CHARS) end
    local old = textCache[obj]
    if not old or old[1] ~= content then pcall(obj.setContent, content) end
    if color and (not old or old[2] ~= color) and obj.setColor then pcall(obj.setColor, color) end
    textCache[obj] = {content, color}
  end

  local msgUntil = 0
  local function say(s, color)
    set(hud.msg, s, color or COLOR.text)
    msgUntil = os.epoch("utc") + 8000
    print(s)
  end

  ---------------------------------------------------------------------
  -- Direction maths
  ---------------------------------------------------------------------
  -- Minecraft yaw: 0 = south (+z), 90 = west, 180 = north, -90 = east.
  local function facingName(yaw)
    local dirs = { "S", "SW", "W", "NW", "N", "NE", "E", "SE" }
    local i = math.floor(((yaw % 360) + 22.5) / 45) % 8 + 1
    return dirs[i]
  end

  local function compassTo(dx, dz)
    local ns = dz < -0.5 and "N" or (dz > 0.5 and "S" or "")
    local ew = dx > 0.5 and "E" or (dx < -0.5 and "W" or "")
    return (ns .. ew ~= "") and (ns .. ew) or "here"
  end

  -- Where the target is relative to where you're looking.
  local function relativeDir(dx, dz, yaw)
    if not yaw then return compassTo(dx, dz) end
    local bearing = math.deg(atan2(-dx, dz))
    local rel = (bearing - yaw + 540) % 360 - 180   -- -180..180, + = right
    local a = math.abs(rel)
    if a < 20 then return "^ ahead" end
    if a > 160 then return "v behind" end
    local side = rel > 0 and "right" or "left"
    local arrow = rel > 0 and ">" or "<"
    return ("%s %s %d"):format(arrow, side, math.floor(a + 0.5))
  end

  ---------------------------------------------------------------------
  -- Waypoints
  ---------------------------------------------------------------------
  local waypoints = {}
  local navTarget = nil   -- { name, x, y, z }

  local function loadWaypoints()
    if fs.exists(WAYPOINT_FILE) then
      local f = fs.open(WAYPOINT_FILE, "r")
      waypoints = textutils.unserialise(f.readAll()) or {}
      f.close()
    end
  end

  local function saveWaypoints()
    local f = fs.open(WAYPOINT_FILE, "w")
    f.write(textutils.serialise(waypoints)); f.close()
  end

  local function navigate(name, x, y, z, color, dimension)
    navTarget = { name = name, x = x, y = y, z = z, color = color, dimension = dimension or myDimension() }
    clearGroup("waypoint")
    if navTarget.dimension == myDimension() then
      groups.waypoint[name] = beacon(x, y, z, color or COLOR.waypoint, name)
    end
  end

  ---------------------------------------------------------------------
  -- Block scanning
  ---------------------------------------------------------------------
  local blockTargets = nil   -- list of substrings, or nil
  local lastScan, lastScanAt = nil, 0

  local function scan()
    local fn = scanner and (scanner.scanBlocks or scanner.scan)
    if not fn then return nil, "no Geo Scanner" end
    local dimension = myDimension()
    if lastScan and lastScan.dimension == dimension and nowMs() - lastScanAt < 2400 then return lastScan end
    local fx, fy, fz = myPos()
    if not fx then return nil, "position unknown" end
    local x0, y0, z0 = try(overlay.getEyePosition)
    local ok, res = pcall(fn, SCAN_RADIUS)
    if not ok or type(res) ~= "table" then return nil, "scanner busy" end
    local ex, ey, ez = try(overlay.getEyePosition)
    if x0 and ex and math.max(math.abs(ex - x0), math.abs(ey - y0), math.abs(ez - z0)) >= 0.5 then
      return nil, "hold still to scan"
    end
    local out = { dimension = dimension }
    for _, b in ipairs(res) do
      if type(b.name) == "string" and b.x then
        out[#out + 1] = { name = b.name, tags = b.tags, x = math.floor((ex or fx) + b.x), y = math.floor((ey or fy + 1.62) + b.y),
                          z = math.floor((ez or fz) + b.z), d = b.x * b.x + b.y * b.y + b.z * b.z }
      end
    end
    lastScan, lastScanAt = out, os.epoch("utc")
    return out
  end

  local function matches(b, targets)
    for _, t in ipairs(targets) do
      if b.name:find(t, 1, true) then return true end
      if type(b.tags) == "table" then
        for k, v in pairs(b.tags) do
      if (type(v) == "string" and v:find(t, 1, true)) or (v == true and type(k) == "string" and k:find(t, 1, true)) then
            return true
          end
        end
      end
    end
    return false
  end

  local function refreshBlocks()
    if not blockTargets then return end
    local blocks, err = scan()
    if not blocks then return 0, err end
    table.sort(blocks, function(a, b) return a.d < b.d end)
    local want, n = {}, 0
    for _, b in ipairs(blocks) do
      if n >= MAX_BOXES then break end
      if matches(b, blockTargets) then
        want[b.x .. "," .. b.y .. "," .. b.z] = b
        n = n + 1
      end
    end
    try(overlay.setAutoUpdate, false)
    for k, objs in pairs(groups.blocks) do
      if not want[k] then for _, o in ipairs(objs) do removeObj(o) end; groups.blocks[k] = nil end
    end
    for k, b in pairs(want) do
      if not groups.blocks[k] then groups.blocks[k] = { blockBox(b.x, b.y, b.z, colorFor(b.name)) } end
    end
    try(overlay.update); try(overlay.setAutoUpdate, true)
    return n
  end

  local function findNearest(target)
    local blocks, err = scan()
    if not blocks then return say("Can't scan: " .. err, COLOR.bad) end
    local best
    for _, b in ipairs(blocks) do
      if matches(b, { target }) and (not best or b.d < best.d) then best = b end
    end
    if not best then return say("No " .. target .. " within " .. SCAN_RADIUS .. " blocks", COLOR.warn) end
    navigate(plain(best.name), best.x, best.y, best.z, colorFor(best.name))
    say(("Nearest %s: %d %d %d"):format(plain(best.name), best.x, best.y, best.z), COLOR.good)
  end

  ---------------------------------------------------------------------
  -- Players
  ---------------------------------------------------------------------
  local showPlayers = false   -- outline players?
  local playerFilter = nil    -- list of names, or nil for everyone
  local nearbyNames = {}

  local function refreshPlayers()
    clearGroup("players")
    nearbyNames = {}
    if not detector then return end
    local self = me()
    local ownName = self.username or self.customName
    local fx, fy, fz = myPos()
    for _, p in pairs(try(detector.getPlayersInRange, PLAYER_RANGE) or {}) do
      local name = type(p) == "table" and p.name or p
      if type(name) == "string" and name ~= ownName then
        local info = try(detector.getPlayer or detector.getPlayerLua, name)
        if type(info) == "table" and info.uuid and info.uuid == self.uuid then info = nil; name = nil end
        local dist = "?"
        if type(info) == "table" and info.x and fx then
          dist = math.floor(math.sqrt((info.x - fx) ^ 2 + (info.y - fy) ^ 2 + (info.z - fz) ^ 2) + 0.5)
        end
        if name then nearbyNames[#nearbyNames + 1] = name .. " " .. dist .. "m" end
        local wanted = showPlayers and (not playerFilter)
        if name and showPlayers and playerFilter then
          for _, n in ipairs(playerFilter) do if n:lower() == name:lower() then wanted = true end end
        end
        if wanted and type(info) == "table" and info.x then
          local x, y, z = info.x, info.y + 0.95, info.z
          groups.players[name] = {
            box(x, y, z, 0.7, 1.9, 0.7, COLOR.player, 0.35),
            label(info.x, info.y + 2.3, info.z, name .. "  " .. dist .. "m", COLOR.player),
          }
        end
      end
    end
  end

  ---------------------------------------------------------------------
  -- Dark mode
  ---------------------------------------------------------------------
  -- A big dark box that follows your head, drawn over terrain.
  local function setDark(on)
    if dimObj then removeObj(dimObj); dimObj = nil end
    if on then
      dimObj = try(overlay.createBox, {
        relativePosition = true, x = 0, y = 0, z = 0,
        sizeX = 64, sizeY = 64, sizeZ = 64, color = 0x000000, opacity = 0.8,
        culling = false, depthTest = false, depthMask = false,
      })
    end
  end

  ---------------------------------------------------------------------
  -- Rebuild everything (after hide/show, dark toggle, or overlay wipe)
  ---------------------------------------------------------------------
  local dark = false
  -- Remove only OUR objects, so other programs' overlays stay put.
  local function removeAllOwn()
    try(overlay.setAutoUpdate, false)
    if dimObj then removeObj(dimObj) end
    for _, o in pairs(hud) do removeObj(o) end
    for _, g in pairs(groups) do
      for _, objs in pairs(g) do for _, o in ipairs(objs) do removeObj(o) end end
    end
    try(overlay.update); try(overlay.setAutoUpdate, true)
  end

  local function rebuildAll()
    removeAllOwn()
    groups = { blocks = {}, players = {}, waypoint = {}, nearest = {} }
    dimObj, hud = nil, {}
    if not hudShown then return end
    if dark then setDark(true) end
    buildHud()
    if navTarget then navigate(navTarget.name, navTarget.x, navTarget.y, navTarget.z, navTarget.color, navTarget.dimension) end
    refreshBlocks()
    if showPlayers then refreshPlayers() end
  end

  local function countObjects()
    local n = (dimObj and 1 or 0)
    for _ in pairs(hud) do n = n + 1 end
    for _, g in pairs(groups) do for _, objs in pairs(g) do n = n + #objs end end
    return n
  end

  ---------------------------------------------------------------------
  -- Commands
  ---------------------------------------------------------------------
  local HELP = {
    "gps | gps fix | gps go <x> <y> <z>",
    "gps save <name> <x> <y> <z>",
    "ores | highlight <blocks> | nearest <block>",
    "players [names] | wp add/go/del/list <name> | stop",
    "dark | bright | clear [blocks|players|all] | hide | q",
  }

  local function gpsCommand(rest)
    local action = rest[1]
    if not action or (action == "fix" and #rest == 1) then
      local x, y, z, source
      if action == "fix" then
        local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
        if not modem then return say("GPS fix needs a wireless or Ender Modem", COLOR.warn) end
        if gps and gps.locate then x, y, z = gps.locate(2) end
        source = "Network GPS"
      else
        x, y, z = myPos()
        source = "Position"
      end
      if not x then
        return say(action and "No GPS fix. Check hosts in this dimension." or "Wear the glasses to read position.", COLOR.warn)
      end
      return say(("%s %d %d %d"):format(source, math.floor(x), math.floor(y), math.floor(z)), COLOR.good)
    end

    local name, start
    if action == "go" and #rest == 4 then
      name, start = "GPS target", 2
    elseif action == "save" and #rest == 5 then
      name, start = rest[2], 3
    else
      return say("Use gps go <x> <y> <z> or gps save <name> <x> <y> <z>", COLOR.warn)
    end
    local x, y, z = tonumber(rest[start]), tonumber(rest[start + 1]), tonumber(rest[start + 2])
    if not x or not y or not z or x % 1 ~= 0 or y % 1 ~= 0 or z % 1 ~= 0
        or math.max(math.abs(x), math.abs(y), math.abs(z)) > 30000000 then
      return say("Enter three whole-number block coordinates.", COLOR.warn)
    end
    local dimension = myDimension()
    if dimension == "?" then return say("Wear the glasses so I can read the dimension.", COLOR.warn) end
    if action == "save" then
      waypoints[name] = { x = x, y = y, z = z, dimension = dimension }
      saveWaypoints()
      return say(("Saved %s at %d %d %d"):format(name, x, y, z), COLOR.good)
    end
    navigate(name, x, y, z, nil, dimension)
    say(("GPS target %d %d %d"):format(x, y, z), COLOR.good)
  end

  local function askAI(input)
    if not AI_URL or not http then return false end
    say("thinking...", COLOR.warn)
    local ok, resp = pcall(http.post, AI_URL, textutils.serialiseJSON({ prompt = input }),
                           { ["Content-Type"] = "application/json" })
    if not ok or not resp then say("AI offline", COLOR.bad) return true end
    local data = textutils.unserialiseJSON(resp.readAll()); resp.close()
    for _, a in ipairs((type(data) == "table" and data.actions) or {}) do
      if a.action == "highlight_blocks" and type(a.targets) == "table" then
        blockTargets = {}
        for _, t in ipairs(a.targets) do blockTargets[#blockTargets + 1] = plain(t) end
        say(("highlighting %d"):format(refreshBlocks() or 0), COLOR.good)
      elseif a.action == "highlight_players" then
        showPlayers, playerFilter = true, (type(a.names) == "table" and #a.names > 0) and a.names or nil
        refreshPlayers()
      elseif a.action == "clear" then
        blockTargets, showPlayers = nil, false
        clearGroup("blocks"); clearGroup("players")
      elseif a.action == "dark_mode" then
        dark = a.on ~= false; rebuildAll()
      elseif a.action == "say" then
        say(tostring(a.text or ""), COLOR.accent)
      end
    end
    return true
  end

  local function handle(input)
    local words = {}
    for w in input:gmatch("%S+") do words[#words + 1] = w end
    local cmd = (words[1] or ""):lower()
    local rest = {}
    for i = 2, #words do rest[#rest + 1] = words[i]:lower() end

    if cmd == "" then return
    elseif cmd == "help" then for _, l in ipairs(HELP) do print(l) end; say(HELP[1], COLOR.label)
    elseif cmd == "ores" then
      blockTargets = ORES
      say(("ores: %d found"):format(refreshBlocks() or 0), COLOR.good)
    elseif cmd == "highlight" or cmd == "show" then
      if #rest == 0 then return say("highlight what?", COLOR.warn) end
      if rest[1] == "players" then showPlayers, playerFilter = true, nil; refreshPlayers(); return say("players on", COLOR.good) end
      blockTargets = rest
      say(("%s: %d found"):format(table.concat(rest, ", "), refreshBlocks() or 0), COLOR.good)
    elseif cmd == "nearest" or cmd == "find" then
      if not rest[1] then return say("nearest what?", COLOR.warn) end
      findNearest(rest[1])
    elseif cmd == "players" then
      showPlayers = true
      playerFilter = #rest > 0 and rest or nil
      refreshPlayers()
      say("players on" .. (playerFilter and (": " .. table.concat(rest, ", ")) or ""), COLOR.good)
    elseif cmd == "gps" then
      gpsCommand(rest)
    elseif cmd == "wp" or cmd == "waypoint" then
      local sub, name = rest[1], rest[2]
      if sub == "add" and name then
        local x, y, z = myPos()
        if not x then return say("position unknown", COLOR.bad) end
        waypoints[name] = { x = math.floor(x), y = math.floor(y), z = math.floor(z), dimension = myDimension() }
        saveWaypoints()
        say(("saved %s at %d %d %d"):format(name, waypoints[name].x, waypoints[name].y, waypoints[name].z), COLOR.good)
      elseif sub == "go" and name then
        local w = waypoints[name]
        if not w then return say("no waypoint " .. name, COLOR.warn) end
        navigate(name, w.x, w.y, w.z, nil, w.dimension)
        say("navigating to " .. name, COLOR.good)
      elseif sub == "del" and name then
        waypoints[name] = nil; saveWaypoints()
        if navTarget and navTarget.name == name then navTarget = nil; clearGroup("waypoint") end
        say("deleted " .. name, COLOR.text)
      else
        local names = {}
        for n in pairs(waypoints) do names[#names + 1] = n end
        table.sort(names)
        say(#names > 0 and ("waypoints: " .. table.concat(names, ", ")) or "no waypoints yet", COLOR.text)
      end
    elseif cmd == "stop" then
      navTarget = nil; clearGroup("waypoint"); say("navigation off", COLOR.text)
    elseif cmd == "dark" then dark = true; rebuildAll(); say("dark on", COLOR.good)
    elseif cmd == "bright" then dark = false; rebuildAll(); say("dark off", COLOR.text)
    elseif cmd == "clear" then
      local what = rest[1] or "all"
      if what == "blocks" or what == "all" then blockTargets = nil; clearGroup("blocks") end
      if what == "players" or what == "all" then showPlayers = false; clearGroup("players") end
      if what == "all" then navTarget = nil; clearGroup("waypoint") end
      say("cleared " .. what, COLOR.text)
    elseif cmd == "hide" then hudShown = not hudShown; rebuildAll()
    else
      return askAI(input)   -- false = not handled
    end
    return true
  end

  ---------------------------------------------------------------------
  -- Loops
  ---------------------------------------------------------------------
  local function infoLoop()
    while true do
      if hudShown then
        if countObjects() > (try(overlay.getObjectsCount) or 1e9) then rebuildAll() end
        local o = me()
        local x, y, z = myPos()
        if x then
          set(hud.pos, ("%d %d %d   facing %s"):format(math.floor(x), math.floor(y), math.floor(z),
              o.yaw and facingName(o.yaw) or "?"))
        end
        local hp = (o.health and o.maxHealth) and ("HP %d/%d"):format(math.floor(o.health), math.floor(o.maxHealth)) or "HP ?"
        local act = {}
        if blockTargets then act[#act + 1] = "blocks" end
        if showPlayers then act[#act + 1] = "players" end
        if dark then act[#act + 1] = "dark" end
        local ratio = o.health and o.maxHealth and o.maxHealth > 0 and math.max(0, math.min(1, o.health / o.maxHealth)) or 0
        local tint = ratio <= 0.30 and COLOR.bad or (ratio <= 0.55 and COLOR.warn or 0x73F2E5)
        set(hud.vitals, hp .. (#act > 0 and (" / " .. table.concat(act, "+")) or ""), tint)
        local width = (PANEL_W - 14) * ratio
        if hud.hpBar then
          try(hud.hpBar.setSizeX, width)
          try(hud.hpBar.setPos, PANEL_X + 7 + width / 2, PANEL_Y + 49.5, 0)
          try(hud.hpBar.setColor, tint)
        end
        set(hud.clock, textutils.formatTime(os.time(), true))
        local dimension = myDimension()
        if navTarget and navTarget.dimension ~= dimension then
          if next(groups.waypoint) then clearGroup("waypoint") end
          set(hud.nav, navTarget.name .. " / " .. plain(navTarget.dimension), COLOR.warn)
          set(hud.nav, navTarget.name, COLOR.warn)
          set(hud.guide, "Go to " .. plain(navTarget.dimension), COLOR.warn)
        elseif navTarget and x then
          if not groups.waypoint[navTarget.name] then
            groups.waypoint[navTarget.name] = beacon(navTarget.x, navTarget.y, navTarget.z,
              navTarget.color or COLOR.waypoint, navTarget.name)
          end
          local dx, dz = navTarget.x + 0.5 - x, navTarget.z + 0.5 - z
          local dist = math.floor(math.sqrt(dx * dx + dz * dz + (navTarget.y - y) ^ 2) + 0.5)
          local dy = navTarget.y - math.floor(y)
          local height = dy > 1 and (" up " .. dy) or (dy < -1 and (" down " .. -dy) or "")
          set(hud.nav, ("%s %dm  %s%s"):format(navTarget.name, dist, relativeDir(dx, dz, o.yaw), height))
          local height = dy > 0 and (" / up " .. dy) or (dy < 0 and (" / down " .. -dy) or "")
          set(hud.nav, ("%s  %dm"):format(shorten(navTarget.name, 15), dist), COLOR.waypoint)
          set(hud.guide, dist <= 1 and "Arrived" or (relativeDir(dx, dz, o.yaw) .. height), COLOR.nav)
        else
          set(hud.nav, #nearbyNames > 0 and ("near: " .. table.concat(nearbyNames, ", ")) or "")
          set(hud.guide, "")
        end
        if os.epoch("utc") > msgUntil then set(hud.msg, "") end
      end
      sleep(INFO_EVERY)
    end
  end

  local function scanLoop()
    while true do
      sleep(SCAN_EVERY)
      if hudShown and blockTargets then refreshBlocks() end
      if hudShown and (showPlayers or detector) then refreshPlayers() end
    end
  end

  local function hotkeyLoop()
    while true do
      os.pullEvent("glasses_key_pressed")
      hudShown = not hudShown
      rebuildAll()
    end
  end

  local function inputLoop()
    while true do
      term.setTextColour(colours.lightBlue); write("> "); term.setTextColour(colours.white)
      local line = read()
      if not line or line:lower() == "q" then return end
      local ok, handled = pcall(handle, line)
      if not ok then printError(handled)
      elseif not handled then say("unknown: " .. line .. "  (type help)", COLOR.warn) end
    end
  end

  ---------------------------------------------------------------------
  -- Module mode: evidencelog loads us and drives the loops itself
  ---------------------------------------------------------------------
  if EMBEDDED then
    local M = { help = HELP }
    -- opts.panelY: where to put our panel (below the logger's)
    function M.start(opts)
      opts = opts or {}
      if opts.panelY then panelFallbackY = opts.panelY end
      loadWaypoints()
      rebuildAll()
    end
    function M.handle(line)
      local ok, handled = pcall(handle, line)
      if not ok then printError(handled) return true end
      return handled
    end
    M.loops = { infoLoop, scanLoop }
    M.scan = function() return (scan()) end   -- shared, cached scan (absolute coords)
    function M.setShown(v) hudShown = v; rebuildAll() end
    function M.isShown() return hudShown end
    function M.stop() removeAllOwn() end
    return M
  end

  ---------------------------------------------------------------------
  -- Start (standalone)
  ---------------------------------------------------------------------
  term.clear(); term.setCursorPos(1, 1)
  print("HUD toolkit. Type 'help'. Hotkey hides/shows.")
  if not scanner then print("(no Geo Scanner: block tools off)") end
  if not detector then print("(no Player Detector: player tools off)") end
  print(AI_URL and ("AI: " .. AI_URL) or "AI: off (works fully offline)")
  loadWaypoints()
  rebuildAll()

  local ok, err = pcall(parallel.waitForAny, inputLoop, infoLoop, scanLoop, hotkeyLoop)
  try(overlay.clear)
  if not ok and err ~= "Terminated" then printError(err) end
  print("HUD stopped.")
end

---------------------------------------------------------------------
-- 13. HUD TOOLKIT + COMMAND LINE
---------------------------------------------------------------------
do
  local ok, mod = pcall(HUD_TOOLKIT, "hud")
  if ok and type(mod) == "table" and mod.start then toolkit = mod
  elseif not ok then printError("HUD toolkit failed to load: " .. tostring(mod)) end
end

local LOG_HELP = {
  "mark | summary | recent [count] | hide | q",
  "supply <item-id> <minimum> | supply del <item-id> | supply",
}

local function showRecent(count)
  local file = fs.open(LOG_PATH, "r")
  if not file then print("No evidence log yet."); return end
  local lines, total = {}, 0
  while true do
    local line = file.readLine()
    if not line then break end
    total = total + 1
    lines[(total - 1) % count + 1] = line
  end
  file.close()
  for i = math.max(1, total - count + 1), total do
    print(lines[(i - 1) % count + 1])
  end
end

local function commandSupply(rest)
  if rest == "" then
    local names = {}
    for item in pairs(supplyWatch) do names[#names + 1] = item end
    table.sort(names)
    if #names == 0 then print("Example: supply firework_rocket 16") end
    for _, item in ipairs(names) do print(item .. " minimum " .. supplyWatch[item]) end
    return
  end

  local item, threshold = rest:match("^(%S+)%s+(%d+)$")
  local remove = rest:match("^del%s+(%S+)$")
  item = remove or item
  threshold = tonumber(threshold)
  if not item or (not remove and (not threshold or threshold < 1 or threshold > 2147483647)) then
    print("Usage: supply <item-id> <minimum> | supply del <item-id>")
    return
  end
  item = item:lower()
  if not item:find(":", 1, true) then item = "minecraft:" .. item end
  if not item:match("^[a-z0-9_.%-]+:[a-z0-9_./%-]+$") then print("Invalid item ID."); return end
  supplyWatch[item], supplyLow[item] = threshold, nil
  settings.set("evidence.supplies", supplyWatch)
  if not settings.save() then printError("Couldn't save supply settings."); return end
  print(remove and ("Removed " .. item) or ("Watching " .. item .. " below " .. threshold))
end

local function inputLoop()
  while true do
    term.setTextColour(colours.lightBlue); write("> "); term.setTextColour(colours.white)
    local line = read()
    if not line then return end
    local cmd, rest = line:lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "q" or cmd == "quit" then return
    elseif cmd == "mark" or cmd == "m" then mark("typed")
    elseif cmd == "summary" or cmd == "s" then summary()
    elseif cmd == "supply" then commandSupply(rest)
    elseif cmd == "recent" then
      local count = rest == "" and 8 or tonumber(rest)
      if count and count >= 1 and count <= 50 and count % 1 == 0 then showRecent(count)
      else print("Usage: recent [1-50]") end
    elseif cmd == "hide" then
      HUD.shown = not HUD.shown; HUD.rebuild()
      if toolkit then toolkit.setShown(HUD.shown) end
    elseif cmd == "help" then
      for _, l in ipairs(LOG_HELP) do print(l) end
      if toolkit then for _, l in ipairs(toolkit.help) do print(l) end
      else print("(HUD tools unavailable: no Overlay Module?)") end
    elseif cmd ~= "" then
      if not (toolkit and toolkit.handle(line)) then
        print("unknown: " .. cmd .. "  (type help)")
      end
    end
  end
end

local function main()
  local loops = { run, inputLoop }
  if toolkit then
    -- put the toolkit's panel under ours (and under the alert banner)
    toolkit.start({ panelY = SETTINGS.HUD_Y + HEADER_H + #ROWS * ROW_H + PAD + 24 })
    for _, l in ipairs(toolkit.loops) do loops[#loops + 1] = l end
  end
  parallel.waitForAny(table.unpack(loops))
end

term.clear(); term.setCursorPos(1, 1)
writeLog("START", ("you=%s card=%s manager=%s scanner=%s detector=%s")
  :format(tostring(myName()), tostring(managerOwner()), tostring(HW.manager ~= nil),
          tostring(HW.scanner ~= nil), tostring(HW.detector ~= nil)))
print("Type 'help'. Tap hotkey to mark; hold to hide.")

local ok, err = pcall(main)
if toolkit then toolkit.stop() end
HUD.shown = false
HUD.rebuild()
writeLog("STOP", "stopped")
if not ok and err ~= "Terminated" then printError(err) end
