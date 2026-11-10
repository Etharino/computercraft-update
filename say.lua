-- say.lua :: send chat messages through the chat box, formatted like a normal
-- player message: "<wainuiomata>: your text" with the name in green (&2 / dark_green).
--
-- usage:
--   say hello there          -- sends one message and exits
--   say                      -- no args: opens a prompt, type a line + enter to send,
--                               blank line or "exit" to quit

local args = { ... }

local NAME = "wainuiomata"      -- change this if you want a different label
local NAME_COLOR = "dark_green" -- &2

local chat = peripheral.find("chat_box") or peripheral.find("chatBox")
if not chat then
  printError("no chat box found. is it touching this computer?")
  return
end

local chatStyle -- "new" or "old", learned on first successful send

local function send(message)
  local parts = {
    { text = "" },
    { text = "<" .. NAME .. "> ", color = NAME_COLOR, bold = true },
    { text = message, color = "white" },
  }
  local json = textutils.serializeJSON(parts)
  local order = (chatStyle == "old") and { "old", "new" } or { "new", "old" }
  for _, style in ipairs(order) do
    local ok, res = pcall(function()
      if style == "new" then
        return chat.sendFormattedMessage(json, { prefix = "", brackets = "  ", bracketColor = "&f" })
      else
        return chat.sendFormattedMessage(json, "", "  ", "&f")
      end
    end)
    if ok and res then chatStyle = style return true end
    if ok and res == nil then return false, "cooldown" end -- rate limited, caller can retry
  end
  -- both formatted styles failed outright: fall back to plain text
  local ok = pcall(chat.sendMessage, "<" .. NAME .. "> " .. message, "", "  ", "&f")
  return ok
end

local function sendWithRetry(message)
  for _ = 1, 10 do
    local ok, reason = send(message)
    if ok then return true end
    if reason ~= "cooldown" then return false end
    sleep(1.1)
  end
  return false
end

if #args > 0 then
  local message = table.concat(args, " ")
  if sendWithRetry(message) then
    print("sent: <" .. NAME .. "> " .. message)
  else
    printError("failed to send. try 'chattest' to see what the chat box is doing.")
  end
  return
end

print("say  --  type a message and press enter to send it as <" .. NAME .. ">")
print("blank line or 'exit' to quit")
while true do
  write("> ")
  local line = read()
  if not line or line == "" or line == "exit" then break end
  if sendWithRetry(line) then
    print("sent")
  else
    printError("failed to send")
  end
end
