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
  -- Evidence mode (inventory-loss logging, REC, marks). Off: stats only.
  EVIDENCE          = false,

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
  MANAGER_MERGE     = 2.5,             -- hits this close together = same manager
  ALERT_RANGE       = 16,              -- warn once when a non-ally comes this close
  WATCH_BLOCKS      = { "inventory_manager" },

  -- Look
  HUD_X = 6, HUD_Y = 6, HUD_WIDTH = 250,
  ALERT_SECONDS     = 6,
  MARKER_LABELS     = false,           -- floating text over managers (off = just the box)

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

-- Box sizes: the overlay places rectangles in GUI units (like text) but
-- SIZES them in raw pixels, so sizes get multiplied by your GUI scale.
-- Detected automatically; force with:  uiscale 2   (saved to /.glasses_box)
local UI = { box = nil }
if fs.exists("/.glasses_box") then
  local f = fs.open("/.glasses_box", "r")
  local v = tonumber(f.readAll()); f.close()
  if v and v > 0.2 and v < 9 then UI.box = v end
end
local LAYOUT   -- set up in section 5
local function boxScale() return UI.box or (LAYOUT and LAYOUT.scale) or 2 end

-- Terminal output. Once the layout is up, lines go into the log window
-- so they don't scroll the status bar or your typing away.
local TERM = {}
local toolkit   -- built-in HUD toolkit (section 13a), set at startup

-- Session statistics (shared by the logger and the HUD toolkit)
local STATS = {
  started = os.epoch("utc"),
  dist = 0, topSpeed = 0,              -- blocks walked/flown, best b/s
  gained = 0, used = 0,                -- items picked up / used or dropped
  dmg = 0, heal = 0, deaths = 0,       -- health changes
  seen = {}, seenCount = 0,            -- different players met
  oresNear = 0, bestOre = nil,         -- from the latest block scan
}
local function out(s, color)
  s = tostring(s)
  if TERM.log then
    local old = term.redirect(TERM.log)
    if color and term.isColour() then term.setTextColour(color) end
    print(s)
    term.setTextColour(colours.white)
    term.redirect(old)
  else
    print(s)
  end
end

-- Who "you" are. Filled from the glasses, or learned from the player
-- standing exactly where the glasses are (some builds don't report a name).
local SELF = { name = nil }
if fs.exists("/.glasses_me") then
  local f = fs.open("/.glasses_me", "r")
  local n = (f.readAll() or ""):gsub("%s", ""); f.close()
  if n ~= "" then SELF.name = n end
end
local function setSelf(n)
  SELF.name = n
  local f = fs.open("/.glasses_me", "w"); f.write(n); f.close()
end
-- Given { name = distance }, the wearer is the closest player, and they
-- must be within 4 blocks (the detector's position for you can be ~2 off).
local function learnSelf(dists)
  if SELF.name then return end
  local best, bd
  for n, d in pairs(dists) do
    if type(n) == "string" and d and (not bd or d < bd) then best, bd = n, d end
  end
  if best and bd < 4 then setSelf(best) end
end

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
  return (w and w.name) or SELF.name
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
  if SETTINGS.EVIDENCE then
    local line = ("%s  %-8s  @ %s  |  %s"):format(timestamp(), kind, whereText(), message)
    local f = fs.open(LOG_PATH, "a")
    if f then f.writeLine(line); f.close() end
  end
  local kc = ({ SUSPECT = colours.red, LOSS = colours.orange, MANAGER = colours.yellow,
                PLAYER = colours.orange, TAMPER = colours.red, MARK = colours.lightBlue,
                WARN = colours.orange })[kind] or colours.lightGrey
  out(shorten(os.date("%H:%M") .. " " .. kind .. " " .. message, 52), kc)
end

---------------------------------------------------------------------
-- 5. HUD  (panel, alert banner, 3D markers)
---------------------------------------------------------------------
local HUD = { shown = true, parts = {}, markers = {}, alertUntil = 0,
              contacts = {}, toast = {}, started = 0 }

-- Screen layout ------------------------------------------------------
-- Positions are in overlay text units. getGuiSize() may report raw pixels
-- or GUI-scaled units depending on the build, so big raw-looking numbers
-- get divided by the scale. Override with:  uiwidth 640 360
LAYOUT = { W = 480, H = 270, scale = nil }
function LAYOUT.compute()
  local a, b, c
  if HW.overlay then a, b, c = try(HW.overlay.getGuiSize) end
  LAYOUT.raw = { a, b, c }
  -- Don't trust the order: collect the numbers and sort them.
  -- Smallest = GUI scale, middle = height, largest = width.
  local nums = {}
  local src = (type(a) == "table") and { a.width or a[1], a.height or a[2], a.scale or a[3] } or { a, b, c }
  for i = 1, 3 do if type(src[i]) == "number" then nums[#nums + 1] = src[i] end end
  table.sort(nums)
  local sc, h, w
  if #nums >= 3 then sc, h, w = nums[1], nums[2], nums[3]
  elseif #nums == 2 then h, w = nums[1], nums[2] end
  if sc and sc >= 1 and sc <= 8 then LAYOUT.scale = sc end
  -- Raw pixel sizes (height > 600) get converted to GUI units.
  if w and h and sc and sc >= 1 and sc <= 8 and h > 600 then w, h = w / sc, h / sc end
  if not w or w < 240 or not h or h < 140 then w, h = 480, 270 end   -- implausible: safe default
  LAYOUT.W, LAYOUT.H = math.floor(w), math.floor(h)
  if fs.exists("/.glasses_screen") then
    local f = fs.open("/.glasses_screen", "r")
    local ow, oh = (f.readAll() or ""):match("(%d+)%s+(%d+)"); f.close()
    if ow then LAYOUT.W, LAYOUT.H = tonumber(ow), tonumber(oh) end
  end
end

-- Card geometry (shared look for every card)
local CARD = { W = 152, HDR = 13, ROW = 12, PADY = 4 }
local SROWS = {
  { key = "time",  label = "TIME"  },
  { key = "dist",  label = "DIST"  },
  { key = "items", label = "ITEMS" },
  { key = "hp",    label = "HP"    },
  { key = "seen",  label = "SEEN"  },
  { key = "ores",  label = "ORES"  },
  { key = "mgr",   label = "MGR"   },
}
local rowValues = {}

local function removeObject(o)
  if o and HW.overlay then
    local id = try(o.getId) or o.id
    if id then pcall(HW.overlay.removeObject, id) end
  end
end

local function rect(x, y, w, h, color, opacity)
  return try(HW.overlay.createRectangle, {
    gui = true, x = x, y = y, sizeX = w * boxScale(), sizeY = h * boxScale(),
    color = color, opacity = opacity,
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

-- A card: dark body, coloured header, accent edge, faint zebra rows.
-- Returns the list of created objects.
local function card(list, x, y, w, rows, title, accent)
  local h = CARD.HDR + rows * CARD.ROW + CARD.PADY
  list[#list + 1] = rect(x, y, w, h, COLOR.panel, 0.86)
  list[#list + 1] = rect(x, y, w, CARD.HDR, COLOR.header, 0.95)
  list[#list + 1] = rect(x, y, 2, h, accent or COLOR.accent, 1)
  for i = 2, rows, 2 do
    list[#list + 1] = rect(x + 2, y + CARD.HDR + 2 + (i - 1) * CARD.ROW, w - 2, CARD.ROW, 0xFFFFFF, 0.05)
  end
  list[#list + 1] = text(x + 7, y + 3, title, accent or COLOR.accent)
  return h
end
local function rowY(y, i) return y + CARD.HDR + 4 + (i - 1) * CARD.ROW end

-- Moving an existing object: overlay objects animate from x=0 when they
-- are CREATED, so everything that changes is created once and then moved
-- or re-texted in place. These try the setter names different AP builds use.
local function moveX(obj, x)
  if not obj then return false end
  if type(obj.setX) == "function" then return (pcall(obj.setX, x)) end
  if type(obj.setPosition) == "function" then return (pcall(obj.setPosition, x, obj.getY and select(2, pcall(obj.getY)) or 0)) end
  return false
end

local NAV_H = CARD.HDR + 4 * CARD.ROW + CARD.PADY
local CONTACT_ROWS = 5

-- Left column: EVIDENCE card, then NAV (toolkit), then CONTACTS.
function HUD.build()
  if not HW.overlay then return end
  LAYOUT.compute()
  local P, list = HUD.parts, {}
  local x, y = 4, 4
  HUD.statusH = card(list, x, y, CARD.W, #SROWS, "STATS", COLOR.accent)
  for i, o in ipairs(list) do P["c" .. i] = o end
  if SETTINGS.EVIDENCE then P.dot = text(x + CARD.W - 24, y + 3, "REC", COLOR.bad) end
  for i, row in ipairs(SROWS) do
    P["l_" .. row.key] = text(x + 7, rowY(y, i), row.label, COLOR.label)
    P["v_" .. row.key] = text(x + 44, rowY(y, i), rowValues[row.key] and rowValues[row.key][1] or "-",
                             rowValues[row.key] and rowValues[row.key][2] or COLOR.text)
  end

  -- CONTACTS: fixed card with 5 rows; rows are re-texted, never recreated
  local cy = 4 + HUD.statusH + 6 + NAV_H + 6
  local cl = {}
  card(cl, x, cy, CARD.W, CONTACT_ROWS, "CONTACTS", COLOR.good)
  HUD.cpool = { edge = cl[3], title = cl[#cl], rows = {} }
  HUD.cpool.count = text(x + CARD.W - 18, cy + 3, "0", COLOR.good)
  cl[#cl + 1] = HUD.cpool.count
  for i = 1, CONTACT_ROWS do
    local r = {
      arrow = text(x + 7, rowY(cy, i), "", COLOR.text),
      name  = text(x + 17, rowY(cy, i), i == 1 and "all clear" or "", COLOR.label),
      dist  = text(x + CARD.W - 34, rowY(cy, i), "", COLOR.text),
    }
    HUD.cpool.rows[i] = r
    cl[#cl + 1] = r.arrow; cl[#cl + 1] = r.name; cl[#cl + 1] = r.dist
  end
  HUD.contacts = cl
end
function HUD.leftBottom() return 4 + (HUD.statusH or 101) + 6 end

function HUD.row(key, value, color)
  value = shorten(value, 17)
  rowValues[key] = { value, color or COLOR.text }
  local obj = HUD.parts["v_" .. key]
  if obj then setText(obj, value); setColor(obj, color or COLOR.text) end
end

-- list: { { name, dist, arrow, ally }, ... }  -> updates the fixed rows
function HUD.drawContacts(list)
  local cp = HUD.cpool
  if not cp then return end
  local hostile = 0
  for _, c in ipairs(list) do if not c.ally then hostile = hostile + 1 end end
  local accent = hostile > 0 and COLOR.bad or COLOR.good
  setText(cp.count, tostring(#list)); setColor(cp.count, accent)
  setColor(cp.title, accent)
  if cp.edge and type(cp.edge.setColor) == "function" then pcall(cp.edge.setColor, accent) end
  for i = 1, CONTACT_ROWS do
    local r, c = cp.rows[i], list[i]
    if c then
      local col = c.ally and COLOR.good or COLOR.warn
      if not c.ally and c.dist and c.dist <= SETTINGS.ALERT_RANGE then col = COLOR.bad end
      local d = c.dist and (math.floor(c.dist) .. "m") or "?"
      if i == CONTACT_ROWS and #list > CONTACT_ROWS then d = "+" .. (#list - CONTACT_ROWS + 1) end
      setText(r.arrow, c.arrow); setColor(r.arrow, col)
      setText(r.name, shorten(c.name, 12)); setColor(r.name, col)
      setText(r.dist, d)
    else
      setText(r.arrow, "")
      setText(r.name, (i == 1 and #list == 0) and "all clear" or ""); setColor(r.name, COLOR.label)
      setText(r.dist, "")
    end
  end
end

-- Top-centre toast (one at a time, sized to the message)
function HUD.alert(message, color)
  HUD.alertUntil = nowMs() + SETTINGS.ALERT_SECONDS * 1000
  if not HW.overlay then return end
  try(HW.overlay.setAutoUpdate, false)
  for _, o in ipairs(HUD.toast) do removeObject(o) end
  HUD.toast = {}
  if HUD.shown then
    -- fit between the left cards and the contacts card: wrap to <= 2 lines
    local maxChars = math.max(16, math.floor((LAYOUT.W - 2 * (CARD.W + 14) - 16) / 6))
    local lines, cur = {}, ""
    for word in tostring(message):gmatch("%S+") do
      if #cur == 0 then cur = word
      elseif #cur + 1 + #word <= maxChars then cur = cur .. " " .. word
      else lines[#lines + 1] = cur; cur = word end
    end
    if #cur > 0 then lines[#lines + 1] = cur end
    if #lines > 2 then lines = { lines[1], shorten(table.concat(lines, " ", 2), maxChars) } end
    for i, l in ipairs(lines) do lines[i] = shorten(l, maxChars) end
    local longest = 0
    for _, l in ipairs(lines) do longest = math.max(longest, #l) end
    local w, h = longest * 6 + 16, #lines * 10 + 6
    local x, y = LAYOUT.W / 2 - w / 2, LAYOUT.H / 2 - 30 - h
    color = color or COLOR.bad
    HUD.toast[#HUD.toast + 1] = rect(x, y, w, h, COLOR.panel, 0.9)
    HUD.toast[#HUD.toast + 1] = rect(x, y, 3, h, color, 1)
    HUD.toast[#HUD.toast + 1] = rect(x, y + h - 1, w, 1, color, 1)
    for i, l in ipairs(lines) do
      HUD.toast[#HUD.toast + 1] = text(x + 9, y + 4 + (i - 1) * 10, l, color)
    end
  end
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
end

function HUD.tick()
  if #HUD.toast > 0 and nowMs() > HUD.alertUntil then
    for _, o in ipairs(HUD.toast) do removeObject(o) end
    HUD.toast = {}
  end
  if HUD.parts.dot then
    setText(HUD.parts.dot, (math.floor(nowMs() / 700) % 2 == 0) and "REC" or "")
  end
end

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
  list[#list + 1] = box(1.04, COLOR.marker, 0.45)      -- just the block, through walls
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
  local n = #HUD.contacts + #HUD.toast
  for _, o in pairs(HUD.parts) do if o then n = n + 1 end end
  for _, objs in pairs(HUD.markers) do n = n + #objs end
  return n
end

function HUD.rebuild()
  if not HW.overlay then return end
  -- remove only our own objects, so the toolkit's stay put
  try(HW.overlay.setAutoUpdate, false)
  for _, o in pairs(HUD.parts) do removeObject(o) end
  for _, objs in pairs(HUD.markers) do for _, o in ipairs(objs) do removeObject(o) end end
  for _, o in ipairs(HUD.contacts) do removeObject(o) end
  for _, o in ipairs(HUD.toast) do removeObject(o) end
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
  HUD.parts, HUD.markers, HUD.contacts, HUD.toast = {}, {}, {}, {}
  HUD.cpool = nil
  if HUD.shown then HUD.build() end
end

-- Rebuild only after a real wipe (Curios bug, relog): the overlay suddenly
-- has NO objects. Never more than once every 5 seconds.
HUD.lastRebuild = 0
function HUD.checkIntact()
  if not HW.overlay or not HUD.shown then return end
  local n = try(HW.overlay.getObjectsCount)
  if n == 0 and HUD.objectCount() > 0 and nowMs() - HUD.lastRebuild > 5000 then
    HUD.lastRebuild = nowMs()
    HUD.rebuild()
    if toolkit then toolkit.setShown(true) end
  end
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

-- Allies never trigger alerts. Saved to /evidence/allies.txt
local ALLY_FILE = fs.combine(SETTINGS.LOG_FOLDER, "allies.txt")
local allies = {}
if fs.exists(ALLY_FILE) then
  local f = fs.open(ALLY_FILE, "r")
  for line in (f.readAll() or ""):gmatch("[^\n]+") do allies[line:lower()] = true end
  f.close()
end
local function saveAllies()
  local f = fs.open(ALLY_FILE, "w")
  for n in pairs(allies) do f.writeLine(n) end
  f.close()
end

local playerState = {}   -- name -> "near" once alerted, cleared when they leave
local playerDist = {}    -- name -> metres (last poll)
local playerPos = {}     -- name -> {x, z}

local function isSelf(name)
  if type(name) ~= "string" then return true end
  local me = myName()
  return me ~= nil and name:lower() == me:lower()
end

local function checkPlayers()
  local names = {}
  if HW.detector then
    for _, p in pairs(try(HW.detector.getPlayersInRange, SETTINGS.PLAYER_RANGE) or {}) do
      names[#names + 1] = type(p) == "table" and p.name or p
    end
  elseif HW.env then
    for _, e in pairs(try(HW.env.scanEntities, SETTINGS.PLAYER_RANGE, false, "minecraft:player") or {}) do
      names[#names + 1] = type(e) == "table" and e.name
    end
  end
  local x, y, z = myPosition()
  local seenNow, dists = {}, {}
  for _, n in ipairs(names) do
    if HW.detector and x and type(n) == "string" then
      local p = try(HW.detector.getPlayer, n)
      if type(p) == "table" and p.x then
        dists[n] = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2)
        playerPos[n] = { x = p.x, z = p.z }
      end
    end
  end
  learnSelf(dists)
  for _, n in ipairs(names) do
    local dist = dists[n]
    if not isSelf(n) and not (dist and dist < 1.2) then
      if not STATS.seen[n] then STATS.seen[n] = true; STATS.seenCount = STATS.seenCount + 1 end
      recentPlayers[n] = nowMs()
      playerDist[n] = dist
      seenNow[n] = true
      -- one alert per approach, for non-allies only
      if dist and not allies[n:lower()] then
        if dist <= SETTINGS.ALERT_RANGE and playerState[n] ~= "near" then
          playerState[n] = "near"
          writeLog("PLAYER", ("%s came within %dm"):format(n, math.floor(dist)))
          HUD.alert(("%s is %dm away"):format(n, math.floor(dist)), COLOR.warn)
          lastEvent = n .. " close"
        elseif dist > SETTINGS.ALERT_RANGE + 8 then
          playerState[n] = nil
        end
      end
    end
  end
  for n in pairs(playerState) do if not seenNow[n] then playerState[n] = nil end end
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
-- Known managers: { {x,y,z}, ... }  saved to /evidence/managers.txt so a
-- restart doesn't log them all again. Hits within MANAGER_MERGE blocks of a
-- known one are the same manager (the scan position wobbles as you move).
local MGR_FILE = fs.combine(SETTINGS.LOG_FOLDER, "managers.txt")
local knownManagers = {}
if fs.exists(MGR_FILE) then
  local f = fs.open(MGR_FILE, "r")
  for line in (f.readAll() or ""):gmatch("[^\n]+") do
    local x, y, z = line:match("^(%-?%d+) (%-?%d+) (%-?%d+)")
    if x then knownManagers[#knownManagers + 1] = { x = tonumber(x), y = tonumber(y), z = tonumber(z) } end
  end
  f.close()
end
local function matchKnown(x, y, z)
  local r2 = SETTINGS.MANAGER_MERGE ^ 2
  for i, m in ipairs(knownManagers) do
    if (m.x - x) ^ 2 + (m.y - y) ^ 2 + (m.z - z) ^ 2 <= r2 then return i end
  end
end
local inManagerArea = false
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
      out[#out + 1] = { name = b.name, tags = b.tags, x = bx + b.x, y = by + b.y, z = bz + b.z,
                        d = b.x * b.x + b.y * b.y + b.z * b.z }
    end
  end
  return out
end

local ORE_RANK = { "ancient_debris", "diamond", "emerald", "gold", "lapis", "redstone",
                  "uranium", "osmium", "iron", "copper", "zinc", "coal" }
local function isOre(b)
  if b.name:find("_ore", 1, true) or b.name:find("ancient_debris", 1, true) then return true end
  if type(b.tags) == "table" then
    for k, v in pairs(b.tags) do
      local t = type(v) == "string" and v or (type(k) == "string" and k) or ""
      if t:find("ores", 1, true) then return true end
    end
  end
  return false
end

local function checkManagers()
  local blocks = scanBlocksAbsolute()
  if type(blocks) ~= "table" then return end

  -- ore stats from this same scan
  local ores, best, bestRank = 0, nil, 99
  for _, b in ipairs(blocks) do
    if type(b.name) == "string" and isOre(b) then
      ores = ores + 1
      for r, key in ipairs(ORE_RANK) do
        if r < bestRank and b.name:find(key, 1, true) then best, bestRank = key, r; break end
      end
    end
  end
  STATS.oresNear, STATS.bestOre = ores, best

  local found, newOnes = {}, 0
  for _, b in ipairs(blocks) do
    if type(b.name) == "string" and isWatched(b.name) then
      local i = matchKnown(b.x, b.y, b.z)
      if not i then
        knownManagers[#knownManagers + 1] = { x = b.x, y = b.y, z = b.z }
        i = #knownManagers
        newOnes = newOnes + 1
        local f = fs.open(MGR_FILE, "a")
        if f then f.writeLine(("%d %d %d %s"):format(b.x, b.y, b.z, timestamp())); f.close() end
        writeLog("MANAGER", ("new at %d %d %d (%dm)"):format(b.x, b.y, b.z, math.floor(math.sqrt(b.d or 0))))
      end
      local m = knownManagers[i]   -- stable position, so the box doesn't jitter
      found["m" .. i] = { x = m.x, y = m.y, z = m.z, dist = math.sqrt(b.d or 0) }
    end
  end
  stats.managers = #knownManagers

  local count = 0
  for _ in pairs(found) do count = count + 1 end
  -- ONE alert when you walk into an area with managers, not one per scan
  if count > 0 and not inManagerArea then
    inManagerArea = true
    HUD.alert(("%d inventory manager%s here"):format(count, count == 1 and "" or "s"), COLOR.warn)
    lastEvent = "manager area"
  elseif count == 0 then
    inManagerArea = false
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
      if SETTINGS.EVIDENCE then
        writeLog("WARN", "Can't read your inventory (needs a Player Detector or Inventory Manager).")
      end
    end
    return
  end
  warnedNoInventory = false
  local now, total = countItems(list)
  if not before then before, beforeTotal = now, total; return end

  -- stats: items gained / used this session
  for name, has in pairs(now) do
    local had = before[name] or 0
    if has > had then STATS.gained = STATS.gained + (has - had) end
  end
  for name, had in pairs(before) do
    local has = now[name] or 0
    if has < had then STATS.used = STATS.used + (had - has) end
  end
  if not SETTINGS.EVIDENCE then before, beforeTotal = now, total; return end

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
local function fmtDist(b)
  if b >= 1000 then return ("%.1fkm"):format(b / 1000) end
  return math.floor(b) .. "m"
end

local function refreshRows()
  local w = wearer()
  local yaw = w and w.yaw
  local x, _, z = myPosition()
  local function arrowTo(tx, tz)
    if not (yaw and x) then return "" end
    local bearing = (math.deg((math.atan2 or math.atan)(-(tx - x), tz - z)) + 360) % 360
    local rel = (bearing - yaw + 540) % 360 - 180
    if math.abs(rel) < 30 then return "^" elseif math.abs(rel) > 150 then return "v" end
    return rel > 0 and ">" or "<"
  end

  local up = math.floor((nowMs() - STATS.started) / 1000)
  HUD.row("time", ("%dh %02dm  day %d"):format(math.floor(up / 3600), math.floor(up / 60) % 60, os.day and os.day() or 0), COLOR.text)
  HUD.row("dist", ("%s  top %.0f b/s"):format(fmtDist(STATS.dist), STATS.topSpeed), COLOR.text)
  if invSource == "none" then
    HUD.row("items", "need detector", COLOR.label)
  else
    HUD.row("items", ("%d  +%d -%d"):format(beforeTotal or 0, STATS.gained, STATS.used), COLOR.text)
  end
  HUD.row("hp", ("-%d +%d  %d dead"):format(math.floor(STATS.dmg), math.floor(STATS.heal), STATS.deaths),
          STATS.deaths > 0 and COLOR.warn or COLOR.text)
  HUD.row("seen", STATS.seenCount .. (STATS.seenCount == 1 and " player" or " players"), COLOR.text)
  if not HW.scanner then
    HUD.row("ores", "no scanner", COLOR.label)
  else
    HUD.row("ores", STATS.oresNear .. " near" .. (STATS.bestOre and ("  " .. STATS.bestOre:gsub("ancient_", "")) or ""),
            STATS.bestOre and (STATS.bestOre:find("diamond") or STATS.bestOre:find("debris") or STATS.bestOre:find("emerald"))
              and COLOR.good or COLOR.text)
  end

  -- managers: how many here + nearest one's distance and direction
  local mc, nearest = 0, nil
  for _, m in pairs(currentManagers) do
    mc = mc + 1
    if not nearest or m.dist < nearest.dist then nearest = m end
  end
  if not HW.scanner then
    HUD.row("mgr", "no scanner", COLOR.label)
  elseif nearest then
    HUD.row("mgr", ("%d here %dm %s"):format(mc, math.floor(nearest.dist), arrowTo(nearest.x + 0.5, nearest.z + 0.5)), COLOR.bad)
  else
    HUD.row("mgr", stats.managers .. " known", COLOR.text)
  end

  -- contacts card
  local list = {}
  for _, n in ipairs(nearbyList()) do
    local p = playerPos[n]
    list[#list + 1] = { name = n, dist = playerDist[n], ally = allies[n:lower()] == true,
                        arrow = p and arrowTo(p.x, p.z) or "?" }
  end
  table.sort(list, function(a, b) return (a.dist or 1e9) < (b.dist or 1e9) end)
  HUD.drawContacts(list)
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
  out(("Loss %d  Suspect %d"):format(stats.losses, stats.suspect), colours.yellow)
  out(("Managers %d  Marks %d"):format(stats.managers, stats.marks), colours.yellow)
  out("Log: " .. LOG_PATH, colours.lightGrey)
end

local function showStats()
  local up = math.floor((nowMs() - STATS.started) / 1000)
  out("-- session stats --", colours.yellow)
  out(("time   %dh %02dm %02ds"):format(math.floor(up / 3600), math.floor(up / 60) % 60, up % 60))
  out(("dist   %s"):format(fmtDist(STATS.dist)))
  out(("speed  top %.1f b/s"):format(STATS.topSpeed))
  out(("avg    %.1f b/s"):format(up > 0 and STATS.dist / up or 0))
  out(("items  %d now"):format(beforeTotal or 0))
  out(("       +%d got  -%d used"):format(STATS.gained, STATS.used))
  out(("hp     -%d taken +%d healed"):format(math.floor(STATS.dmg), math.floor(STATS.heal)))
  out(("deaths %d"):format(STATS.deaths))
  out(("seen   %d players"):format(STATS.seenCount))
  out(("ores   %d near (%s)"):format(STATS.oresNear, STATS.bestOre or "-"))
  out(("mgrs   %d known"):format(stats.managers))
end

-- List known managers, nearest first.
local function listManagers()
  local x, y, z = myPosition()
  local list = {}
  for _, m in ipairs(knownManagers) do
    local d = x and math.sqrt((m.x - x) ^ 2 + (m.y - y) ^ 2 + (m.z - z) ^ 2) or 0
    list[#list + 1] = { m = m, d = d }
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  if #list == 0 then return out("No managers found yet.") end
  out(#list .. " known (" .. MGR_FILE .. "):", colours.yellow)
  for i = 1, math.min(#list, 12) do
    local e = list[i]
    out(("%6d %4d %6d %5dm"):format(e.m.x, e.m.y, e.m.z, math.floor(e.d)))
  end
  if #list > 12 then out("+" .. (#list - 12) .. " more in the file") end
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
      if SETTINGS.EVIDENCE then mark("hotkey")
      else
        HUD.shown = not HUD.shown; HUD.rebuild()
        if toolkit then toolkit.setShown(HUD.shown) end
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
  local SCAN_RADIUS  = 16
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
    return box(x - 0.01, y - 0.01, z - 0.01, 1.02, 1.02, 1.02, color, 0.5)
  end

  local function label(x, y, z, content, color)
    return try(overlay.createText, {
      x = x, y = y, z = z, content = content, color = color, shadow = true, center = true,
    })
  end

  -- A tall light beam you can see from far away.
  local function beacon(x, y, z, color, text)
    return {
      box(x + 0.35, y, z + 0.35, 0.3, 48, 0.3, color, 0.35),
      blockBox(x, y, z, color),
      label(x + 0.5, y + 1.8, z + 0.5, text, color),
    }
  end

  ---------------------------------------------------------------------
  -- HUD panel
  ---------------------------------------------------------------------
  local PANEL_X, PANEL_Y, PANEL_W = 4, 87, 152

  local function text(x, y, content, color)
    return try(overlay.createText, { gui = true, x = x, y = y, content = content, color = color, shadow = true })
  end
  local function rect(x, y, w, h, color, opacity)
    return try(overlay.createRectangle, { gui = true, x = x, y = y,
      sizeX = w * boxScale(), sizeY = h * boxScale(), color = color, opacity = opacity })
  end

  -- Left side: NAV card.  Top centre: compass bar.
  local COMPASS_W = 160
  -- top of the compass bar: above armour/health/hotbar, below Jade's tooltip
  local function compassY() return LAYOUT.H - 76 end
  local buildCompass   -- defined with the compass code below
  local function buildHud()
    for _, o in pairs(hud) do removeObj(o) end
    hud = {}
    if not hudShown then return end
    local x, y, w = PANEL_X, PANEL_Y, PANEL_W
    local list = {}
    card(list, x, y, w, 4, "NAV", COLOR.accent)
    for i, o in ipairs(list) do hud["c" .. i] = o end
    hud.clock = text(x + w - 34, y + 3, "", COLOR.label)
    for i, l in ipairs({ "POS", "FACE", "SPD", "MODE" }) do hud["l" .. i] = text(x + 7, rowY(y, i), l, COLOR.label) end
    hud.pos  = text(x + 40, rowY(y, 1), "", COLOR.text)
    hud.face = text(x + 40, rowY(y, 2), "", COLOR.text)
    hud.spd  = text(x + 40, rowY(y, 3), "", COLOR.text)
    hud.mode = text(x + 40, rowY(y, 4), "", COLOR.text)
    -- compass bar
    local cx = LAYOUT.W / 2
    local cy = compassY()
    hud.cbg   = rect(cx - COMPASS_W / 2, cy, COMPASS_W, 15, COLOR.panel, 0.86)
    hud.cline = rect(cx - COMPASS_W / 2, cy + 14, COMPASS_W, 1, COLOR.accent, 1)
    hud.notch = rect(cx - 0.5, cy - 4, 1, 4, 0xFFFFFF, 1)
    buildCompass()
  end

  local LINE_CHARS = 17
  local function set(obj, content, color)
    if not obj then return end
    if type(content) == "string" then content = shorten(content, LINE_CHARS) end
    pcall(obj.setContent, content)
    if color and obj.setColor then pcall(obj.setColor, color) end
  end

  -- Feedback goes to the shared toast + the terminal log
  local function say(s, color)
    HUD.alert(s, color or COLOR.accent)
    out(s)
    return true
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

  local function bearingTo(dx, dz) return (math.deg(atan2(-dx, dz)) + 360) % 360 end

  -- Compass: each letter is its own text, created ONCE and slid sideways
  -- with a setter (new objects fly in from x=0, so we never recreate them
  -- per frame). If this AP build has no position setter, letters are only
  -- recreated when your heading changes by a few degrees.
  local compass = nil          -- { marks = {...}, wp = rect, label = text, low = text }
  local COMPASS_MARKS = {}
  for a = 0, 345, 15 do
    local names = { [0] = "S", [90] = "W", [180] = "N", [270] = "E",
                    [45] = "SW", [135] = "NW", [225] = "NE", [315] = "SE" }
    local n = names[a] or "."
    COMPASS_MARKS[#COMPASS_MARKS + 1] = { a = a, label = n,
      color = (a % 90 == 0) and COLOR.text or COLOR.label }
  end
  local canMove = nil          -- learned on first use
  local lastYawKey = nil

  local function clearCompass()
    if not compass then return end
    for _, m in ipairs(compass.marks) do removeObj(m.obj) end
    removeObj(compass.wp); removeObj(compass.label); removeObj(compass.low)
    compass = nil
  end

  function buildCompass()
    clearCompass()
    if not hudShown then return end
    local cx = LAYOUT.W / 2
    compass = { marks = {} }
    for i, m in ipairs(COMPASS_MARKS) do
      compass.marks[i] = { a = m.a, label = m.label, obj = try(overlay.createText, {
        gui = true, x = cx, y = compassY() + 4, content = "", color = m.color, shadow = true }) }
    end
    compass.wp    = rect(cx - 1.5, compassY() - 5, 0, 0, COLOR.waypoint, 1)
    compass.label = try(overlay.createText, { gui = true, x = cx - 45, y = compassY() - 15, content = "", color = COLOR.waypoint, shadow = true })
    compass.wpX = nil
    compass.low   = try(overlay.createText, { gui = true, x = cx - 45, y = LAYOUT.H / 2 + 14, content = "", color = COLOR.bad, shadow = true })
    lastYawKey = nil
  end

  local function setX(obj, x)
    if canMove == false then return false end
    local ok = moveX(obj, x)
    if canMove == nil then canMove = ok end
    return ok
  end

  local function drawCompass(yaw, navBearing, navLabel, lowHp)
    if not compass then return end
    local cx = LAYOUT.W / 2
    local half = COMPASS_W / 2 - 10

    if yaw then
      local yawKey = math.floor(yaw / 3 + 0.5)
      if canMove == false and yawKey ~= lastYawKey then
        -- no setter on this build: rebuild letters, but only on real turns
        buildCompass()
      end
      if canMove ~= false or yawKey ~= lastYawKey then
        lastYawKey = yawKey
        for _, m in ipairs(compass.marks) do
          local rel = (m.a - yaw + 540) % 360 - 180
          if math.abs(rel) <= 90.5 then
            setX(m.obj, cx + rel / 90 * half - #m.label * 3)
            if canMove == false then
              -- created at cx; recreate at the right spot instead
              removeObj(m.obj)
              m.obj = try(overlay.createText, { gui = true, x = cx + rel / 90 * half - #m.label * 3, y = compassY() + 4,
                content = m.label, color = (m.a % 90 == 0) and COLOR.text or COLOR.label, shadow = true })
            else
              setText(m.obj, m.label)
            end
          else
            setText(m.obj, "")
          end
        end
      end
    end

    -- waypoint tick + label
    if navBearing and yaw then
      local rel = (navBearing - yaw + 540) % 360 - 180
      local px = cx + math.max(-1, math.min(1, rel / 90)) * half
      if compass.wp and type(compass.wp.setSizes) == "function" then pcall(compass.wp.setSizes, 3 * boxScale(), 5 * boxScale()) end
      if canMove ~= false then
        setX(compass.wp, px - 1.5)
      elseif not compass.wpX or math.abs(compass.wpX - px) >= 3 then
        -- no setter: only re-place the tick when it has really moved
        removeObj(compass.wp); compass.wp = rect(px - 1.5, compassY() - 5, 3, 5, COLOR.waypoint, 1)
      end
      compass.wpX = px
      setText(compass.label, navLabel or "")
      if canMove ~= false then setX(compass.label, cx - #(navLabel or "") * 3) end
    else
      if compass.wp and type(compass.wp.setSizes) == "function" then pcall(compass.wp.setSizes, 0, 0) end
      if canMove == false and compass.wpX then removeObj(compass.wp); compass.wp = nil end
      compass.wpX = nil
      setText(compass.label, "")
    end

    -- flashing low HP warning (re-texted, not recreated)
    if lowHp and math.floor(os.epoch("utc") / 400) % 2 == 0 then
      setText(compass.low, "! LOW HP " .. lowHp .. " !")
    else
      setText(compass.low, "")
    end
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

  local function navigate(name, x, y, z, color)
    navTarget = { name = name, x = x, y = y, z = z }
    clearGroup("waypoint")
    groups.waypoint[name] = beacon(x, y, z, color or COLOR.waypoint, name)
  end

  ---------------------------------------------------------------------
  -- Block scanning
  ---------------------------------------------------------------------
  local blockTargets = nil   -- list of substrings, or nil
  local lastScan, lastScanAt = nil, 0

  local function scan()
    local fn = scanner and (scanner.scanBlocks or scanner.scan)
    if not fn then return nil, "no Geo Scanner" end
    if lastScan and os.epoch("utc") - lastScanAt < 1500 then return lastScan end
    local fx, fy, fz = myPos()
    if not fx then return nil, "position unknown" end
    local ok, res = pcall(fn, SCAN_RADIUS)
    if not ok or type(res) ~= "table" then return nil, "scanner busy" end
    local bx, by, bz = math.floor(fx), math.floor(fy + 0.001), math.floor(fz)
    local out = {}
    for _, b in ipairs(res) do
      if type(b.name) == "string" and b.x then
        out[#out + 1] = { name = b.name, tags = b.tags, x = bx + b.x, y = by + b.y, z = bz + b.z,
                          d = b.x * b.x + b.y * b.y + b.z * b.z }
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
          if (type(v) == "string" and v:find(t, 1, true)) or (type(k) == "string" and k:find(t, 1, true)) then
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
    local fx, fy, fz = myPos()
    local found, dists = {}, {}
    for _, p in pairs(try(detector.getPlayersInRange, PLAYER_RANGE) or {}) do
      local name = type(p) == "table" and p.name or p
      if type(name) == "string" then
        local info = try(detector.getPlayer, name)
        local exact
        if type(info) == "table" and info.x and fx then
          exact = math.sqrt((info.x - fx) ^ 2 + (info.y - fy) ^ 2 + (info.z - fz) ^ 2)
        end
        found[#found + 1] = { name = name, info = info, exact = exact }
        dists[name] = exact
      end
    end
    learnSelf(dists)
    local myName = me().name or SELF.name
    for _, f in ipairs(found) do
      local name, info, exact = f.name, f.info, f.exact
      local isMe = (myName and name:lower() == myName:lower()) or (exact and exact < 1.2)
      if not isMe then
        local dist = exact and math.floor(exact + 0.5) or "?"
        nearbyNames[#nearbyNames + 1] = name .. " " .. dist .. "m"
        local wanted = showPlayers and (not playerFilter)
        if showPlayers and playerFilter then
          for _, n in ipairs(playerFilter) do if n:lower() == name:lower() then wanted = true end end
        end
        if wanted and type(info) == "table" and info.x then
          local x, y, z = info.x - 0.35, info.y, info.z - 0.35
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
        relativePosition = true, x = -32, y = -32, z = -32,
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
    clearCompass()
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
    if navTarget then navigate(navTarget.name, navTarget.x, navTarget.y, navTarget.z) end
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
    "-- hud --",
    "ores       all ores",
    "count [blk] block tally",
    "highlight <blk..>",
    "nearest <blk>",
    "players [names]",
    "wp add/go/del/list <n>",
    "wp go back  pre-teleport",
    "stop dark bright",
    "clear [blocks|players]",
  }

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
    elseif cmd == "help" then for _, l in ipairs(HELP) do out(l) end
    elseif cmd == "count" then
      local blocks, err = scan()
      if not blocks then return say("can't scan: " .. tostring(err), COLOR.bad) end
      local tally, order = {}, {}
      for _, b in ipairs(blocks) do
        local ok
        if rest[1] then ok = matches(b, { rest[1] }) else ok = matches(b, ORES) end
        if ok then
          local n = plain(b.name)
          if not tally[n] then tally[n] = 0; order[#order + 1] = n end
          tally[n] = tally[n] + 1
        end
      end
      table.sort(order, function(a, b) return tally[a] > tally[b] end)
      if #order == 0 then return say("none within " .. SCAN_RADIUS, COLOR.warn) end
      for i = 1, math.min(#order, 10) do out(("%-20s %4d"):format(shorten(order[i], 20), tally[order[i]])) end
      say(("%d kinds counted"):format(#order), COLOR.good)
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
    elseif cmd == "wp" or cmd == "waypoint" then
      local sub, name = rest[1], rest[2]
      if sub == "add" and name then
        local x, y, z = myPos()
        if not x then return say("position unknown", COLOR.bad) end
        waypoints[name] = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
        saveWaypoints()
        say(("saved %s at %d %d %d"):format(name, waypoints[name].x, waypoints[name].y, waypoints[name].z), COLOR.good)
      elseif sub == "go" and name then
        local w = waypoints[name]
        if not w then return say("no waypoint " .. name, COLOR.warn) end
        navigate(name, w.x, w.y, w.z)
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
      return askAI(input) and true or false   -- false = not handled
    end
    return true
  end

  ---------------------------------------------------------------------
  -- Loops
  ---------------------------------------------------------------------
  local lastPos       -- for teleport / respawn detection + speed
  local lastHp
  local speed = 0
  local function infoLoop()
    while true do
      if hudShown then
        if try(overlay.getObjectsCount) == 0 and countObjects() > 0 then rebuildAll() end
        local o = me()
        local x, y, z = myPos()
        local t = os.epoch("utc")

        if x then
          if lastPos then
            local d2 = (x - lastPos.x) ^ 2 + (z - lastPos.z) ^ 2
            if d2 > 100 * 100 then
              -- teleport / respawn / long pearl: remember where you were
              waypoints.back = { x = math.floor(lastPos.x), y = math.floor(lastPos.y), z = math.floor(lastPos.z) }
              saveWaypoints()
              say("jumped! 'wp go back' returns", COLOR.warn)
            else
              local dt = (t - lastPos.t) / 1000
              local step = math.sqrt(d2)
              if dt > 0 then speed = speed * 0.5 + (step / dt) * 0.5 end
              STATS.dist = STATS.dist + step
              if speed > STATS.topSpeed and speed < 120 then STATS.topSpeed = speed end
            end
          end
          lastPos = { x = x, y = y, z = z, t = t }
        end

        local navBearing, navLabel
        if navTarget and x then
          local dx, dz = navTarget.x + 0.5 - x, navTarget.z + 0.5 - z
          local dist = math.floor(math.sqrt(dx * dx + dz * dz + (navTarget.y - y) ^ 2) + 0.5)
          local dy = navTarget.y - math.floor(y)
          if dist <= 2 then
            say("arrived at " .. navTarget.name, COLOR.good)
            navTarget = nil; clearGroup("waypoint")
          else
            navBearing = bearingTo(dx, dz)
            navLabel = ("%s  %dm%s"):format(navTarget.name, dist,
              dy > 1 and ("  +" .. dy) or (dy < -1 and ("  " .. dy) or ""))
          end
        end
        if o.health then
          if lastHp then
            if o.health < lastHp then STATS.dmg = STATS.dmg + (lastHp - o.health)
            elseif o.health > lastHp then STATS.heal = STATS.heal + (o.health - lastHp) end
            if o.health <= 0 and lastHp > 0 then STATS.deaths = STATS.deaths + 1 end
          end
          lastHp = o.health
        end
        local lowHp
        if o.health and o.health <= 6 then lowHp = ("%d/%d"):format(math.floor(o.health), math.floor(o.maxHealth or 20)) end
        drawCompass(o.yaw, navBearing, navLabel, lowHp)

        if x then set(hud.pos, ("%d %d %d"):format(math.floor(x), math.floor(y), math.floor(z))) end
        set(hud.face, o.yaw and ("%s  %d"):format(facingName(o.yaw), math.floor((o.yaw + 180) % 360)) or "?")
        local dim = myDimension()
        local showDim = dim ~= "?" and not dim:find("overworld")
        set(hud.spd, ("%.1f b/s%s"):format(speed, showDim and ("  " .. plainName(dim)) or ""),
            speed > 12 and COLOR.warn or COLOR.text)
        local act = {}
        if blockTargets then act[#act + 1] = "blocks" end
        if showPlayers then act[#act + 1] = "players" end
        if dark then act[#act + 1] = "dark" end
        if navTarget then act[#act + 1] = "nav" end
        set(hud.mode, #act > 0 and table.concat(act, "+") or "idle", #act > 0 and COLOR.good or COLOR.label)
        set(hud.clock, textutils.formatTime(os.time(), true))
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
      elseif handled == false then say("unknown: " .. line .. "  (type help)", COLOR.warn) end
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
      if opts.panelY then PANEL_Y = opts.panelY end
      loadWaypoints()
      rebuildAll()
    end
    function M.handle(line)
      local ok, handled = pcall(handle, line)
      if not ok then out("error: " .. tostring(handled), colours.red) return true end
      return handled ~= false
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
  "-- general --",
  "stats      session stats",
  "managers   list known",
  "ally add/del/list <n>",
  "me <name>  set your name",
  "uiscale <n> box width",
  "uiwidth <w> <h> screen",
  "uiinfo     screen info",
  "hide       hide all",
  "q          quit",
}

---------------------------------------------------------------------
-- Terminal layout (fits the glasses' small screen):
--   rows 1-3  live status bar
--   middle    scrolling log
--   last row  command input
---------------------------------------------------------------------
local TW, TH = term.getSize()
local function setupTerminal()
  if not window then return end
  local root = term.current()
  TERM.status = window.create(root, 1, 1, TW, 3)
  TERM.log    = window.create(root, 1, 4, TW, TH - 4)
  TERM.input  = window.create(root, 1, TH, TW, 1)
  TERM.log.setTextColour(colours.white)
end

local function drawStatus()
  local w = TERM.status
  if not w then return end
  local fg = term.isColour() and colours.white or colours.white
  w.setBackgroundColour(term.isColour() and colours.blue or colours.black)
  w.setCursorPos(1, 1); w.clearLine()
  w.setTextColour(colours.white); w.write(" EVIDENCE LOG")
  local rec = (math.floor(nowMs() / 700) % 2 == 0) and "* REC " or "  REC "
  w.setCursorPos(TW - #rec + 1, 1)
  w.setTextColour(term.isColour() and colours.red or fg); w.write(rec)

  w.setBackgroundColour(colours.black)
  local mc = 0
  for _ in pairs(currentManagers) do mc = mc + 1 end
  w.setCursorPos(1, 2); w.clearLine()
  w.setTextColour(colours.lightGrey); w.write("Inv ")
  w.setTextColour(invSource == "none" and colours.red or colours.lime); w.write(tostring(beforeTotal or "?"))
  w.setTextColour(colours.lightGrey); w.write(" Loss ")
  w.setTextColour(stats.suspect > 0 and colours.red or colours.white)
  w.write(stats.losses .. "/" .. stats.suspect)
  w.setTextColour(colours.lightGrey); w.write(" Mgr ")
  w.setTextColour(mc > 0 and colours.red or colours.white); w.write(mc .. "/" .. stats.managers)

  local near = nearbyList()
  w.setCursorPos(1, 3); w.clearLine()
  w.setTextColour(#near > 0 and colours.orange or colours.grey)
  w.write(shorten(#near > 0 and ("Near: " .. table.concat(near, ",")) or "Nobody near", TW))
end

local function statusLoop()
  while true do drawStatus(); sleep(0.5) end
end

local function prompt()
  if TERM.input then term.redirect(TERM.input); term.clear(); term.setCursorPos(1, 1) end
  term.setTextColour(colours.lightBlue); write("> "); term.setTextColour(colours.white)
end

local function inputLoop()
  local history = {}
  while true do
    prompt()
    local line = read(nil, history)
    if not line then return end
    if line ~= "" then history[#history + 1] = line end
    local words = {}
    for w in line:gmatch("%S+") do words[#words + 1] = w end
    local cmd = (words[1] or ""):lower()
    if cmd ~= "" then out("> " .. line, colours.lightBlue) end
    if cmd == "q" or cmd == "quit" then return
    elseif cmd == "mark" or cmd == "m" then mark("typed")
    elseif cmd == "summary" or cmd == "s" or cmd == "stats" then showStats()
    elseif cmd == "managers" or cmd == "mgrs" then listManagers()
    elseif cmd == "me" then
      if words[2] then setSelf(words[2]); out("you are " .. words[2], colours.lime)
      else
        local w = wearer()
        out("you are " .. tostring(myName() or "unknown"))
        out("glasses say: " .. tostring(w and w.name))
        out("learned: " .. tostring(SELF.name))
      end
    elseif cmd == "ally" then
      local sub, name = (words[2] or ""):lower(), words[3]
      if sub == "add" and name then allies[name:lower()] = true; saveAllies(); out("ally: " .. name, colours.lime)
      elseif sub == "del" and name then allies[name:lower()] = nil; saveAllies(); out("removed " .. name)
      else
        local l = {}
        for n in pairs(allies) do l[#l + 1] = n end
        table.sort(l)
        out(#l > 0 and ("allies: " .. table.concat(l, ", ")) or "no allies yet")
      end
    elseif cmd == "uiscale" then
      local v = tonumber(words[2])
      if v and v > 0.2 and v < 9 then
        UI.box = v
        local f = fs.open("/.glasses_box", "w"); f.write(tostring(v)); f.close()
        HUD.rebuild()
        if toolkit then toolkit.setShown(HUD.shown) end
        out("box scale " .. v .. " (saved)", colours.lime)
      else
        out("box scale " .. boxScale() .. (UI.box and " (set)" or " (auto)"))
        out("= your GUI scale normally")
      end
    elseif cmd == "uiinfo" then
      LAYOUT.compute()
      local r = LAYOUT.raw or {}
      out(("gui: %s x %s  scale %s"):format(tostring(r[1]), tostring(r[2]), tostring(r[3])))
      out(("using %d x %d"):format(LAYOUT.W, LAYOUT.H))
      out("box scale " .. boxScale())
    elseif cmd == "uiwidth" then
      local w, h = tonumber(words[2]), tonumber(words[3])
      if w and h then
        local f = fs.open("/.glasses_screen", "w"); f.write(w .. " " .. h); f.close()
      elseif fs.exists("/.glasses_screen") then fs.delete("/.glasses_screen") end
      HUD.rebuild()
      if toolkit then toolkit.setShown(HUD.shown) end
      out(w and ("screen set " .. w .. "x" .. h) or "screen: auto", colours.lime)
    elseif cmd == "hide" then
      HUD.shown = not HUD.shown; HUD.rebuild()
      if toolkit then toolkit.setShown(HUD.shown) end
      out(HUD.shown and "HUD shown" or "HUD hidden")
    elseif cmd == "help" or cmd == "?" then
      for _, l in ipairs(LOG_HELP) do out(l, colours.lightGrey) end
      if toolkit then for _, l in ipairs(toolkit.help) do out(l, colours.lightGrey) end
      else out("(no HUD tools: no Overlay?)", colours.orange) end
    elseif cmd ~= "" then
      if not (toolkit and toolkit.handle(line)) then
        out("unknown: " .. cmd .. " (help)", colours.orange)
      end
    end
  end
end

local function main()
  setupTerminal()
  HUD.started = nowMs()
  HUD.rebuild()
  local loops = { run, inputLoop, statusLoop }
  if toolkit then
    -- put the toolkit's panel under ours (and under the alert banner)
    toolkit.start({ panelY = HUD.leftBottom() })
    for _, l in ipairs(toolkit.loops) do loops[#loops + 1] = l end
  end
  out(SETTINGS.EVIDENCE and "Type 'help'. Hotkey = mark." or "Type 'help'. Hotkey = hide.", colours.lightGrey)
  parallel.waitForAny(table.unpack(loops))
end

term.clear(); term.setCursorPos(1, 1)
writeLog("START", ("you=%s scanner=%s detector=%s")
  :format(tostring(myName()), tostring(HW.scanner ~= nil), tostring(HW.detector ~= nil)))

local ok, err = pcall(main)
term.redirect(term.native()); term.setBackgroundColour(colours.black); term.clear(); term.setCursorPos(1, 1)
TERM.log = nil
if toolkit then toolkit.stop() end
if HW.overlay then try(HW.overlay.clear) end
writeLog("STOP", "stopped")
if not ok and err ~= "Terminated" then printError(err) end
