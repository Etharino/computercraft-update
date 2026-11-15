--[[
=====================================================================
  ME LINK  -  connects your ME system to your Smart Glasses
=====================================================================
  Runs on the ME computer NEXT TO me-watch (it doesn't change it).
  Uses the same ME Bridge, plus the ender modem, and talks to the
  glasses through securelink: signed + encrypted + replay-protected,
  so nobody listening on the modem can read your stock or fake it.

  Sends the glasses:
    * status every few seconds (items, types, storage %, power)
    * an alert when stock drops a lot or valuables leave
  Answers "me <item>" lookups from the glasses.

  NEEDS on this computer: ME Bridge, ender (or wireless) modem,
  securelink.lua.  Player Detector optional (names who was nearby).

  SETUP
    1. me_link setup             -> prints a key
    2. on the glasses:  evidencelog mepair <key>
    3. run it alongside me-watch (Advanced Computer):
         bg me_link
         me-watch
       or put both in startup.lua:
         shell.openTab("me_link")
         shell.run("me-watch")
=====================================================================
]]

local link = require("securelink")
local args = { ... }

local KEY_FILE      = "/.me_key"
local STATUS_EVERY  = 5      -- seconds between status packets
local CHECK_EVERY   = 5      -- seconds between stock comparisons
local ALERT_MIN     = 64     -- alert when this many items leave at once
local NEAR_RADIUS   = 8      -- who counts as "nearby" the ME system
local VALUABLE = { "diamond", "netherite", "ancient_debris", "elytra", "totem",
                   "enchanted_golden_apple", "nether_star", "heavy_core", "beacon" }

---------------------------------------------------------------------
-- Key
---------------------------------------------------------------------
local function loadKey()
  if not fs.exists(KEY_FILE) then return nil end
  local f = fs.open(KEY_FILE, "r"); local s = (f.readAll() or ""):gsub("%s", ""); f.close()
  return s ~= "" and s or nil
end

if args[1] == "setup" then
  local secret = link.newSecret()
  local f = fs.open(KEY_FILE, "w"); f.write(secret); f.close()
  term.setTextColour(colours.yellow); print("New ME link key (keep it private):")
  term.setTextColour(colours.white); print(""); print("  " .. secret); print("")
  print("On your glasses run:")
  print("  evidencelog mepair " .. secret)
  return
end

local secret = loadKey()
if not secret then error("No key yet. Run: me_link setup", 0) end
local keys = assert(link.keys(secret))

---------------------------------------------------------------------
-- Peripherals
---------------------------------------------------------------------
local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("No ME Bridge on this computer.", 0) end
local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if not modem then error("No ender/wireless modem on this computer.", 0) end
local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
modem.open(keys.channel)

-- Call the first ME Bridge function that exists (names differ between AP versions)
local function call(names, ...)
  for _, n in ipairs(names) do
    local f = bridge[n]
    if type(f) == "function" then
      local ok, v = pcall(f, ...)
      if ok then return v end
    end
  end
end

local function online()
  local v = call({ "isOnline", "isConnected" })
  return v ~= false
end

-- name -> { count, display }
local function readItems()
  local list = call({ "getItems" }, {}) or call({ "listItems" })
  if type(list) ~= "table" then return nil end
  local out = {}
  for _, it in pairs(list) do
    if type(it) == "table" and type(it.name) == "string" then
      local c = tonumber(it.count or it.amount) or 0
      local e = out[it.name] or { count = 0, display = it.displayName }
      e.count = e.count + c
      out[it.name] = e
    end
  end
  return out
end

---------------------------------------------------------------------
-- Sending (sequence numbers are ms timestamps, so never two in one ms)
---------------------------------------------------------------------
local lastSeal = 0
local function send(tbl)
  while os.epoch("utc") <= lastSeal do sleep(0) end
  local packet = link.seal(keys, textutils.serialize(tbl, { compact = true }))
  lastSeal = packet.s
  modem.transmit(keys.channel, keys.channel, packet)
end

local function plain(id) return (tostring(id):gsub("^[^:]+:", "")) end

---------------------------------------------------------------------
-- Status, drop alerts, lookups
---------------------------------------------------------------------
local prev
local lastStatus = {}

local function status(items)
  local types, total = 0, 0
  for _, e in pairs(items or {}) do types = types + 1; total = total + e.count end
  lastStatus = {
    t = "status", online = online() and items ~= nil, types = types, total = total,
    used = call({ "getUsedItemStorage" }), cap = call({ "getTotalItemStorage" }),
    energy = call({ "getStoredEnergy", "getEnergyStorage" }),
    maxEnergy = call({ "getEnergyCapacity", "getMaxEnergyStorage" }),
  }
  send(lastStatus)
end

local function nearby()
  if not detector then return nil end
  local ok, list = pcall(detector.getPlayersInRange, NEAR_RADIUS)
  if not ok or type(list) ~= "table" then return nil end
  local names = {}
  for _, p in pairs(list) do names[#names + 1] = type(p) == "table" and p.name or tostring(p) end
  return #names > 0 and table.concat(names, ", ") or "nobody"
end

local function isValuable(name)
  for _, v in ipairs(VALUABLE) do if name:find(v, 1, true) then return true end end
  return false
end

local function checkDrops(items)
  if not items then prev = nil; return end          -- failed read: rebaseline next time
  if not prev then prev = items; return end
  local drops, total, valuable = {}, 0, false
  for name, e in pairs(prev) do
    local now = items[name] and items[name].count or 0
    if now < e.count then
      local d = e.count - now
      total = total + d
      if isValuable(name) then valuable = true end
      drops[#drops + 1] = { name = plain(name), count = d }
    end
  end
  prev = items
  if total >= ALERT_MIN or (valuable and total > 0) then
    table.sort(drops, function(a, b) return a.count > b.count end)
    local top = {}
    for i = 1, math.min(#drops, 4) do top[i] = drops[i] end
    send({ t = "drop", total = total, items = top, valuable = valuable, near = nearby() })
    print(("Drop -%d sent%s"):format(total, valuable and " (valuable)" or ""))
  end
end

local function answer(q, id)
  local items = readItems() or {}
  q = tostring(q or ""):lower()
  local res = {}
  for name, e in pairs(items) do
    local d = (e.display or ""):lower()
    if name:lower():find(q, 1, true) or d:find(q, 1, true) then
      res[#res + 1] = { name = e.display or plain(name), count = e.count }
    end
  end
  table.sort(res, function(a, b) return a.count > b.count end)
  local top = {}
  for i = 1, math.min(#res, 8) do top[i] = res[i] end
  send({ t = "reply", id = id, q = q, matches = #res, results = top })
end

---------------------------------------------------------------------
-- Main
---------------------------------------------------------------------
term.clear(); term.setCursorPos(1, 1)
term.setTextColour(colours.lightBlue); print("ME LINK"); term.setTextColour(colours.white)
print("Channel " .. keys.channel .. " (from your key)")
print(detector and "Player Detector: yes" or "Player Detector: no (alerts won't name anyone)")
print("Ctrl+T to stop.")

local rx = {}   -- replay-protection state for packets from the glasses
local nextStatus, nextCheck = 0, 0
local timer = os.startTimer(0.5)
while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" and ev[2] == timer then
    local t = os.clock()
    if t >= nextCheck or t >= nextStatus then
      local items = readItems()
      if t >= nextCheck then nextCheck = t + CHECK_EVERY; checkDrops(items) end
      if t >= nextStatus then nextStatus = t + STATUS_EVERY; status(items) end
    end
    timer = os.startTimer(0.5)
  elseif ev[1] == "modem_message" and ev[3] == keys.channel then
    local plainText = link.open(keys, rx, ev[5])
    if plainText then
      local msg = textutils.unserialize(plainText)
      if type(msg) == "table" and msg.t == "query" then
        answer(msg.q, msg.id)
        print("Lookup: " .. tostring(msg.q))
      end
    end
  end
end
