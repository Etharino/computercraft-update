-- Player dimension tracker for CC:Tweaked / ComputerCraft command computers.
-- Requires a Command Computer or another setup that exposes the `commands` API.

local dimensions = {
  { id = "minecraft:overworld", label = "Overworld" },
  { id = "minecraft:the_nether", label = "Nether" },
  { id = "minecraft:the_end", label = "End" },
}

local args = { ... }
local player = args[1]
local interval = tonumber(args[2]) or 5

local function usage()
  print("Usage:")
  print("  player_tracker <playerName> [seconds]")
  print("")
  print("Example:")
  print("  player_tracker Steve 3")
end

local function isValidPlayerName(name)
  return type(name) == "string" and name:match("^[A-Za-z0-9_]+$") ~= nil
end

local function requireCommandsApi()
  if not commands or type(commands.exec) ~= "function" then
    error("This program needs a Command Computer with the commands API.", 0)
  end
end

local function selectorFor(name)
  return "@a[name=" .. name .. ",limit=1]"
end

local function run(command)
  local ok, output = commands.exec(command)
  return ok == true, output
end

local function playerExistsAnywhere(name)
  local ok = run("execute if entity " .. selectorFor(name) .. " run data get entity " .. selectorFor(name) .. " UUID")
  return ok
end

local function playerIsInDimension(name, dimensionId)
  local selector = selectorFor(name)
  local command = "execute in " .. dimensionId .. " if entity " .. selector ..
    " run data get entity " .. selector .. " Pos"

  local ok, output = run(command)
  return ok, output
end

local function findPlayerDimension(name)
  for _, dimension in ipairs(dimensions) do
    local found, output = playerIsInDimension(name, dimension.id)
    if found then
      return dimension, output
    end
  end

  return nil, nil
end

local function firstLine(lines)
  if type(lines) == "table" then
    return lines[1]
  end

  return nil
end

local function clearScreen()
  term.clear()
  term.setCursorPos(1, 1)
end

if not player then
  usage()
  return
end

if not isValidPlayerName(player) then
  print("Player names can only use letters, numbers, and underscores.")
  return
end

requireCommandsApi()

local lastDimensionId = nil

while true do
  clearScreen()
  print("Tracking: " .. player)
  print("Refresh: " .. interval .. "s")
  print("")

  local dimension, output = findPlayerDimension(player)

  if dimension then
    print(player .. " is in: " .. dimension.label)
    print("Dimension ID: " .. dimension.id)

    local pos = firstLine(output)
    if pos then
      print("Position: " .. pos)
    end

    if lastDimensionId ~= dimension.id then
      os.queueEvent("player_dimension_changed", player, dimension.id)
      lastDimensionId = dimension.id
    end
  elseif playerExistsAnywhere(player) then
    print(player .. " exists, but was not found in the configured dimensions.")
    print("Add modded dimensions to the dimensions table at the top of this file.")
  else
    print(player .. " is offline or cannot be found.")
  end

  sleep(interval)
end