-- nuke.lua :: fake missile launch. all bark, no bite — nothing actually fires.
-- big dramatic countdown + chat spam + monitor strobe, then it "fails" at the last second.
-- usage: nuke [target name]
--   nuke
--   nuke Nathan

local lib = require("auralib")
local args = { ... }
local TARGET = (args[1] or "NATHAN"):upper()

local chat = lib.findAny("chatBox", "chat_box")
local speaker = peripheral.find("speaker")
local mon = peripheral.find("monitor")
local t = mon or term
if mon then mon.setTextScale(0.5) end

---------------------------------------------------------------- chat (handles both AP chat box API styles)
local chatStyle
local function chatOpts() return { prefix = "&4&lDEFCON", brackets = "[]", bracketColor = "&4" } end
local function chatSend(text, color)
  if not chat then return end
  local json = textutils.serializeJSON({ { text = "" }, { text = text, color = color or "red", bold = true } })
  local order = (chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res = pcall(function()
      if style == "new" then return chat.sendFormattedMessage(json, chatOpts())
      else return chat.sendFormattedMessage(json, "DEFCON", "[]", "&4") end
    end)
    if ok and res then chatStyle = style return end
  end
  pcall(chat.sendMessage, text, "DEFCON")
end

local function beep(sound, pitch)
  if speaker then pcall(speaker.playSound, sound, 3, pitch or 1) end
end

---------------------------------------------------------------- monitor visuals
local W, H = t.getSize()

local function clear(col)
  t.setBackgroundColor(col or colors.black)
  t.clear()
end

local function centre(y, text, fg, bg)
  if bg then
    t.setBackgroundColor(bg)
    t.setCursorPos(1, y)
    t.write(string.rep(" ", W))
  end
  t.setCursorPos(math.max(1, math.floor((W - #text) / 2) + 1), y)
  t.setTextColor(fg)
  t.write(text)
end

local function bigNumber(n, col)
  clear(colors.black)
  local lines, sc, xs = lib.fitText(tostring(n), W - 4, H - 2, 20)
  local grid = lib.grid(W, H, "f")
  lib.stamp(grid, lines, sc, col == colors.red and "e" or "1", "f", 0, xs)
  lib.blitGrid(t, grid, "e")
end

local function strobe(n, a, b)
  for i = 1, n do
    clear(i % 2 == 1 and a or b)
    sleep(0.08)
  end
end

local function bigWords(text, col, bgcol)
  clear(bgcol or colors.black)
  local lines, sc, xs = lib.fitText(text, W - 4, H - 2, 6)
  if sc >= 1 then
    local grid = lib.grid(W, H, "f")
    lib.stamp(grid, lines, sc, col, "f", 0, xs)
    lib.blitGrid(t, grid, "e")
  else
    local y = math.floor(H / 2)
    for i, l in ipairs(lines) do centre(y + i - 1, l, colors.white) end
  end
end

---------------------------------------------------------------- script
local WARNINGS = {
  "SATELLITE UPLINK ESTABLISHED",
  "TARGETING ARRAY ONLINE",
  "COORDINATES LOCKED",
  "SILO DOORS OPENING",
  "ARMING SEQUENCE ENGAGED",
  "WARHEAD STATUS: HOT",
  "AUTHORIZATION CODE ACCEPTED",
  "GUIDANCE SYSTEM CALIBRATED",
}

local FAILS = {
  "SIGNAL LOST. " .. TARGET .. " WILL NEVER KNOW HOW CLOSE THAT WAS.",
  "LAUNCH KEY WAS LEFT AT HOME. STAND DOWN.",
  "A BIRD LANDED ON THE BUTTON. MISSION SCRUBBED.",
  TARGET .. "'S AURA DEFLECTED THE WARHEAD. THEY LIVE ANOTHER DAY.",
  "WHOOPS, WRONG BUTTON. THAT WAS THE COFFEE MACHINE.",
  "COMMAND OVERRIDE: " .. TARGET .. " HAS DIPLOMATIC IMMUNITY (for now).",
}

local function run()
  if chat then chatSend("INCOMING TRANSMISSION FROM DEFCON COMMAND", "red") sleep(1.2) end

  bigWords("DEFCON 1", colors.red, colors.black)
  if chat then chatSend("=== DEFCON 1 ===", "dark_red") end
  beep("minecraft:block.bell.use", 0.5)
  sleep(1.5)

  strobe(6, colors.red, colors.black)
  bigWords("TARGET:", colors.white)
  sleep(0.8)
  bigWords(TARGET, colors.red)
  if chat then chatSend("TARGET ACQUIRED: " .. TARGET, "red") end
  beep("minecraft:entity.wither.spawn", 0.7)
  sleep(1.8)

  for _, w in ipairs(WARNINGS) do
    clear(colors.black)
    centre(math.floor(H / 2) - 1, "[ ALERT ]", colors.red)
    centre(math.floor(H / 2) + 1, w, colors.yellow)
    if chat then chatSend("[SYSTEM] " .. w, "yellow") end
    beep("minecraft:block.note_block.hat", 1.5)
    sleep(0.9)
  end

  bigWords("LAUNCH IN", colors.yellow)
  if chat then chatSend("!!! LAUNCH SEQUENCE INITIATED !!!", "gold") end
  sleep(1.2)

  for n = 10, 1, -1 do
    local col = n <= 3 and colors.red or colors.orange
    bigNumber(n, col)
    if chat then
      if n <= 3 then
        chatSend(string.rep("! ", 3) .. n .. string.rep(" !", 3), "red")
      elseif n % 2 == 0 or n <= 5 then
        chatSend(tostring(n) .. "...", "gold")
      end
    end
    beep(n <= 3 and "minecraft:block.note_block.bell" or "minecraft:block.note_block.hat", 2 - n * 0.08)
    strobe(2, colors.red, colors.black)
    sleep(0.3)
  end

  -- the "launch" that immediately fizzles
  strobe(10, colors.white, colors.red)
  bigWords("MALFUNCTION", colors.red, colors.black)
  if chat then chatSend("!!! LAUNCH FAILURE !!!", "red") end
  beep("minecraft:entity.generic.extinguish_fire", 0.6)
  sleep(1.5)

  local fail = FAILS[math.random(#FAILS)]
  clear(colors.black)
  local lines, sc, xs = lib.fitText("ABORTED", W - 4, math.floor(H * 0.6), 6)
  if sc >= 1 then
    local grid = lib.grid(W, H, "f")
    lib.stamp(grid, lines, sc, "1", "f", -math.floor(H * 0.15), xs)
    lib.blitGrid(t, grid, "e")
  end
  t.setTextColor(colors.lightGray)
  local wrapY = math.floor(H * 0.75)
  -- word-wrap the fail message across available width
  local w = W - 4
  local cur = ""
  local wlines = {}
  for word in fail:gmatch("%S+") do
    local cand = (cur == "" and word or cur .. " " .. word)
    if #cand > w then wlines[#wlines + 1] = cur cur = word else cur = cand end
  end
  if cur ~= "" then wlines[#wlines + 1] = cur end
  for i, l in ipairs(wlines) do
    if wrapY + i - 1 <= H then centre(wrapY + i - 1, l, colors.lightGray) end
  end
  if chat then
    chatSend("LAUNCH ABORTED.", "aqua")
    sleep(1.1)
    chatSend(fail, "white")
  end
  beep("minecraft:entity.villager.no", 1)
end

local ok, err = pcall(run)
sleep(2)
clear(colors.black)
t.setTextColor(colors.white)
t.setCursorPos(1, 1)
if not ok then printError(err) end
print("nothing was actually fired. " .. TARGET .. " is safe. for now.")
