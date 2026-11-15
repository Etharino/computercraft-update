-- ME Link for CC: Tweaked Rednet and the Advanced Peripherals ME Bridge.
-- me_link setup <glasses-ID>                     Configure the glasses ID.
-- me_link take-setup <owner> <manager> <buffer> <glasses-ID>
--   Enable inventory withdrawals to a linked AP 0.8 Inventory Manager.
-- me_link                                       Run alongside me-watch.
local args = { ... }
local PROTOCOL = "me-link"
local CLIENT_SETTING = "me_link.glasses_id"
local TAKE_SETTING  = "me_link.withdraw"
local TAKE_LOG      = "/me-withdraw.log"
local STATUS_EVERY  = 5      -- seconds between status packets
local CHECK_EVERY   = 5      -- seconds between stock comparisons
local ALERT_MIN     = 64     -- alert when this many items leave at once
local NEAR_RADIUS   = 8      -- who counts as "nearby" the ME system
local VALUABLE = { "diamond", "netherite", "ancient_debris", "elytra", "totem",
                   "enchanted_golden_apple", "nether_star", "heavy_core", "beacon" }

local function takeDevices(config)
  local manager = peripheral.wrap(config.manager)
  local buffer = peripheral.wrap(config.buffer)
  if not manager or type(manager.getOwner) ~= "function" then
    return nil, nil, "Linked Inventory Manager is missing"
  end
  if not buffer or type(buffer.list) ~= "function" then
    return nil, nil, "Transfer chest is missing or isn't connected as an inventory"
  end
  if type(manager.importItem) ~= "function" then
    return nil, nil, "Withdrawals need the Advanced Peripherals 0.8 Inventory Manager"
  end
  local ok, first, second = pcall(manager.getOwner)
  local name = second or first
  if not ok or type(name) ~= "string" or name:lower() ~= config.owner:lower() then
    return nil, nil, config.owner .. " must be online and linked to this manager"
  end
  return manager, buffer
end

if args[1] == "setup" or args[1] == "take-setup" then
  local configureTake = args[1] == "take-setup"
  local glassesID = tonumber(args[configureTake and 5 or 2])
  if not glassesID or glassesID < 0 or glassesID > 2147483647 or glassesID % 1 ~= 0 then
    error("Enter the numeric computer ID shown by 'id' on your glasses.", 0)
  end

  if configureTake then
    local owner, manager, buffer = args[2], args[3], args[4]
    if #args ~= 5 or not owner:match("^[A-Za-z0-9_]+$") or #owner > 16 or manager == buffer then
      error("Usage: me_link take-setup <owner> <manager> <buffer> <glasses-ID>", 0)
    end
    local config = { owner = owner, manager = manager, buffer = buffer }
    local _, chest, reason = takeDevices(config)
    if not chest then error(reason, 0) end
    if next(chest.list()) then error("Start with an empty, dedicated transfer chest.", 0) end
    settings.set(TAKE_SETTING, config)
    print("Withdrawals configured for " .. owner .. ".")
  elseif #args ~= 2 then
    error("Usage: me_link setup <glasses-ID>", 0)
  end

  settings.set(CLIENT_SETTING, glassesID)
  if not settings.save() then error("Couldn't save ME Link settings.", 0) end
  print("Restart me_link. On the glasses run me_take setup " .. os.getComputerID())
  return
end

local glassesID = settings.get(CLIENT_SETTING)
if not glassesID then error("Run me_link setup <glasses-ID> first.", 0) end

---------------------------------------------------------------------
-- Peripherals
---------------------------------------------------------------------
local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
if not bridge then error("No ME Bridge on this computer.", 0) end
local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if not modem then error("No ender/wireless modem on this computer.", 0) end
local detector = peripheral.find("player_detector") or peripheral.find("playerDetector")
rednet.open(peripheral.getName(modem))
local takeConfig = settings.get(TAKE_SETTING)

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

local function send(message)
  rednet.send(glassesID, message, PROTOCOL)
end

local function plain(id) return (tostring(id):gsub("^[^:]+:", "")) end

---------------------------------------------------------------------
-- Status, drop alerts, lookups
---------------------------------------------------------------------
local prev
local function status(items, id)
  local types, total = 0, 0
  for _, e in pairs(items or {}) do types = types + 1; total = total + e.count end
  send({
    t = "status", id = id, online = online() and items ~= nil, types = types, total = total,
    used = call({ "getUsedItemStorage" }), cap = call({ "getTotalItemStorage" }),
    energy = call({ "getStoredEnergy", "getEnergyStorage" }),
    maxEnergy = call({ "getEnergyCapacity", "getMaxEnergyStorage" }),
  })
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

local function journal(line)
  local file = assert(fs.open(TAKE_LOG, "a"))
  file.writeLine(line)
  file.close()
end

local lastTakeID = 0
if takeConfig and fs.exists(TAKE_LOG) then
  local file = assert(fs.open(TAKE_LOG, "r"))
  while true do
    local line = file.readLine()
    if not line then break end
    local sender, id = line:match("^REDNET_REQUEST (%d+) (%d+)")
    if tonumber(sender) == glassesID then lastTakeID = math.max(lastTakeID, tonumber(id)) end
  end
  file.close()
end

local function movedCount(method, first, second, limit)
  local ok, moved, reason = pcall(method, first, second)
  if not ok then return nil, tostring(moved) end
  if type(moved) ~= "number" then return nil, tostring(reason or "Invalid transfer result") end
  if moved < 0 or moved > limit or moved % 1 ~= 0 then return nil, "Invalid transfer count" end
  return moved, reason
end

local function withdraw(item, quantity)
  local manager, buffer, reason = takeDevices(takeConfig)
  if not manager then return reason end
  if not online() then return "ME network is offline" end
  if next(buffer.list()) then return "Transfer chest is occupied. Check it at base." end
  local staged, exportError = movedCount(bridge.exportItem, takeConfig.buffer,
    { name = item, count = quantity }, quantity)
  if not staged then return "Could not verify export. Check the transfer chest. " .. exportError end
  if staged == 0 then return exportError or "No stock moved. Check ME stock and chest connection." end

  local delivered, deliveryError = movedCount(manager.importItem, takeConfig.buffer,
    { name = item, count = staged }, staged)
  if not delivered then
    return "Could not verify inventory delivery. Check your inventory and the transfer chest. " .. deliveryError
  end

  local spare = staged - delivered
  local status = ("Delivered %d/%d to %s"):format(delivered, quantity, takeConfig.owner)
  if spare > 0 then
    local returned = movedCount(bridge.importItem, takeConfig.buffer, { name = item, count = spare }, spare)
    if not returned then
      return status .. ". Could not verify return of leftovers. Check the transfer chest."
    end
    status = status .. (". Returned %d to ME"):format(returned)
    if returned < spare then status = status .. (". %d left in transfer chest"):format(spare - returned) end
  end
  if deliveryError then status = status .. ". " .. tostring(deliveryError) end
  return status
end

local function handleTake(msg)
  local item, quantity = msg.item, msg.count
  local result
  if not takeConfig then
    result = "Withdrawals need me_link take-setup on the ME computer"
  elseif msg.id <= lastTakeID then
    result = "Request already processed. Check your inventory or me-withdraw.log."
  elseif math.abs(os.epoch("utc") - msg.id) > 30000 then
    result = "Request expired. Run me_take again."
  elseif type(item) ~= "string" or item == "minecraft:air" or #item > 180
      or not item:match("^[a-z0-9_.%-]+:[a-z0-9_./%-]+$")
      or type(quantity) ~= "number" or quantity < 1 or quantity > 2147483647 or quantity % 1 ~= 0 then
    result = "Invalid item ID or amount"
  else
    -- Record the request before moving items to avoid duplicate delivery after a restart.
    local logged = pcall(journal, ("REDNET_REQUEST %d %d %s %s %d"):format(
      glassesID, msg.id, takeConfig.owner, item, quantity))
    if logged then
      lastTakeID = msg.id
      local ok, details = pcall(withdraw, item, quantity)
      result = ok and details or "Could not verify withdrawal. Check your inventory and the transfer chest."
      local entry = ("RESULT %d %s"):format(msg.id, result)
      if not pcall(journal, entry:gsub("[\r\n]", " ")) then print("Could not append withdrawal result.") end
      print("Withdrawal " .. item .. ": " .. result)
    else
      result = "Could not save request to " .. TAKE_LOG .. ". No items moved."
    end
  end
  send({ t = "take_result", id = msg.id, result = result })
end

---------------------------------------------------------------------
-- Main
---------------------------------------------------------------------
term.clear(); term.setCursorPos(1, 1)
term.setTextColour(colours.lightBlue); print("ME LINK"); term.setTextColour(colours.white)
print(("ME computer #%d | Glasses #%d"):format(os.getComputerID(), glassesID))
print(detector and "Player Detector: yes" or "Player Detector: no (alerts won't name anyone)")
if takeConfig then print("Inventory withdrawals: " .. takeConfig.owner) end
print("Ctrl+T to stop.")

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
  elseif ev[1] == "rednet_message" and ev[2] == glassesID and ev[4] == PROTOCOL then
    local msg = ev[3]
    if type(msg) == "table" and type(msg.id) == "number" and msg.id > 0
        and msg.id <= 9007199254740991 and msg.id % 1 == 0 then
      if msg.t == "query" and type(msg.q) == "string" and #msg.q > 0 and #msg.q <= 180 then
        answer(msg.q, msg.id)
        print("Lookup: " .. msg.q)
      elseif msg.t == "status_request" then
        status(readItems(), msg.id)
      elseif msg.t == "take" then
        handleTake(msg)
      end
    end
  end
end
