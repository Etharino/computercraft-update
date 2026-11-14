--[[
=====================================================================
  RELAY BASE  -  sends your inventory to your Smart Glasses, securely
=====================================================================
  Put this on a computer in your base with:
    * an Inventory Manager next to it, with a memory card bound to YOU
      (it keeps working after the card goes blank - that's normal)
    * an ENDER modem (or wireless modem) on it

  Messages are encrypted, signed and replay-protected (securelink.lua).
  People can see that packets are sent, but can't read or fake them.

  SETUP
    1. relay_base setup         -> makes a secret key and prints it
    2. on the glasses:  evidencelog pair <that key>
    3. relay_base               -> start (or put it in startup)

  Files needed on this computer: relay_base.lua, securelink.lua
=====================================================================
]]

local link = require("securelink")
local args = { ... }

local SEND_EVERY = 1   -- seconds

---------------------------------------------------------------------
-- Setup: make and show a new key
---------------------------------------------------------------------
if args[1] == "setup" then
  local secret = link.newSecret()
  link.saveSecret(secret)
  term.setTextColour(colours.yellow)
  print("New relay key (keep it private):")
  term.setTextColour(colours.white)
  print("")
  print("  " .. secret)
  print("")
  print("On your glasses run:")
  print("  evidencelog pair " .. secret)
  print("")
  print("Then run: relay_base")
  print("Tip: anyone who reads this computer's files can see the key.")
  return
end

---------------------------------------------------------------------
-- Hardware
---------------------------------------------------------------------
local secret = link.loadSecret()
if not secret then error("No key yet. Run: relay_base setup", 0) end
local keys = assert(link.keys(secret))

local manager = peripheral.find("inventory_manager") or peripheral.find("inventoryManager")
if not manager then error("No Inventory Manager next to this computer.", 0) end

local modem = peripheral.find("modem", function(_, m) return m.isWireless and m.isWireless() end)
if not modem then error("No ender/wireless modem on this computer.", 0) end

local function owner()
  local ok, a, b = pcall(manager.getOwner)
  if not ok then return nil end
  return (type(b) == "string" and b) or (type(a) == "string" and a) or nil
end

local function readItems()
  local items, any = {}, false
  local function add(list)
    if type(list) ~= "table" then return end
    any = true
    for _, it in pairs(list) do
      if type(it) == "table" and it.name then
        local c = tonumber(it.count or it.amount) or 0
        items[it.name] = (items[it.name] or 0) + c
      end
    end
  end
  local ok1, inv = pcall(manager.getItems)
  if ok1 then add(inv) end
  local ok2, armor = pcall(manager.getArmor)
  if ok2 then add(armor) end
  return items, any
end

---------------------------------------------------------------------
-- Run
---------------------------------------------------------------------
term.clear(); term.setCursorPos(1, 1)
term.setTextColour(colours.lightBlue); print("RELAY BASE"); term.setTextColour(colours.white)
print("Owner:   " .. tostring(owner()))
print("Channel: " .. keys.channel .. " (from your key)")
print("Sending every " .. SEND_EVERY .. "s.  Ctrl+T to stop.")
print("")

local sent = 0
while true do
  local items, online = readItems()
  local payload = link.encodeInventory({ owner = owner(), online = online, items = items })
  modem.transmit(keys.channel, keys.channel, link.seal(keys, payload))
  sent = sent + 1
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  write(("Sent %d  |  %s"):format(sent, online and "you are online" or "you are offline"))
  sleep(SEND_EVERY)
end
