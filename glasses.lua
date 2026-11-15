-- Smart Glasses toolkit for Advanced Peripherals 0.8.2a.
-- Install the Overlay Module; Geo Scanner, Player Detector and Hotkey Module are optional.
---------------------------------------------------------------------
-- SETTINGS
---------------------------------------------------------------------
local SCAN_RADIUS  = 8
local PLAYER_RANGE = 48
local MAX_BOXES    = 300
local SCAN_EVERY   = 3      -- seconds, only while block highlights are on
local COMPASS_EVERY = 0.1
local STATUS_EVERY  = 0.5
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
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b, c = pcall(fn, ...)
  if ok then return a, b, c end
end
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local function nowMs() return os.epoch("utc") end
local function shorten(s, n)
  s = tostring(s)
  return #s <= n and s or (s:sub(1, n - 2) .. "..")
end
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

local function myDimension() return me().dimension or "?" end

local function myPos(o)
  o = o or me()
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
local HELMET = {
  plate = 0x100F17, edge = 0x62302B, gold = 0xFFC16A,
  glow = 0x77F0FF, faint = 0x7996A6, alarm = 0xFF5958,
}
local SCREEN_W, SCREEN_H = 400, 240
local PANEL_W = 154
local STATUS_X, STATUS_Y = 12, 100
local NAV_X, NAV_Y = 234, 100
local COMPASS_Y = 9
local tape, tapeLabels = {}, {}
local compassYaw, compassTarget

local function text(x, y, content, color, centered, size)
  return try(overlay.createText, {
    gui = true, x = x, y = y, content = content, color = color,
    center = centered == true, fontSize = size or 1, shadow = true,
  })
end

local function rect(x, y, w, h, color, opacity, angle)
  return try(overlay.createRectangle, {
    gui = true, x = x + w / 2, y = y + h / 2, sizeX = w, sizeY = h,
    color = color, opacity = opacity, rotZ = angle or 0,
  })
end

local function readScreen()
  local width, height, scale = try(overlay.getGuiSize)
  if not width or not height or width <= 0 or height <= 0 then return SCREEN_W, SCREEN_H end
  return math.ceil(width / math.max(1, scale or 1)), math.ceil(height / math.max(1, scale or 1))
end

local function plate(prefix, x, y, w, title)
  hud[prefix .. "bg"] = rect(x, y, w, 66, HELMET.plate, 0.77)
  hud[prefix .. "rail"] = rect(x, y, w - 11, 1, HELMET.gold, 0.92)
  hud[prefix .. "angle"] = rect(x + w - 13, y + 4, 13, 1, HELMET.gold, 0.92, 42)
  hud[prefix .. "side"] = rect(x, y + 1, 1, 65, HELMET.edge, 0.95)
  hud[prefix .. "foot"] = rect(x, y + 65, w - 9, 1, HELMET.edge, 0.95)
  hud[prefix .. "title"] = text(x + 8, y + 7, title, HELMET.gold, false, 0.9)
end

local function buildHud()
  for _, o in pairs(hud) do removeObj(o) end
  hud, tape, tapeLabels = {}, {}, {}
  compassYaw, compassTarget = nil, nil
  if not hudShown then return end

  SCREEN_W, SCREEN_H = readScreen()
  local cx = SCREEN_W / 2
  PANEL_W = math.min(154, math.floor((SCREEN_W - 30) / 2))
  STATUS_X, NAV_X = 9, SCREEN_W - PANEL_W - 9
  STATUS_Y = math.max(49, SCREEN_H - 94)
  NAV_Y = STATUS_Y

  local x, y, w = STATUS_X, STATUS_Y, PANEL_W
  plate("suit", x, y, w, "SUIT STATUS")
  if w >= 112 then hud.clock = text(x + w - 37, y + 7, "", HELMET.faint, false, 0.85) end
  hud.vitals = text(x + 8, y + 22, "", HELMET.glow)
  hud.hpBase = rect(x + 8, y + 36, w - 16, 3, HELMET.edge, 1)
  hud.hpBar  = rect(x + 8, y + 36, w - 16, 3, HELMET.glow, 1)
  hud.supply = text(x + 8, y + 47, "", HELMET.gold, false, 0.9)
  for i = 1, 7 do
    hud["healthGap" .. i] = rect(x + 8 + (w - 16) * i / 8, y + 36, 1, 3, HELMET.plate, 1)
  end

  x, y = NAV_X, NAV_Y
  plate("nav", x, y, w, "NAVIGATION")
  hud.pos   = text(x + 8, y + 22, "", HELMET.faint, false, 0.9)
  hud.nav   = text(x + 8, y + 36, "", HELMET.glow, false, 0.9)
  hud.guide = text(x + 8, y + 50, "", HELMET.glow, false, 0.9)

  local tw = math.min(204, SCREEN_W - 22)
  local left = cx - tw / 2
  hud.tapeBg = rect(left, COMPASS_Y, tw, 31, HELMET.plate, 0.72)
  hud.tapeRail = rect(left + 4, COMPASS_Y + 30, tw - 8, 1, HELMET.edge, 0.93)
  hud.tapeLeft = rect(left, COMPASS_Y + 22, 11, 1, HELMET.gold, 1, 40)
  hud.tapeRight = rect(left + tw - 11, COMPASS_Y + 22, 11, 1, HELMET.gold, 1, -40)
  hud.index = rect(cx - 0.5, COMPASS_Y + 23, 1, 9, HELMET.gold, 1)
  hud.heading = text(cx, COMPASS_Y + 35, "", HELMET.gold, true, 1.05)
  hud.target = text(cx, COMPASS_Y + 1, "", HELMET.glow, true, 0.82)

  for bearing = 0, 345, 15 do
    local cardinal = bearing % 45 == 0
    local tick = rect(cx, COMPASS_Y + 24, 1, cardinal and 8 or 4, HELMET.faint, 0.95)
    tape[bearing], hud["tick" .. bearing] = tick, tick
    if cardinal then
      local caption = text(cx, COMPASS_Y + 12, "", HELMET.glow, true, 0.8)
      tapeLabels[bearing], hud["bearing" .. bearing] = caption, caption
    end
  end

  local cy = SCREEN_H / 2
  hud.reticleLeft = rect(cx - 14, cy - 0.5, 5, 1, HELMET.gold, 0.8)
  hud.reticleRight = rect(cx + 9, cy - 0.5, 5, 1, HELMET.gold, 0.8)
  hud.reticleTop = rect(cx - 0.5, cy - 13, 1, 4, HELMET.gold, 0.7)
  hud.reticleBottom = rect(cx - 0.5, cy + 9, 1, 4, HELMET.gold, 0.7)
  hud.msg = text(cx, math.min(cy + 24, SCREEN_H - 25), "", HELMET.gold, true, 0.9)
end

-- Keep ordinary status strings within the width of the side plates.
local textCache = setmetatable({}, {__mode = "k"})
local function set(obj, content, color, limit)
  if not obj then return end
  if type(content) == "string" then content = shorten(content, limit or math.floor((PANEL_W - 14) / 5.6)) end
  local old = textCache[obj]
  if not old or old[1] ~= content then pcall(obj.setContent, content) end
  if color and (not old or old[2] ~= color) and obj.setColor then pcall(obj.setColor, color) end
  textCache[obj] = {content, color}
end

local msgUntil = 0
local function say(s, color)
  set(hud.msg, s, color or HELMET.gold, 44)
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
local showPlayers = false
local playerFilter
local nearbyNames = {}
local PLAYER_UPDATE = 0.25

-- Local pivots relative to a standing player's feet. The four limbs swing
-- from their shoulders or hips when successive samples show movement.
local bones = {
  {x = 0, y = 1.64, width = 0.22, length = 0.22, depth = 0.22, color = 0xF2FFFF},
  {x = 0, y = 1.14, width = 0.07, length = 0.50, depth = 0.08},
  {x = 0, y = 1.38, width = 0.53, length = 0.07, depth = 0.08},
  {x = 0, y = 1.23, width = 0.36, length = 0.06, depth = 0.08},
  {x = 0, y = 0.88, width = 0.31, length = 0.07, depth = 0.08},
  {x = -0.24, y = 1.38, width = 0.07, length = 0.64, depth = 0.07, swing = -1},
  {x = 0.24, y = 1.38, width = 0.07, length = 0.64, depth = 0.07, swing = 1},
  {x = -0.13, y = 0.88, width = 0.08, length = 0.86, depth = 0.08, swing = 1},
  {x = 0.13, y = 0.88, width = 0.08, length = 0.86, depth = 0.08, swing = -1},
}

local function updateSkeleton(name, info, distance, viewer)
  local objects = groups.players[name]
  if not objects then
    objects = {}
    groups.players[name] = objects
  end

  local x, y, z = info.x, info.y, info.z
  local movement = objects.x and math.sqrt((x - objects.x)^2 + (z - objects.z)^2) or 0
  local stride = (objects.stride or 0) + math.min(movement, 1) * 8
  objects.x, objects.z, objects.stride = x, z, stride
  local swing = movement > 0.035 and math.sin(stride) * math.min(movement * 110, 46) or 0
  local yaw = -(tonumber(info.yaw) or 0)
  local sinYaw, cosYaw = math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
  local eyeHeight = tonumber(info.eyeHeight) or 1.62
  local scale = math.max(0.35, math.min(1, eyeHeight / 1.62))
  local tint = distance < 12 and 0xFF716F or 0x66EFFF

  for i, bone in ipairs(bones) do
    local angle = (bone.swing or 0) * swing
    local swingRad = math.rad(angle)
    local half = bone.swing and bone.length / 2 or 0
    local localX = bone.x
    local localZ = -half * math.sin(swingRad)
    local bx = x + localX * cosYaw + localZ * sinYaw
    local by = y + (bone.y - half * math.cos(swingRad)) * scale
    local bz = z - localX * sinYaw + localZ * cosYaw
    local color = bone.color or tint
    local object = objects[i]
    if object then
      try(object.setPos, bx, by, bz)
      try(object.setRotX, angle % 360)
      try(object.setRotY, yaw % 360)
      try(object.setSizeY, bone.length * scale)
      if objects.tint ~= tint and not bone.color then try(object.setColor, color) end
    else
      objects[i] = overlay.createBox({
        x = bx, y = by, z = bz, sizeX = bone.width, sizeY = bone.length * scale, sizeZ = bone.depth,
        rotX = angle % 360, rotY = yaw % 360, color = color, opacity = 0.92,
        depthTest = false, depthMask = false,
      })
    end
  end

  local labelIndex = #bones + 1
  local tag = ("%s  %dm"):format(name, distance)
  local tagY = y + 2.03 * scale
  local dx, dz = viewer.x - x, viewer.z - z
  local dy = viewer.y + (viewer.eyeHeight or 1.62) - tagY
  local labelYaw = math.deg(atan2(dx, dz)) % 360
  local pitch = math.deg(atan2(-dy, math.sqrt(dx * dx + dz * dz))) % 360
  local tagObject = objects[labelIndex]
  if tagObject then
    try(tagObject.setPos, x, tagY, z)
    try(tagObject.setRotX, pitch)
    try(tagObject.setRotY, labelYaw)
    if objects.tag ~= tag then try(tagObject.setContent, tag) end
    if objects.tint ~= tint then try(tagObject.setColor, tint) end
  else
    objects[labelIndex] = overlay.createText({
      x = x, y = tagY, z = z, rotX = pitch, rotY = labelYaw,
      content = tag, center = true, shadow = true, fontSize = 0.024,
      depthTest = false, depthMask = false, culling = false, color = tint,
    })
  end
  objects.tint, objects.tag = tint, tag
end

local function refreshPlayers()
  nearbyNames = {}
  local viewer = me()
  local visible = {}
  if detector and viewer.x then
    local ownName = viewer.username or viewer.customName
    local nearby = try(detector.getPlayersInRange, PLAYER_RANGE) or {}
    for _, name in pairs(nearby) do
      if type(name) == "table" then name = name.name end
      if type(name) == "string" and name ~= ownName then
        local info = try(detector.getPlayer or detector.getPlayerLua, name)
        if info and info.x and info.y and info.z and (not info.uuid or info.uuid ~= viewer.uuid) then
          local distance = math.floor(math.sqrt((info.x - viewer.x)^2
            + (info.y - viewer.y)^2 + (info.z - viewer.z)^2) + 0.5)
          nearbyNames[#nearbyNames + 1] = name .. " " .. distance .. "m"
          if showPlayers and (not playerFilter or playerFilter[name:lower()]) then
            visible[name] = true
            updateSkeleton(name, info, distance, viewer)
          end
        end
      end
    end
    table.sort(nearbyNames)
  end
  for name, objects in pairs(groups.players) do
    if not visible[name] then
      for _, object in ipairs(objects) do removeObj(object) end
      groups.players[name] = nil
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
  "supply <id> <minimum> | supply del <id> | supply",
  "ores | highlight <blocks> | nearest <block>",
  "esp [names] | esp off | wp add/go/del/list <name> | stop",
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

-- Read previous supply preferences once if upgrading from EvidenceLog.
local supplyWatch = settings.get("glasses.supplies") or settings.get("evidence.supplies", {})
local supplyLow = {}

local function drawSupplies(owner)
  if not next(supplyWatch) then set(hud.supply, ""); return end
  if type(owner.inventory) ~= "table" then set(hud.supply, "Supplies unavailable", COLOR.label); return end

  local stock = {}
  for _, item in pairs(owner.inventory) do
    if type(item) == "table" and type(item.name) == "string" then
      stock[item.name] = (stock[item.name] or 0) + (tonumber(item.count or item.amount) or 0)
    end
  end

  local lowest, fraction
  for item, threshold in pairs(supplyWatch) do
    local count = stock[item] or 0
    local low = count < threshold
    if low and not supplyLow[item] then say(("Low %s: %d/%d"):format(plain(item), count, threshold), COLOR.warn) end
    supplyLow[item] = low
    local ratio = count / threshold
    if not fraction or ratio < fraction or (ratio == fraction and item < lowest) then lowest, fraction = item, ratio end
  end
  set(hud.supply, (fraction < 1 and "LOW " or "") .. shorten(plain(lowest), 10) .. " "
    .. (stock[lowest] or 0) .. "/" .. supplyWatch[lowest], fraction < 1 and COLOR.warn or COLOR.good)
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
  settings.set("glasses.supplies", supplyWatch)
  if not settings.save() then printError("Couldn't save supply settings."); return end
  print(remove and ("Removed " .. item) or ("Watching " .. item .. " below " .. threshold))
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
  elseif cmd == "esp" or cmd == "players" then
    if rest[1] == "off" then
      showPlayers = false
      clearGroup("players")
      say("Skeletons off", COLOR.text)
      return true
    end
    if not detector or not (detector.getPlayer or detector.getPlayerLua) then
      say("Skeletons need a Player Detector with coordinates.", COLOR.warn)
      return true
    end
    showPlayers, playerFilter = true, nil
    if #rest > 0 then
      playerFilter = {}
      for _, name in ipairs(rest) do playerFilter[name] = true end
    end
    refreshPlayers()
    say("Skeletons on" .. (playerFilter and (": " .. table.concat(rest, ", ")) or ""), COLOR.good)
  elseif cmd == "gps" then
    gpsCommand(rest)
  elseif cmd == "supply" then
    commandSupply(table.concat(rest, " "))
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
    return false
  end
  return true
end

local compassLabels = {
  [0] = "N", [45] = "NE", [90] = "E", [135] = "SE",
  [180] = "S", [225] = "SW", [270] = "W", [315] = "NW",
}

local function drawCompass(owner)
  if type(owner.yaw) ~= "number" then
    if compassYaw ~= false then
      for _, tick in pairs(tape) do try(tick.setEnabled, false) end
      for _, caption in pairs(tapeLabels) do try(caption.setEnabled, false) end
      compassYaw, compassTarget = false, nil
      set(hud.target, "")
    end
    set(hud.heading, "HEADING --", HELMET.faint)
    return
  end

  local bearing = (owner.yaw + 180) % 360
  local targetBearing
  if navTarget and owner.x and navTarget.dimension == owner.dimension then
    local dx, dz = navTarget.x + 0.5 - owner.x, navTarget.z + 0.5 - owner.z
    targetBearing = (math.deg(atan2(-dx, dz)) + 180) % 360
  end
  if compassYaw == bearing and compassTarget == targetBearing then return end
  compassYaw, compassTarget = bearing, targetBearing

  local cx = SCREEN_W / 2
  local usableHalf = math.max(1, math.min(92, cx - 18))
  local pixelsPerDegree = usableHalf / 84
  for tickBearing = 0, 345, 15 do
    local angle = (tickBearing - bearing + 540) % 360 - 180
    local offset = angle * pixelsPerDegree
    local labelText = compassLabels[tickBearing]
    local shown = math.abs(offset) <= usableHalf
    local tick, caption = tape[tickBearing], tapeLabels[tickBearing]
    if tick then
      try(tick.setEnabled, shown)
      if shown then try(tick.setPos, cx + offset, COMPASS_Y + 25, 0) end
    end
    if caption then
      try(caption.setEnabled, shown)
      if shown then
        try(caption.setPos, cx + offset, COMPASS_Y + 13, 0)
        set(caption, labelText, labelText == "N" and HELMET.alarm or HELMET.glow)
      end
    end
  end

  set(hud.heading, ("%03d  %s"):format(math.floor(bearing + 0.5) % 360, facingName(owner.yaw)), HELMET.gold)
  if targetBearing and hud.target then
    local relative = (targetBearing - bearing + 540) % 360 - 180
    local offset = relative * pixelsPerDegree
    local position = math.max(-usableHalf + 5, math.min(usableHalf - 5, offset))
    try(hud.target.setPos, cx + position, COMPASS_Y + 2, 0)
    set(hud.target, offset > usableHalf and ">" or offset < -usableHalf and "<" or "V", HELMET.glow)
  else
    set(hud.target, "")
  end
end

---------------------------------------------------------------------
-- Loops
---------------------------------------------------------------------
local function infoLoop()
  local lastBar, lastRatio, nextStatus = nil, nil, 0
  while true do
    if hudShown then
      local o = me()
      local now = os.clock()
      if now >= nextStatus then
        nextStatus = now + STATUS_EVERY
        local w, h = readScreen()
        if countObjects() > (try(overlay.getObjectsCount) or 1e9) then rebuildAll()
        elseif SCREEN_W ~= w or SCREEN_H ~= h then buildHud() end
      end
      drawCompass(o)
      local x, y, z = myPos(o)
      if x then
        set(hud.pos, ("%d %d %d  [%s]"):format(math.floor(x), math.floor(y), math.floor(z),
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
      local width = (PANEL_W - 16) * ratio
      if hud.hpBar and (lastBar ~= hud.hpBar or lastRatio ~= ratio) then
        lastBar, lastRatio = hud.hpBar, ratio
        try(hud.hpBar.setSizeX, width)
        try(hud.hpBar.setPos, STATUS_X + 8 + width / 2, STATUS_Y + 37.5, 0)
        try(hud.hpBar.setColor, tint)
      end
      set(hud.clock, textutils.formatTime(os.time(), true))
      drawSupplies(o)
      local dimension = o.dimension or "?"
      if navTarget and navTarget.dimension ~= dimension then
        if next(groups.waypoint) then clearGroup("waypoint") end
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
        local height = dy > 0 and (" / up " .. dy) or (dy < 0 and (" / down " .. -dy) or "")
        set(hud.nav, ("%s  %dm"):format(shorten(navTarget.name, 15), dist), COLOR.waypoint)
        set(hud.guide, dist <= 1 and "Arrived" or (relativeDir(dx, dz, o.yaw) .. height), COLOR.nav)
      else
        set(hud.nav, #nearbyNames > 0 and ("near: " .. table.concat(nearbyNames, ", ")) or "")
        set(hud.guide, "")
      end
      if os.epoch("utc") > msgUntil then set(hud.msg, "") end
    end
    sleep(COMPASS_EVERY)
  end
end

local function scanLoop()
  while true do
    sleep(SCAN_EVERY)
    if hudShown and blockTargets then refreshBlocks() end
  end
end

local function playerLoop()
  while true do
    if hudShown and detector then refreshPlayers() end
    sleep(showPlayers and PLAYER_UPDATE or 2)
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
    if not line or line:lower() == "q" or line:lower() == "quit" then return end
    local ok, handled = pcall(handle, line)
    if not ok then printError(handled)
    elseif not handled then say("unknown: " .. line .. "  (type help)", COLOR.warn) end
  end
end

-- Start the HUD and retain its existing waypoints.
loadWaypoints()
rebuildAll()
print("Field Kit ready. Type help. Glasses hotkey toggles the HUD.")
local ok, reason = pcall(parallel.waitForAny, inputLoop, infoLoop, scanLoop, hotkeyLoop, playerLoop)
removeAllOwn()
if not ok and reason ~= "Terminated" then printError(reason) end
