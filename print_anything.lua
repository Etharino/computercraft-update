-- Print Anything for ComputerCraft / CC:Tweaked
-- Prints typed text, text files, and simple image files as ASCII art.

local printer = peripheral.find("printer")

if not printer then
  error("No printer found. Place a printer next to the computer or connect one with a modem.", 0)
end

local function pause()
  write("\nPress any key to continue...")
  os.pullEvent("key")
  print()
end

local function inkAndPaperOk()
  if printer.getPaperLevel and printer.getPaperLevel() <= 0 then
    print("The printer has no paper.")
    return false
  end

  if printer.getInkLevel and printer.getInkLevel() <= 0 then
    print("The printer has no ink.")
    return false
  end

  return true
end

local function startPage(title)
  if not inkAndPaperOk() then return false end

  if not printer.newPage() then
    print("Could not start a new page. Check paper and ink.")
    return false
  end

  if printer.setPageTitle then
    printer.setPageTitle(title or "Print job")
  end

  printer.setCursorPos(1, 1)
  return true
end

local function finishPage()
  if not printer.endPage() then
    print("The printer could not finish the page.")
    return false
  end
  return true
end

local function wrapLine(line, width)
  local out = {}

  while #line > width do
    local cut = width
    for i = width, 1, -1 do
      local ch = line:sub(i, i)
      if ch == " " or ch == "\t" then
        cut = i
        break
      end
    end

    local piece = line:sub(1, cut)
    piece = piece:gsub("%s+$", "")
    if piece == "" then piece = line:sub(1, width) end
    table.insert(out, piece)

    line = line:sub(cut + 1):gsub("^%s+", "")
  end

  table.insert(out, line)
  return out
end

local function makePrintableLines(text, width)
  local lines = {}

  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local wrapped = wrapLine(line, width)
    for i = 1, #wrapped do
      table.insert(lines, wrapped[i])
    end
  end

  return lines
end

local function printLines(lines, title)
  local width, height = printer.getPageSize()
  local page = 1
  local y = 1

  if not startPage(title) then return false end

  for i = 1, #lines do
    if y > height then
      if not finishPage() then return false end
      page = page + 1
      if not startPage((title or "Print job") .. " " .. page) then return false end
      y = 1
    end

    printer.setCursorPos(1, y)
    printer.write(lines[i]:sub(1, width))
    y = y + 1
  end

  return finishPage()
end

local function readTypedText()
  print("Type what you want to print.")
  print("Put a single . on its own line when you are done.\n")

  local lines = {}
  while true do
    write("> ")
    local line = read()
    if line == "." then break end
    table.insert(lines, line)
  end

  return table.concat(lines, "\n")
end

local function readFile(path)
  if not fs.exists(path) then
    print("File not found: " .. path)
    return nil
  end

  if fs.isDir(path) then
    print("That path is a folder, not a file.")
    return nil
  end

  local handle = fs.open(path, "r")
  local data = handle.readAll()
  handle.close()
  return data
end

local function isNfpPixel(ch)
  if ch == " " or ch == "." or ch == "-" then return false end
  if ch == "f" or ch == "F" then return false end
  return ch:match("[0-9a-eA-E]") ~= nil or ch == "#"
end

local function looksLikeNfp(lines)
  local sawColor = false

  for i = 1, #lines do
    local line = lines[i]
    if line:find("[^0-9a-fA-F%s]") then
      return false
    end
    if line:find("[0-9a-eA-E]") then
      sawColor = true
    end
  end

  return sawColor
end

local function loadImageAsAscii(path, width, height)
  local data = readFile(path)
  if not data then return nil end

  local sourceLines = {}
  local result = {}
  data = data:gsub("\r\n", "\n"):gsub("\r", "\n")

  for line in (data .. "\n"):gmatch("(.-)\n") do
    table.insert(sourceLines, line)
  end

  local nfp = looksLikeNfp(sourceLines)

  for i = 1, #sourceLines do
    local line = sourceLines[i]
    local out = {}
    local maxX = math.min(#line, width)

    for x = 1, maxX do
      local ch = line:sub(x, x)
      if nfp and isNfpPixel(ch) then
        table.insert(out, "#")
      elseif nfp then
        table.insert(out, " ")
      else
        table.insert(out, ch)
      end
    end

    table.insert(result, table.concat(out))
    if #result >= height then break end
  end

  return result
end

local function printTypedText()
  local width = printer.getPageSize()
  local text = readTypedText()

  if text == "" then
    print("Nothing to print.")
    return
  end

  local lines = makePrintableLines(text, width)
  if printLines(lines, "Typed text") then
    print("Printed typed text.")
  end
end

local function printTextFile()
  write("Text file path: ")
  local path = read()
  local data = readFile(path)
  if not data then return end

  local width = printer.getPageSize()
  local lines = makePrintableLines(data, width)
  if printLines(lines, fs.getName(path)) then
    print("Printed " .. path)
  end
end

local function printImageFile()
  local width, height = printer.getPageSize()

  print("Use a ComputerCraft paint/NFP file or a text-art file.")
  print("The image will be printed in black and white.")
  write("Image file path: ")
  local path = read()

  local lines = loadImageAsAscii(path, width, height)
  if not lines then return end

  if #lines == 0 then
    print("That image file is empty.")
    return
  end

  if printLines(lines, fs.getName(path)) then
    print("Printed image " .. path)
  end
end

local function showStatus()
  print("\nPrinter status")
  if printer.getPaperLevel then
    print("Paper: " .. printer.getPaperLevel())
  else
    print("Paper: unknown")
  end

  if printer.getInkLevel then
    print("Ink: " .. printer.getInkLevel())
  else
    print("Ink: unknown")
  end

  local width, height = printer.getPageSize()
  print("Page size: " .. width .. " x " .. height)
end

while true do
  term.clear()
  term.setCursorPos(1, 1)
  print("Print Anything")
  print("==============")
  showStatus()
  print("\n1. Print typed text")
  print("2. Print a text file")
  print("3. Print an image file")
  print("4. Exit")
  write("\nChoose: ")

  local choice = read()
  print()

  if choice == "1" then
    printTypedText()
    pause()
  elseif choice == "2" then
    printTextFile()
    pause()
  elseif choice == "3" then
    printImageFile()
    pause()
  elseif choice == "4" or choice:lower() == "exit" then
    break
  else
    print("Choose 1, 2, 3, or 4.")
    pause()
  end
end
