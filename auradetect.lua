-- auradetect.lua :: the aura tracking system
-- needs (all optional, uses whatever it finds):
--   Player Detector  (Advanced Peripherals) -> judges everyone who walks up
--   Chat Box         (Advanced Peripherals) -> announces + chat commands
--   Monitor (advanced) -> live leaderboard + big flash when someone gains/loses aura
--
-- chat commands (start with ! , or $ to hide the message):
--   !aura            your aura + rank
--   !aura top        top 5
--   !aura <name>     someone else's aura
--   !farm            farm a bit of aura (cooldown, spamming costs you)
--   !mog <name>      aura battle. winner takes the stake
--   !aurahelp        list commands
-- right-clicking the player detector = vibe check

local lib = require("auralib")

local CFG = {
  range        = 10,     -- blocks; players inside this radius get judged
  rejudge      = 300,    -- seconds before the same player gets judged again on arrival
  prefix       = "&d&lAURA",
  brackets     = "[]",
  bracketColor = "&5",
  saveFile     = "aura.db",
  rsSide       = nil,    -- e.g. "back": pulses redstone on every judgement (lamps, note blocks...)
  farmCooldown = 600,
  mogCooldown  = 30,
  clickCooldown= 60,
  textScale    = 0.5,
}

local detector = lib.findAny("playerDetector", "player_detector")
local chat     = lib.findAny("chatBox", "chat_box")
local mon      = peripheral.find("monitor")
local out      = mon or term

local function now() return os.epoch("utc") / 1000 end
local function pick(list) return list[math.random(#list)] end

---------------------------------------------------------------- data
local db = {}
local function load()
  if fs.exists(CFG.saveFile) then
    local f = fs.open(CFG.saveFile, "r")
    local d = textutils.unserialize(f.readAll())
    f.close()
    if type(d) == "table" then db = d end
  end
end
local function save()
  local f = fs.open(CFG.saveFile, "w")
  f.write(textutils.serialize(db))
  f.close()
end
local function get(name)
  local p = db[name]
  if not p then p = { aura = 0 } db[name] = p end
  return p
end
local function findName(q)
  q = q:lower()
  for n in pairs(db) do if n:lower() == q then return n end end
end
local function sorted()
  local l = {}
  for n, p in pairs(db) do l[#l + 1] = { name = n, aura = p.aura } end
  table.sort(l, function(a, b) return a.aura > b.aura end)
  return l
end
local function rankOf(name)
  for i, e in ipairs(sorted()) do if e.name == name then return i end end
  return "?"
end

---------------------------------------------------------------- state
local lastEvent = "waiting for someone to walk in..."
local lastColor = colors.lightGray
local dirty = true
local flashes = {}
local outbox = {}
local present = {}

---------------------------------------------------------------- chat
local C = { gain = "light_purple", loss = "red", gold = "gold", name = "aqua", dim = "gray", white = "white" }

local function say(parts, target)
  outbox[#outbox + 1] = { parts = parts, target = target, tries = 0 }
end
local function toast(target, title, msg)
  outbox[#outbox + 1] = { toast = true, target = target, title = title, msg = msg, tries = 0 }
end
local function plain(parts)
  local s = ""
  for _, p in ipairs(parts) do s = s .. (p.text or "") end
  return s
end
local function amt(n) return (n >= 0 and "+" or "") .. lib.commas(n) .. " aura" end

-- Advanced Peripherals changed the chat box API: newer versions take an options table
-- ({prefix=, brackets=, bracketColor=}), older ones take them as separate arguments.
-- we try both and remember whichever one works.
local style       -- "new" or "old", learned from the first message that goes through
local chatErr     -- last error the chat box gave us

local function opts()
  return { prefix = CFG.prefix, brackets = CFG.brackets, bracketColor = CFG.bracketColor }
end

local function chatError(msg)
  chatErr = msg
  lastEvent = "chat box error: " .. tostring(msg)
  lastColor = colors.red
  dirty = true
  local f = fs.open("aura.log", "a")
  if f then f.writeLine(os.date("%H:%M:%S") .. " " .. tostring(msg)) f.close() end
  if mon then printError(lastEvent) end
end

-- returns "sent", "cooldown" or "error"
local function attempt(newFn, oldFn)
  local order = (style == "old") and { { "old", oldFn }, { "new", newFn } } or { { "new", newFn }, { "old", oldFn } }
  local errs = {}
  for _, o in ipairs(order) do
    local ok, res, err = pcall(o[2])
    if ok and res then
      style = o[1]
      return "sent"
    end
    local msg = tostring(ok and err or res)
    if ok and msg:lower():find("cool") then return "cooldown" end
    errs[#errs + 1] = o[1] .. ": " .. msg
  end
  chatErr = table.concat(errs, " | ")
  return "error"
end

-- returns true when the item is finished (sent, or given up on)
local function trySend(item)
  if not chat then return true end
  local r
  if item.toast then
    r = attempt(
      function()
        local o = opts()
        o.message, o.title, o.player = item.msg, item.title, item.target
        return chat.sendToastToPlayer(o)
      end,
      function()
        return chat.sendToastToPlayer(item.msg, item.title, item.target, CFG.prefix, CFG.brackets, CFG.bracketColor)
      end)
  else
    local json = textutils.serializeJSON({ { text = "" }, table.unpack(item.parts) })
    if item.target then
      r = attempt(
        function() return chat.sendFormattedMessageToPlayer(json, item.target, opts()) end,
        function() return chat.sendFormattedMessageToPlayer(json, item.target, CFG.prefix, CFG.brackets, CFG.bracketColor) end)
    else
      r = attempt(
        function() return chat.sendFormattedMessage(json, opts()) end,
        function() return chat.sendFormattedMessage(json, CFG.prefix, CFG.brackets, CFG.bracketColor) end)
    end
    if r == "error" then
      -- formatted failed both ways: try plain text
      local text = plain(item.parts)
      if item.target then
        r = attempt(
          function() return chat.sendMessageToPlayer(text, item.target, opts()) end,
          function() return chat.sendMessageToPlayer(text, item.target, CFG.prefix, CFG.brackets, CFG.bracketColor) end)
      else
        r = attempt(
          function() return chat.sendMessage(text, opts()) end,
          function() return chat.sendMessage(text, CFG.prefix, CFG.brackets, CFG.bracketColor) end)
      end
    end
  end
  if r == "sent" then return true end
  if r == "cooldown" then return false end
  chatError(chatErr)
  return true
end

local function outboxLoop()
  while true do
    if #outbox > 0 then
      local item = outbox[1]
      if trySend(item) then
        table.remove(outbox, 1)
      else
        item.tries = item.tries + 1
        if item.tries > 8 then table.remove(outbox, 1) end
      end
      sleep(1.1) -- chat box has a cooldown
    else
      sleep(0.2)
    end
  end
end

---------------------------------------------------------------- aura logic
local GAIN = {
  "walked in like they own the place",
  "main character entrance",
  "the music changed when they walked in",
  "unbothered. moisturized. in their lane.",
  "made eye contact with the cannon and didn't blink",
  "walked in slow motion",
  "didn't even look at the explosion",
}
local LOSS = {
  "tripped on the doorframe",
  "walked in during someone else's monologue",
  "forgot to sprint",
  "entered crouching (suspicious)",
  "said 'hey guys' to an empty room",
  "got stuck on a slab",
}

local function award(name, amount, reason, big, label)
  local p = get(name)
  p.aura = p.aura + amount
  save()
  local good = amount >= 0
  lastEvent = name .. " " .. (good and "+" or "") .. lib.commas(amount) .. "  " .. reason
  lastColor = good and colors.magenta or colors.red
  dirty = true
  flashes[#flashes + 1] = { name = name, amount = amount, good = good, big = big, label = label }
  if mon then print(lastEvent) end
end

local function judge(name)
  local r = math.random()
  local amount, reason, big
  if r < 0.05 then
    amount, reason, big = 10000, "MAIN CHARACTER ENERGY", true
  elseif r < 0.09 then
    amount, reason, big = -10000, "CAUGHT LACKING", true
  elseif r < 0.70 then
    amount, reason = math.random(100, 999), pick(GAIN)
  else
    amount, reason = -math.random(50, 500), pick(LOSS)
  end
  award(name, amount, reason, big)
  say({
    { text = name, color = C.name, bold = true },
    { text = " " .. reason .. " ", color = C.white },
    { text = amt(amount), color = amount >= 0 and C.gain or C.loss, bold = true },
  })
  if big then toast(name, amount > 0 and "+10,000 AURA" or "-10,000 AURA", reason) end
end

local function help(user)
  say({
    { text = "aura commands", color = C.gold, bold = true },
    { text = "\n!aura  !aura top  !aura <name>  !farm  !mog <name>", color = C.white },
    { text = "\n(use $ instead of ! to hide your message)", color = C.dim },
  }, user)
end

local function cmdAura(user, arg)
  if arg:lower() == "top" then
    local parts = { { text = "aura leaderboard", color = C.gold, bold = true } }
    for i, e in ipairs(sorted()) do
      if i > 5 then break end
      parts[#parts + 1] = { text = "\n#" .. i .. " ", color = C.dim }
      parts[#parts + 1] = { text = e.name, color = C.name }
      parts[#parts + 1] = { text = "  " .. lib.commas(e.aura), color = e.aura >= 0 and C.gain or C.loss }
    end
    say(parts)
    return
  end
  local who
  if arg ~= "" then
    who = findName(arg)
    if not who then say({ { text = arg .. " has no aura on record. tragic.", color = C.dim } }) return end
  else
    who = user
    get(user)
  end
  local p = db[who]
  say({
    { text = who, color = C.name, bold = true },
    { text = " has ", color = C.white },
    { text = lib.commas(p.aura) .. " aura", color = p.aura >= 0 and C.gain or C.loss, bold = true },
    { text = " (rank #" .. rankOf(who) .. ")", color = C.dim },
  })
end

local function cmdFarm(user)
  local p = get(user)
  local t = now()
  if t - (p.farmed or 0) < CFG.farmCooldown then
    p.farmed = t -- spamming resets your cooldown too
    award(user, -150, "got caught aura farming")
    say({
      { text = user, color = C.name, bold = true },
      { text = " got caught aura farming ", color = C.white },
      { text = amt(-150), color = C.loss, bold = true },
    })
  else
    p.farmed = t
    local n = math.random(10, 250)
    award(user, n, "farmed some aura")
    say({
      { text = user, color = C.name, bold = true },
      { text = " quietly farmed ", color = C.white },
      { text = amt(n), color = C.gain, bold = true },
    })
  end
end

local function cmdMog(user, arg)
  if arg == "" then say({ { text = "usage: !mog <player>", color = C.dim } }, user) return end
  local target = findName(arg)
  if not target then say({ { text = "who is " .. arg .. "? no aura on record", color = C.dim } }) return end
  if target == user then
    award(user, -500, "tried to mog themselves")
    say({
      { text = user, color = C.name, bold = true },
      { text = " tried to mog themselves ", color = C.white },
      { text = amt(-500), color = C.loss, bold = true },
    })
    return
  end
  local p = get(user)
  local t = now()
  if t - (p.mogged or 0) < CFG.mogCooldown then
    say({ { text = "calm down. mog cooldown: " .. math.ceil(CFG.mogCooldown - (t - p.mogged)) .. "s", color = C.dim } }, user)
    return
  end
  p.mogged = t
  local a, b = p.aura, get(target).aura
  local edge = math.max(-0.25, math.min(0.25, (a - b) / (math.abs(a) + math.abs(b) + 1000) * 0.5))
  local stake = math.random(100, 1500)
  local winner, loser = target, user
  if math.random() < 0.5 + edge then winner, loser = user, target end
  get(loser).aura = get(loser).aura - stake
  award(winner, stake, "mogged " .. loser, false, "MOGGED")
  say({
    { text = winner, color = C.name, bold = true },
    { text = " mogged ", color = C.white },
    { text = loser, color = C.name, bold = true },
    { text = "  +" .. lib.commas(stake) .. " / -" .. lib.commas(stake), color = C.gold, bold = true },
  })
end

local function onClick(user)
  local p = get(user)
  local t = now()
  if t - (p.clicked or 0) < CFG.clickCooldown then
    p.clicked = t
    award(user, -50, "stop poking the detector")
    say({ { text = user, color = C.name, bold = true }, { text = " won't stop poking the detector ", color = C.white },
      { text = amt(-50), color = C.loss, bold = true } })
    return
  end
  p.clicked = t
  local n = math.random(-100, 300)
  award(user, n, "vibe check")
  say({ { text = user, color = C.name, bold = true }, { text = " got vibe checked ", color = C.white },
    { text = amt(n), color = n >= 0 and C.gain or C.loss, bold = true } })
end

local function onChat(user, msg)
  local cmd, arg = msg:match("^[!$](%S+)%s*(.-)%s*$")
  if not cmd then return end
  cmd = cmd:lower()
  if cmd == "aura" then
    if arg:lower() == "help" then help(user) else cmdAura(user, arg) end
  elseif cmd == "farm" then cmdFarm(user)
  elseif cmd == "mog" then cmdMog(user, arg)
  elseif cmd == "aurahelp" then help(user)
  end
end

---------------------------------------------------------------- loops
local function detectLoop()
  if not detector then while true do sleep(3600) end end
  while true do
    local ok, list = pcall(detector.getPlayersInRange, CFG.range)
    if ok and type(list) == "table" then
      local seen = {}
      for _, entry in ipairs(list) do
        local name = type(entry) == "table" and (entry.name or entry.username) or entry
        seen[name] = true
        if not present[name] then
          local p = get(name)
          if now() - (p.judged or 0) >= CFG.rejudge then
            p.judged = now()
            judge(name)
          end
        end
      end
      present = seen
    end
    sleep(1)
  end
end

local function isUUID(s)
  return type(s) == "string" and s:match("^%x+%-%x+%-%x+%-%x+%-%x+$") ~= nil
end

local function eventLoop()
  while true do
    local e, a, b, c = os.pullEvent()
    if e == "chat" then
      -- new AP: uuid, username, message   old AP: username, message, uuid
      local user, msg
      if a == nil or isUUID(a) then user, msg = b, c else user, msg = a, b end
      if type(user) == "string" and type(msg) == "string" and user ~= "[say]" then
        onChat(user, msg)
      end
    elseif e == "playerClick" or e == "player_click" then
      local user = isUUID(a) and b or a
      if type(user) == "string" then onClick(user) end
    elseif e == "monitor_touch" then
      local top = sorted()[1]
      if top then flashes[#flashes + 1] = { name = top.name, good = top.aura >= 0, label = "AURA KING" } end
    elseif e == "monitor_resize" or e == "term_resize" then
      dirty = true
    end
  end
end

---------------------------------------------------------------- drawing
local GRAD = { "a", "a", "2", "2", "6", "6", "0", "6", "2" } -- purple > magenta > pink > white
local function gradHex(i, off) return GRAD[((i + off) % #GRAD) + 1] end

local function centre(y, text, fg, bg)
  local w = out.getSize()
  out.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
  if bg then out.setBackgroundColor(bg) end
  out.setTextColor(fg)
  out.write(text)
end

local function drawShimmer(off)
  local w = out.getSize()
  local bg = {}
  for x = 1, w do bg[x] = gradHex(math.floor(x / 2), off) end
  local s = table.concat(bg)
  out.setCursorPos(1, 1) out.blit(string.rep(" ", w), string.rep("f", w), s)
  out.setCursorPos(1, 3) out.blit(string.rep(" ", w), string.rep("f", w), s:reverse())
  local title = w >= 22 and " AURA LEADERBOARD " or "AURA"
  local fg = {}
  for i = 1, #title do fg[i] = gradHex(i, -off) end
  out.setCursorPos(1, 2) out.blit(string.rep(" ", w), string.rep("0", w), string.rep("f", w))
  out.setCursorPos(math.floor((w - #title) / 2) + 1, 2)
  out.blit(title, table.concat(fg), string.rep("f", #title))
end

local function drawBoard()
  local w, h = out.getSize()
  out.setBackgroundColor(colors.black)
  out.clear()
  local list = sorted()
  local maxAbs = 1
  for _, e in ipairs(list) do maxAbs = math.max(maxAbs, math.abs(e.aura)) end
  local rows = h - 6
  for i = 1, math.min(#list, rows) do
    local e = list[i]
    local y = 4 + i
    local val = lib.commas(e.aura)
    local rankCol = i == 1 and colors.yellow or i == 2 and colors.lightGray or i == 3 and colors.orange or colors.gray
    out.setCursorPos(2, y) out.setTextColor(rankCol) out.write("#" .. i)
    local nameMax = math.max(3, w - #val - 8)
    out.setCursorPos(6, y) out.setTextColor(i <= 3 and colors.white or colors.lightGray)
    out.write(e.name:sub(1, nameMax))
    local barStart, barEnd = 23, w - #val - 2
    if barEnd - barStart >= 4 then
      local len = math.floor((barEnd - barStart + 1) * math.abs(e.aura) / maxAbs + 0.5)
      if len > 0 then
        out.setCursorPos(barStart, y)
        out.setBackgroundColor(e.aura >= 0 and colors.purple or colors.red)
        out.write(string.rep(" ", len))
        out.setBackgroundColor(colors.black)
      end
    end
    out.setTextColor(e.aura >= 0 and colors.magenta or colors.red)
    out.setCursorPos(w - #val, y) out.write(val)
  end
  if #list == 0 then centre(math.floor(h / 2) + 1, "nobody has aura yet. walk up.", colors.gray) end
  out.setCursorPos(1, h - 1) out.setTextColor(colors.gray) out.write(string.rep("-", w))
  out.setCursorPos(2, h) out.setTextColor(lastColor) out.write(lastEvent:sub(1, w - 2))
end

local function pulse()
  if CFG.rsSide then
    redstone.setOutput(CFG.rsSide, true)
    sleep(0.3)
    redstone.setOutput(CFG.rsSide, false)
  end
end

local function doFlash(f)
  local w, h = out.getSize()
  local bgCol = f.good and colors.purple or colors.red
  local bgHex = f.good and "a" or "e"
  local amountStr = f.label or ((f.amount >= 0 and "+" or "") .. lib.commas(f.amount))
  for _ = 1, 3 do -- strobe
    out.setBackgroundColor(colors.white) out.clear() sleep(0.05)
    out.setBackgroundColor(bgCol) out.clear() sleep(0.05)
  end
  local lines = { f.name:upper(), amountStr }
  local sc, xs = lib.fitLines(lines, w - 2, h - 2)
  local plainName = false
  if sc < 1 then
    lines = { amountStr }
    sc, xs = lib.fitLines(lines, w - 2, h - 4)
    plainName = true
  end
  sc = math.min(4, sc)
  if sc >= 1 then
    local grid = lib.grid(w, h, bgHex)
    lib.stamp(grid, lines, sc, "0", "f", plainName and 1 or 0, xs)
    lib.blitGrid(out, grid, "0")
    if plainName then centre(2, f.name, colors.white, bgCol) end
  else
    centre(math.floor(h / 2), f.name, colors.white, bgCol)
    centre(math.floor(h / 2) + 1, amountStr, colors.white, bgCol)
  end
  pulse()
  sleep(f.big and 3 or 1.8)
  out.setBackgroundColor(colors.black)
  dirty = true
end

local function animLoop()
  local off = 0
  while true do
    if #flashes > 0 then doFlash(table.remove(flashes, 1)) end
    if dirty then drawBoard() dirty = false end
    drawShimmer(off)
    off = off + 1
    sleep(0.15)
  end
end

---------------------------------------------------------------- go
load()
if mon then mon.setTextScale(CFG.textScale) end
term.setBackgroundColor(colors.black)
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.magenta)
print("aura detector online")
term.setTextColor(colors.white)
print(" detector: " .. (detector and "yes" or "MISSING (no arrival judging)"))
print(" chat box: " .. (chat and "yes" or "MISSING (no chat commands)"))
print(" monitor : " .. (mon and "yes" or "no (using this screen)"))
print("chat: !aura  !aura top  !farm  !mog <name>")
print("ctrl+T to stop")
if chat then
  say({ { text = "aura system online. ", color = C.gain, bold = true }, { text = "type !aurahelp", color = C.dim } })
end
sleep(mon and 0 or 2)

local ok, err = pcall(parallel.waitForAny, detectLoop, eventLoop, outboxLoop, animLoop)
save()
out.setBackgroundColor(colors.black)
out.setTextColor(colors.white)
out.clear()
out.setCursorPos(1, 1)
if not ok and err ~= "Terminated" then printError(err) end
