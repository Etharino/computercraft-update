-- Smart Glasses client for me_link. Uses plain CC: Tweaked Rednet.
-- me_take setup <ME-computer-ID>  |  me_take <item-id> [count]
-- me_take status  |  me_take find <item name>
local args = { ... }
local protocol = "me-link"
local serverSetting = "me_take.server_id"

if args[1] == "setup" then
  local serverID = tonumber(args[2])
  if #args ~= 2 or not serverID or serverID < 0 or serverID > 2147483647 or serverID % 1 ~= 0 then
    error("Usage: me_take setup <ME-computer-ID>. Run 'id' on the ME computer.", 0)
  end
  settings.set(serverSetting, serverID)
  settings.unset("me_take.key")
  if not settings.save() then error("Couldn't save the ME computer ID.", 0) end
  print(("ME computer #%d | Glasses #%d"):format(serverID, os.getComputerID()))
  return
end

local request, expected
if args[1] == "status" and #args == 1 then
  request, expected = { t = "status_request" }, "status"
elseif args[1] == "find" and #args >= 2 then
  local query = table.concat(args, " ", 2)
  if #query > 180 then error("Item query is too long.", 0) end
  request, expected = { t = "query", q = query }, "reply"
else
  local item, count = args[1], tonumber(args[2] or "1")
  if item and not item:find(":", 1, true) then item = "minecraft:" .. item end
  if not item or item == "minecraft:air" or #item > 180
      or not item:match("^[a-z0-9_.%-]+:[a-z0-9_./%-]+$")
      or not count or count < 1 or count > 2147483647 or count % 1 ~= 0 or #args > 2
      or args[1] == "help" or args[1] == "pair" or args[1] == "find" then
    print("Usage: me_take <item-id> [count]")
    print("Example: me_take diamond 16")
    print("Also: me_take setup <ME-computer-ID> | status | find <item>")
    return
  end
  request, expected = { t = "take", item = item, count = count }, "take_result"
end

local serverID = settings.get(serverSetting)
if not serverID then error("Run me_take setup <ME-computer-ID> first.", 0) end
local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if not modem then error("Install an Ender Modem in a glasses peripheral slot.", 0) end
local modemName = peripheral.getName(modem)
local opened = not rednet.isOpen(modemName)
if opened then rednet.open(modemName) end

local function show(message)
  if expected == "take_result" and type(message.result) == "string" then
    print(message.result)
  elseif expected == "status" then
    if not message.online then
      print("ME network is offline.")
      return
    end
    print(("%s items | %s types"):format(message.total or "?", message.types or "?"))
    if type(message.used) == "number" and type(message.cap) == "number" and message.cap > 0 then
      print(("Storage %.0f%% used"):format(100 * message.used / message.cap))
    end
    if type(message.energy) == "number" and type(message.maxEnergy) == "number" and message.maxEnergy > 0 then
      print(("Power %.0f%%"):format(100 * message.energy / message.maxEnergy))
    end
  elseif expected == "reply" and type(message.results) == "table" then
    if #message.results == 0 then print("No matching items.") end
    for _, row in ipairs(message.results) do
      if type(row) == "table" and type(row.count) == "number" and type(row.name) == "string" then
        print(("%s x %s"):format(row.count, row.name))
      end
    end
  end
end

local function exchange()
  request.id = os.epoch("utc")
  if expected == "take_result" then
    print(("Requesting %d %s..."):format(request.count, request.item))
  end
  if not rednet.send(serverID, request, protocol) then error("Rednet couldn't send the request.", 0) end
  local timer = os.startTimer(18)
  while true do
    local event, sender, message, receivedProtocol = os.pullEvent()
    if event == "timer" and sender == timer then
      print(expected == "take_result" and "No reply. Check your inventory or me-withdraw.log before retrying."
        or "No reply from the ME computer.")
      return
    end
    if event == "rednet_message" and sender == serverID and receivedProtocol == protocol
        and type(message) == "table" and message.t == expected and message.id == request.id then
      os.cancelTimer(timer)
      show(message)
      return
    end
  end
end

local ok, reason = pcall(exchange)
if opened then rednet.close(modemName) end
if not ok then error(reason, 0) end
