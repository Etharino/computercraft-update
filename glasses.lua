--[[
=====================================================================
  HELMET HUD   -   Smart Glasses (Advanced Peripherals 0.8)
=====================================================================
  Helmet-style HUD: reticle, target lock, stats readout, contacts,
  compass, altitude tape, ore / player highlights, waypoints, dark
  mode, Inventory Manager markers, and optional secure links to your
  base inventory (relay_base.lua) and ME system (me_link.lua).

  PUT IN THE GLASSES
    Required:     Overlay Module
    Recommended:  Geo Scanner (ores, managers), Player Detector
    Optional:     Hotkey Module (hide/show), Environment Detector,
                  ender modem + securelink.lua (for the links)

  START
    evidencelog               start
    evidencelog probe         check what the glasses can see
    evidencelog pair <key>    link to relay_base
    evidencelog mepair <key>  link to me_link
  Type 'help' on the glasses for every command.
=====================================================================
]]

local args = { ... }

---------------------------------------------------------------------
-- 1. SETTINGS
---------------------------------------------------------------------
local SETTINGS = {
  -- Where allies / known managers are saved (old folder name kept so
  -- your saved lists carry over)
  LOG_FOLDER        = "/evidence",

  -- How often things run (seconds)
  CHECK_INVENTORY   = 1,
  CHECK_PLAYERS     = 2,
  CHECK_MANAGERS    = 4,

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

-- HUD size. Overlay rectangles are drawn CENTRED on their x/y (rect()
-- below converts from a top-left corner), and every size in the layout is
-- multiplied by UI.size, with text drawn at fontSize = UI.size.
-- Change it live with:  uisize 0.6   (saved to /.glasses_size)
local UI = { size = 0.75 }
if fs.exists("/.glasses_size") then
  local f = fs.open("/.glasses_size", "r")
  local v = tonumber(f.readAll()); f.close()
  if v and v >= 0.4 and v <= 1.5 then UI.size = v end
end
local function U(n) return n * UI.size end
local LAYOUT   -- set up in section 5


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
  speed = 0, stacks = nil,             -- current speed, inventory stacks
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

-- ME system link (me_link.lua on your ME computer). Optional; same
-- securelink protection as the relay, with its own key and channel.
local ME_KEY_FILE = "/.me_key"
local MELINK = { ok = false, state = {}, status = nil, at = 0, nextId = 0, lastSeal = 0 }
do
  local link = RELAY.link
  if args[1] == "mepair" then
    local key = args[2] and args[2]:gsub("%s", "")
    if not link then
      print("securelink.lua is missing on the glasses. Download it first.")
    elseif not key or not link.keys(key) then
      print("Usage: evidencelog mepair <key from me_link setup>")
    else
      local f = fs.open(ME_KEY_FILE, "w"); f.write(key); f.close()
      print("ME linked. Channel " .. link.keys(key).channel .. ". Now run: evidencelog")
    end
    return
  end
  if link and HW.modem and fs.exists(ME_KEY_FILE) then
    local f = fs.open(ME_KEY_FILE, "r"); local key = (f.readAll() or ""):gsub("%s", ""); f.close()
    MELINK.keys = link.keys(key)
    if MELINK.keys then HW.modem.open(MELINK.keys.channel); MELINK.ok = true end
  end
end
local function meSend(tbl)
  if not MELINK.ok then return false end
  while os.epoch("utc") <= MELINK.lastSeal do sleep(0) end   -- one packet per ms
  local packet = RELAY.link.seal(MELINK.keys, textutils.serialize(tbl, { compact = true }))
  MELINK.lastSeal = packet.s
  HW.modem.transmit(MELINK.keys.channel, MELINK.keys.channel, packet)
  return true
end
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

---------------------------------------------------------------------
-- 4. SAVED DATA + TERMINAL NOTES (nothing is logged to a file)
---------------------------------------------------------------------
if not fs.exists(SETTINGS.LOG_FOLDER) then fs.makeDir(SETTINGS.LOG_FOLDER) end

local stats = { managers = 0 }

local function note(kind, message)
  local kc = ({ MANAGER = colours.yellow, PLAYER = colours.orange, TAMPER = colours.red })[kind]
             or colours.lightGrey
  out(shorten(os.date("%H:%M") .. " " .. kind .. " " .. message, 52), kc)
end

---------------------------------------------------------------------
-- 5. HUD  (panel, alert banner, 3D markers)
---------------------------------------------------------------------
local HELM_BUILD, HELM_TICK   -- helmet theme hooks (section 5b)
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
-- MekaSuit-helmet style: thin glowing cyan text straight over the world,
-- no panels. Change the colour here if you like.
-- Themes: "helmet" (ice-blue readouts, gold frame, red threats) or
-- "meka" (all cyan). Switch live with:  theme helmet   /   theme meka
local THEMES = {
  helmet = { main = 0x9BE8FF, dim = 0x4FA3C4, faint = 0x1E4F63, gold = 0xFFB43C, red = 0xFF3B30 },
  meka   = { main = 0x3CF0E6, dim = 0x2A9C96, faint = 0x184B48, gold = 0x3CF0E6, red = 0xFF4D4D },
}
local THEME = "helmet"
if fs.exists("/.glasses_theme") then
  local f = fs.open("/.glasses_theme", "r"); local v = f.readAll(); f.close()
  if THEMES[v] then THEME = v end
end
local MEKA = {}
local function applyTheme(name)
  THEME = name
  for k, v in pairs(THEMES[name]) do MEKA[k] = v end
end
applyTheme(THEME)

local SLINES = { "hp", "inv", "spd", "dist", "ores", "mgr" }
local LABELS = { hp = "HP", inv = "INV", spd = "SPD", dist = "DIST", ores = "ORES", mgr = "MGR", me = "ME" }
if MELINK.ok then SLINES[#SLINES + 1] = "me" end
local BAR_SEGS = 12
local rowValues = {}

local function removeObject(o)
  if o and HW.overlay then
    local id = try(o.getId) or o.id
    if id then pcall(HW.overlay.removeObject, id) end
  end
end

-- Overlay rectangles are CENTRED on (x, y). This takes a top-left corner.
local function rect(x, y, w, h, color, opacity)
  return try(HW.overlay.createRectangle, {
    gui = true, x = x + w / 2, y = y + h / 2, sizeX = w, sizeY = h,
    color = color, opacity = opacity,
  })
end

local function text(x, y, content, color)
  return try(HW.overlay.createText, {
    gui = true, x = x, y = y, content = content, color = color, shadow = true, fontSize = UI.size,
  })
end

local function setText(obj, content)
  return obj and type(obj.setContent) == "function" and pcall(obj.setContent, content)
end

local function setColor(obj, color)
  if obj and type(obj.setColor) == "function" then pcall(obj.setColor, color) end
end

-- Moving an existing object: overlay objects animate from 0 when they are
-- CREATED, so things that change are created once and moved in place.
local function moveX(obj, x)
  if not obj then return false end
  if type(obj.setX) == "function" then return (pcall(obj.setX, x)) end
  return false
end
local function moveXY(obj, x, y)
  if not obj then return false end
  if type(obj.setX) == "function" and type(obj.setY) == "function" then
    return (pcall(obj.setX, x)) and (pcall(obj.setY, y))
  end
  if type(obj.setPosition) == "function" then return (pcall(obj.setPosition, x, y)) end
  return false
end

local function LH() return U(11) end
local CONTACT_ROWS = 4

function HUD.build()
  if not HW.overlay then return end
  LAYOUT.compute()
  local P = HUD.parts
  local x, y = U(10), U(9)
  -- corner bracket
  P.br1 = rect(U(3), U(3), U(12), U(1), MEKA.main, 0.9)
  P.br2 = rect(U(3), U(3), U(1), U(12), MEKA.main, 0.9)
  local valX = x + U(30)
  for i, key in ipairs(SLINES) do
    local ly = y + (i - 1) * LH()
    P["l_" .. key] = text(x, ly, LABELS[key], MEKA.dim)
    local rv = rowValues[key]
    if key == "hp" or key == "inv" then
      -- number first, bar after it: nothing to the right of the bar can collide
      P["v_" .. key]  = text(valX, ly, rv and rv[1] or "", rv and rv[2] or MEKA.main)
      P["bb_" .. key] = text(valX + U(34), ly, string.rep("|", BAR_SEGS), MEKA.faint)
      P["bf_" .. key] = text(valX + U(34), ly, rv and rv.bar or "", rv and rv[2] or MEKA.main)
    else
      P["v_" .. key]  = text(valX, ly, rv and rv[1] or "-", rv and rv[2] or MEKA.main)
    end
  end
  HUD.listBottom = y + #SLINES * LH()

  -- contacts, right under the readout
  local cy = HUD.listBottom + U(6)
  local cl = {}
  cl[1] = rect(x, cy - U(2), U(110), U(1), MEKA.faint, 0.9)
  cl[2] = text(x, cy, "CONTACTS", MEKA.dim)
  HUD.cpool = { title = cl[2], rows = {} }
  HUD.cpool.count = text(x + U(52), cy, "0", MEKA.main)
  cl[#cl + 1] = HUD.cpool.count
  for i = 1, CONTACT_ROWS do
    local ry = cy + i * LH()
    local r = {
      arrow = text(x, ry, "", MEKA.main),
      name  = text(x + U(9), ry, i == 1 and "all clear" or "", MEKA.dim),
      dist  = text(x + U(88), ry, "", MEKA.main),
    }
    HUD.cpool.rows[i] = r
    cl[#cl + 1] = r.arrow; cl[#cl + 1] = r.name; cl[#cl + 1] = r.dist
  end
  HUD.contacts = cl
  if HELM_BUILD then HELM_BUILD() end
end
function HUD.leftBottom() return HUD.listBottom or U(80) end

function HUD.row(key, value, color)
  value = shorten(value, 20)
  local rv = rowValues[key] or {}
  rv[1], rv[2] = value, color or MEKA.main
  rowValues[key] = rv
  local obj = HUD.parts["v_" .. key]
  if obj then setText(obj, value); setColor(obj, rv[2]) end
end

-- charge-style bar: frac 0..1
function HUD.bar(key, frac, value, color)
  local n = math.max(0, math.min(BAR_SEGS, math.floor((frac or 0) * BAR_SEGS + 0.5)))
  local bar = string.rep("|", n)
  HUD.row(key, value, color)
  rowValues[key].bar = bar
  local obj = HUD.parts["bf_" .. key]
  if obj then setText(obj, bar); setColor(obj, color or MEKA.main) end
end

-- list: { { name, dist, arrow, ally }, ... }  -> updates the fixed rows
function HUD.drawContacts(list)
  local cp = HUD.cpool
  if not cp then return end
  local hostile = 0
  for _, c in ipairs(list) do if not c.ally then hostile = hostile + 1 end end
  setText(cp.count, tostring(#list)); setColor(cp.count, hostile > 0 and COLOR.bad or MEKA.main)
  for i = 1, CONTACT_ROWS do
    local r, c = cp.rows[i], list[i]
    if c then
      local col = c.ally and COLOR.good or COLOR.warn
      if not c.ally and c.dist and c.dist <= SETTINGS.ALERT_RANGE then col = COLOR.bad end
      local d = c.dist and (math.floor(c.dist) .. "m") or "?"
      if i == CONTACT_ROWS and #list > CONTACT_ROWS then d = "+" .. (#list - CONTACT_ROWS + 1) end
      setText(r.arrow, c.arrow); setColor(r.arrow, col)
      setText(r.name, shorten(c.name, 13)); setColor(r.name, col)
      setText(r.dist, d)
    else
      setText(r.arrow, "")
      setText(r.name, (i == 1 and #list == 0) and "all clear" or ""); setColor(r.name, MEKA.dim)
      setText(r.dist, "")
    end
  end
end

-- Toast just above the crosshair: [ message ] with thin cyan brackets
function HUD.alert(message, color)
  HUD.alertUntil = nowMs() + SETTINGS.ALERT_SECONDS * 1000
  if not HW.overlay then return end
  try(HW.overlay.setAutoUpdate, false)
  for _, o in ipairs(HUD.toast) do removeObject(o) end
  HUD.toast = {}
  if HUD.shown then
    local msg = shorten(tostring(message), 40)
    local w, h = #msg * U(6) + U(12), U(13)
    local x, y = LAYOUT.W / 2 - w / 2, LAYOUT.H / 2 - 26 - h
    color = color or COLOR.bad
    HUD.toast[#HUD.toast + 1] = rect(x, y, w, h, 0x000000, 0.35)
    HUD.toast[#HUD.toast + 1] = rect(x, y, U(1), h, MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = rect(x + w - U(1), y, U(1), h, MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = rect(x, y, U(4), U(1), MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = rect(x, y + h - U(1), U(4), U(1), MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = rect(x + w - U(4), y, U(4), U(1), MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = rect(x + w - U(4), y + h - U(1), U(4), U(1), MEKA.gold, 1)
    HUD.toast[#HUD.toast + 1] = text(x + U(6), y + U(3), msg, color)
  end
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
end

function HUD.tick()
  if HELM_TICK then HELM_TICK() end
  if #HUD.toast > 0 and nowMs() > HUD.alertUntil then
    for _, o in ipairs(HUD.toast) do removeObject(o) end
    HUD.toast = {}
  end
end

local function markerBoxes(x, y, z, distance)
  local list = {}
  local function box(size, color, opacity)
    -- boxes are drawn centred on x/y/z: use the middle of the block
    local bx, by, bz = x + 0.5, y + 0.5, z + 0.5
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
-- 5b. HELMET HUD  (theme "helmet")
-- Spinning reticle, lock-on brackets, altitude tape, status strip,
-- faceplate edges that flash red when you take damage, and a boot-up
-- sequence. Everything is created ONCE in HELM.build and afterwards only
-- moved / re-texted / re-coloured (new objects fly in from 0).
---------------------------------------------------------------------
local HELM = { spin = 0, lockR = nil, booted = false, bootStep = 0, canMove = nil,
               target = nil, hp = nil, maxHp = 20, lastHp = nil, hurt = 0, y = nil }
local RET_DOTS, TAPE_TICKS, BOOT_STEPS = 12, 9, 18
local ARC_DOTS, ARC_COUNT = 5, 3          -- outer ring: 3 arcs of 5 dots
local OUTER_R, INNER_R = 27, 16

-- rectangle by its CENTRE
local function crect(x, y, w, h, color, opacity)
  return rect(x - w / 2, y - h / 2, w, h, color, opacity)
end

local function helmMove(obj, x, y)
  if HELM.canMove == false or not obj then return false end
  local ok = moveXY(obj, x, y)
  if HELM.canMove == nil then HELM.canMove = ok end
  return ok
end

local CORNERS = { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }
local BRACKET_LEN = 6

local function bracketSpots(R)
  local cx, cy, L = LAYOUT.W / 2, LAYOUT.H / 2, U(BRACKET_LEN)
  local spots = {}
  for i, s in ipairs(CORNERS) do
    local px, py = cx + s[1] * R, cy + s[2] * R
    spots[i] = { hx = px - s[1] * L / 2, hy = py, vx = px, vy = py - s[2] * L / 2 }
  end
  return spots
end

local function ringSpot(i, cx, cy, r)
  local a = math.rad(i * 360 / RET_DOTS + HELM.spin)
  return cx + r * math.sin(a), cy - r * math.cos(a)
end

local function arcSpot(a, i, cx, cy)
  -- arc a (1..3), dot i (1..5): arcs are 80 degrees long, 40 degree gaps
  local ang = math.rad((a - 1) * 120 + (i - 1) * 20 - HELM.spin * 0.6)
  local r = U(OUTER_R)
  return cx + r * math.sin(ang), cy - r * math.cos(ang)
end

function HELM.build()
  if THEME ~= "helmet" or not HW.overlay then return end
  local P = HUD.parts
  local W, H = LAYOUT.W, LAYOUT.H
  local cx, cy = W / 2, H / 2

  -- reticle: inner ring of dots that slowly spins
  for i = 1, RET_DOTS do
    local x, y = ringSpot(i, cx, cy, U(INNER_R))
    local d = (i % 3 == 0) and U(1.8) or U(1)
    P["h_rd" .. i] = crect(x, y, d, d, MEKA.main, (i % 3 == 0) and 0.9 or 0.55)
  end
  -- lock-on brackets (start wide during boot, then close in)
  HELM.lockR = HELM.booted and U(30) or U(70)
  local L = U(BRACKET_LEN)
  for i, s in ipairs(bracketSpots(HELM.lockR)) do
    P["h_bh" .. i] = crect(s.hx, s.hy, L, U(1), MEKA.gold, 0.9)
    P["h_bv" .. i] = crect(s.vx, s.vy, U(1), L, MEKA.gold, 0.9)
  end
  -- target readout under the reticle
  P.h_tgt = text(cx - U(36), cy + U(38), "", MEKA.red)

  -- faceplate edges, left and right
  local eh = H * 0.5
  P.h_el = crect(U(2), cy, U(1), eh, MEKA.faint, 0.8)
  P.h_er = crect(W - U(2), cy, U(1), eh, MEKA.faint, 0.8)
  P.h_elt = crect(U(4), cy - eh / 2, U(5), U(1), MEKA.gold, 0.8)
  P.h_elb = crect(U(4), cy + eh / 2, U(5), U(1), MEKA.gold, 0.8)
  P.h_ert = crect(W - U(4), cy - eh / 2, U(5), U(1), MEKA.gold, 0.8)
  P.h_erb = crect(W - U(4), cy + eh / 2, U(5), U(1), MEKA.gold, 0.8)

  -- altitude tape, right side (ticks scroll as you climb)
  local tx = W - U(14)
  for k = 1, TAPE_TICKS do
    P["h_tk" .. k] = crect(tx, cy + (k - 5) * U(7), U(6), U(1), MEKA.dim, 1)
  end
  P.h_tptr = text(tx - U(9), cy - U(4), "<", MEKA.gold)
  P.h_alt  = text(tx - U(42), cy - U(4), "", MEKA.main)

  -- status strip, top centre
  -- (above the hotbar / held-item name, clear of Jade and boss bars)
  local sy = H - 82
  P.h_sl = crect(cx - U(82), sy + U(4), U(22), U(1), MEKA.gold, 0.9)
  P.h_sr = crect(cx + U(82), sy + U(4), U(22), U(1), MEKA.gold, 0.9)
  P.h_st = text(cx - U(66), sy, "", MEKA.main)

  -- outer ring: three arcs that spin the other way
  for a = 1, ARC_COUNT do
    for i = 1, ARC_DOTS do
      local x, y = arcSpot(a, i, cx, cy)
      local d = (i == 1 or i == ARC_DOTS) and U(1.6) or U(1)
      P["h_ar" .. a .. "_" .. i] = crect(x, y, d, d, (i == 1 or i == ARC_DOTS) and MEKA.main or MEKA.dim, 0.85)
    end
  end
  -- threat pointer: red pip + trail riding the outer ring toward the target
  for k = 1, 3 do
    P["h_tp" .. k] = crect(-50, -50, U(4.5 - k), U(4.5 - k), MEKA.red, 1 - k * 0.22)   -- parked off-screen
  end
  -- pitch ladder: two short bars either side that slide with your view
  for _, side in ipairs({ -1, 1 }) do
    local key = side < 0 and "l" or "r"
    P["h_pl" .. key] = crect(cx + side * U(46), cy, U(14), U(1), MEKA.main, 0.85)
    P["h_pe" .. key] = crect(cx + side * U(53), cy + U(2), U(1), U(4), MEKA.main, 0.85)
  end
  P.h_pv = text(cx + U(62), cy - U(4), "", MEKA.dim)
  -- horizon marks (fixed) so the ladder has something to move against
  P.h_hl = crect(cx - U(66), cy, U(4), U(1), MEKA.gold, 0.9)
  P.h_hr = crect(cx + U(66), cy, U(4), U(1), MEKA.gold, 0.9)

  -- radar sweep: faint line that rolls down the visor
  P.h_sw = crect(cx, cy, W - U(16), U(1), MEKA.main, 0.12)
  HELM.sweepY = 0

  -- frame corners on all four screen corners
  local m, L2 = U(2), U(16)
  HELM.corners = {}
  for i, c in ipairs({ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }) do
    local x = c[1] == 0 and m or W - m
    local y = c[2] == 0 and m or H - m
    local sx = c[1] == 0 and 1 or -1
    local sy = c[2] == 0 and 1 or -1
    P["h_fh" .. i] = crect(x + sx * L2 / 2, y, L2, U(1), MEKA.gold, 0.9)
    P["h_fv" .. i] = crect(x, y + sy * L2 / 2, U(1), L2, MEKA.gold, 0.9)
  end
  P.h_imp = text(cx - U(22), cy + U(50), "", MEKA.red)

  -- boot text
  P.h_boot = text(cx - U(55), cy + U(52), "", MEKA.main)
  P.h_bbar = text(cx - U(55), cy + U(63), "", MEKA.gold)
end

local function sensorsText()
  local s = {}
  if HW.detector then s[#s + 1] = "PLR" end
  if HW.scanner  then s[#s + 1] = "GEO" end
  if HW.manager  then s[#s + 1] = "INV" end
  if HW.env      then s[#s + 1] = "ENV" end
  if HW.modem    then s[#s + 1] = "LINK" end
  return #s > 0 and table.concat(s, " ") or "NONE"
end

local function bootLine(step)
  if step <= 3  then return "BOOTING HUD" .. string.rep(".", step) end
  if step <= 6  then return "CALIBRATING OPTICS" end
  if step <= 9  then return "SENSORS: " .. sensorsText() end
  if step <= 12 then return "TARGETING ONLINE" end
  if step <= 14 then return "ALL SYSTEMS ONLINE" end
  return "WELCOME BACK, " .. string.upper(myName() or "PILOT")
end

local helmTickInner
function HELM.tick()
  if THEME ~= "helmet" or not HUD.parts.h_st then return end
  try(HW.overlay.setAutoUpdate, false)
  local ok, err = pcall(helmTickInner)
  try(HW.overlay.update); try(HW.overlay.setAutoUpdate, true)
  if not ok then error(err, 0) end
end

function helmTickInner()
  local P = HUD.parts
  local W, H = LAYOUT.W, LAYOUT.H
  local cx, cy = W / 2, H / 2

  -- boot sequence
  if not HELM.booted then
    HELM.bootStep = HELM.bootStep + 1
    if HELM.bootStep > BOOT_STEPS then
      HELM.booted = true
      setText(P.h_boot, ""); setText(P.h_bbar, "")
    else
      setText(P.h_boot, bootLine(HELM.bootStep))
      setText(P.h_bbar, string.rep("|", math.min(HELM.bootStep, 14)))
    end
  end

  -- spinning ring (fast while booting)
  if HELM.canMove ~= false then
    HELM.spin = (HELM.spin + (HELM.booted and 6 or 30)) % 360
    for i = 1, RET_DOTS do
      local x, y = ringSpot(i, cx, cy, U(INNER_R))
      helmMove(P["h_rd" .. i], x, y)
    end
    for a = 1, ARC_COUNT do
      for i = 1, ARC_DOTS do
        local x, y = arcSpot(a, i, cx, cy)
        helmMove(P["h_ar" .. a .. "_" .. i], x, y)
      end
    end
    -- radar sweep
    local top, span = H * 0.18, H * 0.64
    HELM.sweepY = (HELM.sweepY + (HELM.booted and 0.03 or 0.12)) % 1
    helmMove(P.h_sw, cx, top + span * HELM.sweepY)
  end

  -- pitch ladder (needs pitch from the glasses)
  local pitch = HELM.pitch
  if pitch and HELM.canMove ~= false then
    local off = math.max(-U(60), math.min(U(60), pitch * U(1.2)))
    for _, side in ipairs({ -1, 1 }) do
      local key = side < 0 and "l" or "r"
      helmMove(P["h_pl" .. key], cx + side * U(46), cy - off)
      helmMove(P["h_pe" .. key], cx + side * U(53), cy - off + (pitch >= 0 and U(2) or -U(2)))
    end
    setText(P.h_pv, ("%+d"):format(math.floor(-pitch + 0.5)))
  end

  -- target lock
  local t = HELM.target
  local locked = t and t.dist and t.dist <= SETTINGS.ALERT_RANGE
  local want = (not HELM.booted) and U(30) or (locked and U(19) or U(30))
  local R = HELM.lockR + (want - HELM.lockR) * 0.45
  if math.abs(R - want) < U(0.4) then R = want end
  if math.abs(R - HELM.lockR) > 0.01 or not HELM.placed then
    for i, s in ipairs(bracketSpots(R)) do
      helmMove(P["h_bh" .. i], s.hx, s.hy)
      helmMove(P["h_bv" .. i], s.vx, s.vy)
    end
    HELM.placed = true
  end
  HELM.lockR = R
  local bc = locked and MEKA.red or MEKA.gold
  if bc ~= HELM.bracketColor then
    for i = 1, 4 do setColor(P["h_bh" .. i], bc); setColor(P["h_bv" .. i], bc) end
    HELM.bracketColor = bc
  end
  if t and HELM.booted then
    local blink = locked and math.floor(nowMs() / 300) % 2 == 0
    setText(P.h_tgt, ("%s %s %dm"):format(locked and (blink and "LOCK" or "    ") or "TRACK",
      shorten(t.name, 12), math.floor((t.dist or 0) + 0.5)))
    setColor(P.h_tgt, locked and MEKA.red or MEKA.gold)
  else
    setText(P.h_tgt, "")
  end

  -- threat pointer around the outer ring
  local tp = t and t.pos and HELM.yaw and HELM.px and HELM.booted
  if tp then
    local bearing = (math.deg((math.atan2 or math.atan)(-(t.pos.x - HELM.px), t.pos.z - HELM.pz)) + 360) % 360
    local th = math.rad((bearing - HELM.yaw + 540) % 360 - 180)
    for k = 1, 3 do
      local r = U(OUTER_R + 2 + k * 3)
      helmMove(P["h_tp" .. k], cx + r * math.sin(th), cy - r * math.cos(th))
    end
  end
  if not tp and HELM.tpShown then
    for k = 1, 3 do helmMove(P["h_tp" .. k], -50, -50) end
  end
  HELM.tpShown = tp

  -- damage flash on the faceplate edges
  if HELM.hp and HELM.lastHp and HELM.hp < HELM.lastHp - 0.5 then HELM.hurt = 3 end
  HELM.lastHp = HELM.hp
  local ec = HELM.hurt > 0 and MEKA.red or MEKA.faint
  if ec ~= HELM.edgeColor then
    setColor(P.h_el, ec); setColor(P.h_er, ec); HELM.edgeColor = ec
    local fc = HELM.hurt > 0 and MEKA.red or MEKA.gold
    for i = 1, 4 do setColor(P["h_fh" .. i], fc); setColor(P["h_fv" .. i], fc) end
  end
  setText(P.h_imp, (HELM.hurt > 0 and HELM.hurt % 2 == 1) and "! IMPACT !" or "")
  if HELM.hurt > 0 then HELM.hurt = HELM.hurt - 1 end

  -- altitude tape
  if HELM.y then
    local fy = math.floor(HELM.y)
    local frac = HELM.y - fy
    for k = 1, TAPE_TICKS do
      local block = fy + (5 - k)            -- tick 5 = your level
      if HELM.canMove ~= false then
        helmMove(P["h_tk" .. k], W - U(14), cy + (k - 5) * U(7) + frac * U(7))
      end
      setColor(P["h_tk" .. k], (block % 5 == 0) and MEKA.gold or MEKA.dim)
    end
    setText(P.h_alt, ("ALT %d"):format(fy))
  end

  -- status strip
  local pwr = HELM.hp and math.floor(HELM.hp / (HELM.maxHp or 20) * 100 + 0.5)
  local sys, col = "SYS OK", MEKA.main
  if pwr and pwr <= 30 then sys, col = "SYS CRIT", MEKA.red
  elseif (pwr and pwr <= 60) or locked then sys, col = "SYS WARN", MEKA.gold end
  setText(P.h_st, ("PWR %s  %s  %s"):format(pwr and (pwr .. "%") or "--", sys,
    textutils.formatTime(os.time(), true)))
  setColor(P.h_st, col)
end

HELM_BUILD, HELM_TICK = HELM.build, HELM.tick

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
          note("PLAYER", ("%s came within %dm"):format(n, math.floor(dist)))
          HUD.alert(("%s is %dm away"):format(n, math.floor(dist)), COLOR.warn)
        elseif dist > SETTINGS.ALERT_RANGE + 8 then
          playerState[n] = nil
        end
      end
    end
  end
  for n in pairs(playerState) do if not seenNow[n] then playerState[n] = nil end end
  -- nearest non-ally for the helmet's target lock
  local best
  for n in pairs(seenNow) do
    local d = playerDist[n]
    if d and not allies[n:lower()] and (not best or d < best.dist) then best = { name = n, dist = d, pos = playerPos[n] } end
  end
  HELM.target = best
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
        note("MANAGER", ("new at %d %d %d (%dm)"):format(b.x, b.y, b.z, math.floor(math.sqrt(b.d or 0))))
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
  elseif count == 0 then
    inManagerArea = false
  end
  currentManagers = found
  HUD.setMarkers(found)
end

---------------------------------------------------------------------
-- 9. INVENTORY STATS
---------------------------------------------------------------------
local before, beforeTotal

local function checkInventory()
  local list = readInventory()
  if not list then return end
  STATS.stacks = #list
  local now, total = countItems(list)
  if before then
    -- stats: items gained / used this session
    for name, has in pairs(now) do
      local had = before[name] or 0
      if has > had then STATS.gained = STATS.gained + (has - had) end
    end
    for name, had in pairs(before) do
      local has = now[name] or 0
      if has < had then STATS.used = STATS.used + (had - has) end
    end
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

  -- HP bar
  local hp, maxHp = w and w.health, (w and w.maxHealth) or 20
  HELM.hp, HELM.maxHp = hp, maxHp
  HELM.yaw, HELM.pitch, HELM.px, HELM.pz = yaw, w and w.pitch, x, z
  do local _, py = myPosition(); HELM.y = py end
  if hp then
    HUD.bar("hp", hp / maxHp, ("%d/%d"):format(math.floor(hp), math.floor(maxHp)),
            hp <= 6 and COLOR.bad or (hp <= 12 and COLOR.warn or MEKA.main))
  else
    HUD.bar("hp", 0, "?", MEKA.dim)
  end
  -- inventory fill bar (36 slots + armour + offhand)
  if STATS.stacks then
    HUD.bar("inv", STATS.stacks / 41, ("%d/41"):format(STATS.stacks),
            STATS.stacks >= 36 and COLOR.warn or MEKA.main)
  else
    HUD.bar("inv", 0, "no detector", MEKA.dim)
  end

  local up = math.floor((nowMs() - STATS.started) / 1000)
  HUD.row("spd", ("%.1f b/s  top %.0f"):format(STATS.speed or 0, STATS.topSpeed),
          (STATS.speed or 0) > 12 and COLOR.warn or MEKA.main)
  HUD.row("dist", ("%s  %dh %02dm"):format(fmtDist(STATS.dist), math.floor(up / 3600), math.floor(up / 60) % 60))
  if not HW.scanner then
    HUD.row("ores", "no scanner", MEKA.dim)
  else
    local best = STATS.bestOre and STATS.bestOre:gsub("ancient_", "")
    HUD.row("ores", STATS.oresNear .. (best and ("  " .. best) or ""),
            (best and (best:find("diamond") or best:find("debris") or best:find("emerald"))) and COLOR.good or MEKA.main)
  end

  -- managers: how many here + nearest one's distance and direction
  local mc, nearest = 0, nil
  for _, m in pairs(currentManagers) do
    mc = mc + 1
    if not nearest or m.dist < nearest.dist then nearest = m end
  end
  if not HW.scanner then
    HUD.row("mgr", "no scanner", MEKA.dim)
  elseif nearest then
    HUD.row("mgr", ("%d here %dm %s"):format(mc, math.floor(nearest.dist), arrowTo(nearest.x + 0.5, nearest.z + 0.5)), COLOR.bad)
  else
    HUD.row("mgr", stats.managers .. " known", MEKA.main)
  end

  -- ME system
  if MELINK.ok then
    local st = MELINK.status
    if not st or nowMs() - MELINK.at > 20000 then
      HUD.row("me", st and "link lost" or "waiting...", MEKA.dim)
    elseif not st.online then
      HUD.row("me", "OFFLINE", COLOR.bad)
    else
      local function short(n)
        if n >= 1e6 then return ("%.1fM"):format(n / 1e6) elseif n >= 1e3 then return ("%.1fk"):format(n / 1e3) end
        return tostring(math.floor(n))
      end
      local txt = short(st.total or 0)
      local col = MEKA.main
      if st.used and st.cap and st.cap > 0 then
        local pct = math.floor(st.used / st.cap * 100)
        txt = txt .. "  " .. pct .. "%"
        if pct >= 90 then col = COLOR.warn end
      end
      if st.energy and st.maxEnergy and st.maxEnergy > 0 then
        local e = math.floor(st.energy / st.maxEnergy * 100)
        txt = txt .. "  pwr " .. e .. "%"
        if e <= 10 then col = COLOR.bad end
      end
      HUD.row("me", txt, col)
    end
  end

  -- contacts
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
  print("HELMET HUD - hardware check")
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
    elseif event == "modem_message" and MELINK.ok and b == MELINK.keys.channel then
      local plainText = RELAY.link.open(MELINK.keys, MELINK.state, ev[5])
      local msg = plainText and textutils.unserialize(plainText)
      if type(msg) == "table" then
        if msg.t == "status" then
          MELINK.status, MELINK.at = msg, nowMs()
        elseif msg.t == "drop" then
          local first = msg.items and msg.items[1]
          local what = first and (first.count .. " " .. first.name) or "items"
          HUD.alert(("ME -%d  %s%s"):format(msg.total or 0, what,
            (msg.near and msg.near ~= "nobody") and ("  (" .. msg.near .. ")") or ""),
            msg.valuable and COLOR.bad or COLOR.warn)
          out(("ME -%d taken, near: %s"):format(msg.total or 0, tostring(msg.near or "?")), colours.orange)
          for _, it in ipairs(msg.items or {}) do out(("  -%d %s"):format(it.count, it.name), colours.orange) end
        elseif msg.t == "reply" then
          if (msg.matches or 0) == 0 then
            out("ME: no '" .. tostring(msg.q) .. "'", colours.orange)
            HUD.alert("ME: none found", COLOR.warn)
          else
            out(("ME '%s': %d match%s"):format(msg.q, msg.matches, msg.matches == 1 and "" or "es"), colours.yellow)
            for _, r in ipairs(msg.results or {}) do
              out(("%7d %s"):format(r.count, shorten(r.name, 17)))
            end
            local top = msg.results[1]
            HUD.alert(("ME: %d %s"):format(top.count, shorten(top.name, 20)), MEKA.main)
          end
        end
      end
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
          note("TAMPER", ("rejected %s packet on relay channel (%d rejected so far)")
            :format(why, RELAY.rejected))
          HUD.alert("Fake relay packet blocked (" .. why .. ")", COLOR.bad)
        end
      end
    elseif event == "glasses_key_pressed" then
      HUD.shown = not HUD.shown; HUD.rebuild()
      if toolkit then toolkit.setShown(HUD.shown) end
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

  -- Takes the box's minimum corner; the overlay draws boxes CENTRED on
  -- x/y/z, so convert corner -> centre here.
  local function box(x, y, z, sx, sy, sz, color, opacity)
    return try(overlay.createBox, {
      x = x + sx / 2, y = y + sy / 2, z = z + sz / 2, sizeX = sx, sizeY = sy, sizeZ = sz,
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
  local PANEL_X, PANEL_Y = U(4), 80

  -- Bottom-left: round compass with your coordinates inside (MekaSuit
  -- style). Kept above Mekanism's own bottom-left HUD text.
  local buildCompass   -- defined with the compass code below
  local function ring()
    local R = U(38)
    local cx = U(14) + R
    local cy = LAYOUT.H - 44 - U(16) - R
    return cx, cy, R
  end

  local function buildHud()
    for _, o in pairs(hud) do removeObj(o) end
    hud = {}
    if not hudShown then return end
    local cx, cy, R = ring()
    try(overlay.setAutoUpdate, false)
    for i = 0, 35 do
      local a = math.rad(i * 10)
      local d = (i % 3 == 0) and U(1.6) or U(1)
      hud["r" .. i] = rect(cx + R * math.sin(a) - d / 2, cy - R * math.cos(a) - d / 2, d, d,
                           (i % 3 == 0) and MEKA.main or MEKA.dim, 0.9)
    end
    hud.top  = rect(cx - U(0.5), cy - R - U(7), U(1), U(5), MEKA.main, 1)   -- you face here
    hud.cx   = text(cx - U(16), cy - U(15), "", MEKA.main)
    hud.cy   = text(cx - U(16), cy - U(4), "", MEKA.main)
    hud.cz   = text(cx - U(16), cy + U(7), "", MEKA.main)
    hud.face = text(cx - R, cy + R + U(6), "", MEKA.main)
    hud.mode = text(cx + R + U(10), cy + U(8), "", MEKA.dim)
    try(overlay.update); try(overlay.setAutoUpdate, true)
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

  -- Compass letters ride around the ring as you turn. Created ONCE and
  -- moved with setters (new objects fly in from 0). Builds without setters
  -- re-place them only when your heading changes by a few degrees.
  local compass = nil
  local LETTERS = { { a = 180, l = "N" }, { a = 270, l = "E" }, { a = 0, l = "S" }, { a = 90, l = "W" } }
  local canMove = nil
  local lastYawKey = nil

  local function clearCompass()
    if not compass then return end
    for _, m in ipairs(compass.marks) do removeObj(m.obj) end
    removeObj(compass.wp); removeObj(compass.label); removeObj(compass.low)
    compass = nil
  end

  local function letterColor(l) return l == "N" and COLOR.bad or MEKA.main end

  function buildCompass()
    clearCompass()
    if not hudShown then return end
    local cx, cy, R = ring()
    compass = { marks = {} }
    for i, m in ipairs(LETTERS) do
      compass.marks[i] = { a = m.a, l = m.l, obj = text(cx, cy, "", letterColor(m.l)) }
    end
    compass.label = text(cx + R + U(10), cy - U(14), "", COLOR.waypoint)
    compass.low   = text(LAYOUT.W / 2 - U(40), LAYOUT.H / 2 + 12, "", COLOR.bad)
    lastYawKey = nil
  end

  local function setXY(obj, x, y)
    if canMove == false then return false end
    local ok = moveXY(obj, x, y)
    if canMove == nil then canMove = ok end
    return ok
  end

  local function drawCompass(yaw, navBearing, navLabel, lowHp)
    if not compass then return end
    local cx, cy, R = ring()

    if yaw then
      local yawKey = math.floor(yaw / 4 + 0.5)
      local turned = yawKey ~= lastYawKey
      for _, m in ipairs(compass.marks) do
        local th = math.rad((m.a - yaw + 540) % 360 - 180)
        local lx, ly = cx + R * math.sin(th) - U(3), cy - R * math.cos(th) - U(4)
        if canMove ~= false and setXY(m.obj, lx, ly) then
          setText(m.obj, m.l)
        elseif turned then
          removeObj(m.obj)
          m.obj = text(lx, ly, m.l, letterColor(m.l))
        end
      end
      lastYawKey = yawKey
    end

    -- waypoint: gold dot on the ring + name/distance beside the compass
    if navBearing and yaw then
      local th = math.rad((navBearing - yaw + 540) % 360 - 180)
      local px, py = cx + R * math.sin(th), cy - R * math.cos(th)
      if not compass.wp then
        compass.wp = rect(px - U(2), py - U(2), U(4), U(4), COLOR.waypoint, 1)
      elseif not (canMove ~= false and setXY(compass.wp, px, py)) then
        if not compass.wpX or (compass.wpX - px) ^ 2 + (compass.wpY - py) ^ 2 >= 9 then
          removeObj(compass.wp); compass.wp = rect(px - U(2), py - U(2), U(4), U(4), COLOR.waypoint, 1)
        end
      end
      compass.wpX, compass.wpY = px, py
      setText(compass.label, navLabel or "")
    else
      if compass.wp then removeObj(compass.wp); compass.wp = nil end
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
        relativePosition = true, x = 0, y = 0, z = 0,   -- centred on your head
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

        STATS.speed = speed
        if x then
          set(hud.cx, ("X %d"):format(math.floor(x)))
          set(hud.cy, ("Y %d"):format(math.floor(y)))
          set(hud.cz, ("Z %d"):format(math.floor(z)))
        end
        local dim = myDimension()
        local showDim = dim ~= "?" and not dim:find("overworld")
        set(hud.face, (o.yaw and ("%s %d"):format(facingName(o.yaw), math.floor((o.yaw + 180) % 360)) or "?")
            .. "  " .. textutils.formatTime(os.time(), true) .. (showDim and ("  " .. plainName(dim)) or ""))
        local act = {}
        if blockTargets then act[#act + 1] = "blocks" end
        if showPlayers then act[#act + 1] = "players" end
        if dark then act[#act + 1] = "dark" end
        if navTarget then act[#act + 1] = "nav" end
        set(hud.mode, table.concat(act, "+"), MEKA.dim)
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
      PANEL_X = U(4)
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
  "me [item]  ME status/find",
  "ally add/del/list <n>",
  "iam <name>  set your name",
  "uisize <n>  HUD size",
  "theme helmet|meka",
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
  w.setTextColour(colours.white); w.write(" HELMET HUD")

  w.setBackgroundColour(colours.black)
  local mc = 0
  for _ in pairs(currentManagers) do mc = mc + 1 end
  w.setCursorPos(1, 2); w.clearLine()
  w.setTextColour(colours.lightGrey); w.write("Inv ")
  w.setTextColour(invSource == "none" and colours.red or colours.lime); w.write(tostring(beforeTotal or "?"))
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
    elseif cmd == "stats" or cmd == "s" or cmd == "summary" then showStats()
    elseif cmd == "managers" or cmd == "mgrs" then listManagers()
    elseif cmd == "me" then
      if not MELINK.ok then
        out("ME not linked.", colours.orange)
        out("me_link setup on the ME pc,", colours.lightGrey)
        out("then: evidencelog mepair <key>", colours.lightGrey)
      elseif words[2] then
        MELINK.nextId = MELINK.nextId + 1
        local q = table.concat(words, " ", 2)
        meSend({ t = "query", q = q, id = MELINK.nextId })
        out("asking ME for '" .. q .. "'...", colours.lightGrey)
      else
        local st = MELINK.status
        if not st then out("no data from ME yet") else
          out(("ME %s"):format(st.online and "online" or "OFFLINE"), st.online and colours.lime or colours.red)
          out(("items %d  types %d"):format(st.total or 0, st.types or 0))
          if st.used and st.cap then out(("storage %d/%d"):format(st.used, st.cap)) end
          if st.energy and st.maxEnergy then out(("power %d/%d"):format(math.floor(st.energy), math.floor(st.maxEnergy))) end
        end
      end
    elseif cmd == "iam" then
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
    elseif cmd == "uisize" or cmd == "uiscale" then
      local v = tonumber(words[2])
      if v and v >= 0.4 and v <= 1.5 then
        UI.size = v
        local f = fs.open("/.glasses_size", "w"); f.write(tostring(v)); f.close()
        HUD.rebuild()
        if toolkit then toolkit.setShown(HUD.shown) end
        out("HUD size " .. v .. " (saved)", colours.lime)
      else
        out("HUD size " .. UI.size .. "  (0.4 - 1.5)")
        out("e.g. uisize 0.6 smaller")
      end
    elseif cmd == "theme" then
      local v = words[2] and words[2]:lower()
      if v and THEMES[v] then
        applyTheme(v)
        local f = fs.open("/.glasses_theme", "w"); f.write(v); f.close()
        HUD.rebuild()
        if toolkit then toolkit.setShown(HUD.shown) end
        out("theme " .. v .. " (saved)", colours.lime)
      else
        out("theme: " .. THEME .. "   options: helmet, meka")
      end
    elseif cmd == "uiinfo" then
      LAYOUT.compute()
      local r = LAYOUT.raw or {}
      out(("gui: %s x %s  scale %s"):format(tostring(r[1]), tostring(r[2]), tostring(r[3])))
      out(("using %d x %d"):format(LAYOUT.W, LAYOUT.H))
      out("HUD size " .. UI.size)
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
  out("Type 'help'. Hotkey = hide.", colours.lightGrey)
  parallel.waitForAny(table.unpack(loops))
end

term.clear(); term.setCursorPos(1, 1)

local ok, err = pcall(main)
term.redirect(term.native()); term.setBackgroundColour(colours.black); term.clear(); term.setCursorPos(1, 1)
TERM.log = nil
if toolkit then toolkit.stop() end
if HW.overlay then try(HW.overlay.clear) end
if not ok and err ~= "Terminated" then printError(err) end
