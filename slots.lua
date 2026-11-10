-- slots.lua :: a slot machine. 3 reels, a lever, and a payout table.
-- needs: a monitor (optional — runs on the plain screen fine), a speaker (optional, for
-- clinks/jackpot sound), a chat box (optional, announces jackpots).
--
-- controls:
--   monitor: tap anywhere to pull the lever
--   no monitor: space or enter to pull, q to quit
--
-- credits persist between runs in slots.db. starting balance is 500 if the file
-- doesn't exist yet. each pull costs 10.

local lib = require("auralib")

local mon = peripheral.find("monitor")
local t = mon or term
if mon then mon.setTextScale(1) end
local speaker = peripheral.find("speaker")
local chat = lib.findAny("chatBox", "chat_box")

local BET = 10
local SAVE = "slots.db"

-- symbol, color, payout multiplier for 3-in-a-row, weight (higher = more common)
local SYMBOLS = {
  { "SEVEN",  colors.red,     50, 1 },
  { "BELL",   colors.yellow,  20, 2 },
  { "STAR",   colors.cyan,    10, 4 },
  { "BAR",    colors.orange,   6, 5 },
  { "LEMON",  colors.lime,     4, 7 },
  { "CHERRY", colors.magenta,  3, 9 },
}
local TOTAL_WEIGHT = 0
for _, s in ipairs(SYMBOLS) do TOTAL_WEIGHT = TOTAL_WEIGHT + s[4] end

local function rollSymbol()
  local r = math.random(TOTAL_WEIGHT)
  for _, s in ipairs(SYMBOLS) do
    r = r - s[4]
    if r <= 0 then return s end
  end
  return SYMBOLS[#SYMBOLS]
end

---------------------------------------------------------------- credits
local credits = 500
local function load()
  if fs.exists(SAVE) then
    local f = fs.open(SAVE, "r")
    credits = tonumber(f.readLine()) or 500
    f.close()
  end
end
local function save()
  local f = fs.open(SAVE, "w")
  f.write(tostring(credits))
  f.close()
end

---------------------------------------------------------------- chat (same dual-style handling as the rest of the pack)
local chatStyle
local function announce(text, color)
  if not chat then return end
  local json = textutils.serializeJSON({ { text = "" }, { text = text, color = color or "yellow", bold = true } })
  local order = (chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res = pcall(function()
      if style == "new" then return chat.sendFormattedMessage(json, { prefix = "SLOTS", brackets = "[]", bracketColor = "&6" })
      else return chat.sendFormattedMessage(json, "SLOTS", "[]", "&6") end
    end)
    if ok and res then chatStyle = style return end
  end
  pcall(chat.sendMessage, text, "SLOTS")
end

local function beep(sound, pitch) if speaker then pcall(speaker.playSound, sound, 3, pitch or 1) end end

---------------------------------------------------------------- drawing
local W, H = t.getSize()
local reelW = math.floor(W / 3)

local function drawFrame(reels, flash, message, msgColor)
  t.setBackgroundColor(colors.black)
  t.clear()
  local title = "=== S L O T S ==="
  t.setCursorPos(math.floor((W - #title) / 2) + 1, 1)
  t.setTextColor(colors.yellow)
  t.write(title)

  local top = math.floor(H / 2) - 2
  for col = 1, 3 do
    local sym = reels[col]
    local cx = (col - 1) * reelW + math.floor(reelW / 2) + 1
    t.setBackgroundColor(flash and colors.white or colors.gray)
    for y = top, top + 4 do
      t.setCursorPos((col - 1) * reelW + 2, y)
      t.write(string.rep(" ", reelW - 2))
    end
    t.setBackgroundColor(colors.black)
    t.setTextColor(flash and colors.black or sym[2])
    local label = sym[1]
    t.setCursorPos(math.max(1, cx - math.floor(#label / 2)), top + 2)
    t.write(label)
  end

  t.setTextColor(colors.white)
  t.setCursorPos(2, H - 3)
  t.write("credits: " .. lib.commas(credits))
  t.setCursorPos(2, H - 2)
  t.write("bet: " .. BET)

  if message then
    t.setTextColor(msgColor or colors.white)
    t.setCursorPos(math.max(1, math.floor((W - #message) / 2) + 1), H - 5)
    t.write(message)
  end

  t.setTextColor(colors.lightGray)
  local hint = mon and "tap to pull the lever" or "space/enter to pull  -  q to quit"
  t.setCursorPos(math.max(1, math.floor((W - #hint) / 2) + 1), H)
  t.write(hint)
end

local function spin()
  if credits < BET then
    drawFrame({ SYMBOLS[1], SYMBOLS[1], SYMBOLS[1] }, false, "NOT ENOUGH CREDITS", colors.red)
    beep("minecraft:entity.villager.no", 1)
    return
  end
  credits = credits - BET
  save()

  local reels = { rollSymbol(), rollSymbol(), rollSymbol() }
  -- spin animation: fast random flicker per reel, each stopping a little later than the last
  local stopAt = { 10, 16, 22 }
  for frame = 1, 22 do
    local showing = {}
    for col = 1, 3 do
      showing[col] = (frame >= stopAt[col]) and reels[col] or rollSymbol()
    end
    drawFrame(showing, false)
    beep("minecraft:block.note_block.hat", 1 + frame * 0.02)
    sleep(0.08)
  end

  local a, b, c = reels[1][1], reels[2][1], reels[3][1]
  local payout = 0
  local msg, col = nil, colors.white

  if a == b and b == c then
    payout = BET * reels[1][3]
    msg = "JACKPOT!  +" .. lib.commas(payout)
    col = colors.yellow
  elseif a == b or b == c or a == c then
    payout = BET * 2
    msg = "PAIR  +" .. lib.commas(payout)
    col = colors.lime
  else
    msg = "no match"
    col = colors.gray
  end

  credits = credits + payout
  save()

  if payout >= BET * 20 then
    for _ = 1, 6 do
      drawFrame(reels, true, msg, col)
      beep("minecraft:entity.firework_rocket.blast", 1)
      sleep(0.1)
      drawFrame(reels, false, msg, col)
      sleep(0.1)
    end
    announce("hit the jackpot on the slots! +" .. lib.commas(payout) .. " credits", "gold")
  else
    drawFrame(reels, false, msg, col)
    beep(payout > 0 and "minecraft:entity.experience_orb.pickup" or "minecraft:block.dispenser.fail", 1)
  end
end

---------------------------------------------------------------- main
math.randomseed(os.epoch("utc"))
load()
drawFrame({ SYMBOLS[1], SYMBOLS[2], SYMBOLS[3] }, false)

local ok, err = pcall(function()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "monitor_touch" and mon and a == peripheral.getName(mon) then
      spin() -- leaves the result on screen; the next pull's spin animation redraws over it
    elseif e == "key" and not mon then
      if b == keys.space or b == keys.enter then
        spin()
      elseif b == keys.q then
        break
      end
    end
  end
end)

t.setBackgroundColor(colors.black)
t.setTextColor(colors.white)
t.clear()
t.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
print("cashed out with " .. lib.commas(credits) .. " credits.")
