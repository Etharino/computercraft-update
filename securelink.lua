--[[
  securelink.lua  -  signed + encrypted messages for ComputerCraft
  ----------------------------------------------------------------
  Used by relay_base.lua (sender) and evidencelog.lua (receiver).

  Every packet is:
    * ENCRYPTED  - stream cipher built from HMAC-SHA256 (counter mode),
                   with a fresh random nonce per message
    * SIGNED     - HMAC-SHA256 over the whole packet (encrypt-then-MAC)
    * FRESH      - carries a sequence number (send time in ms). The
                   receiver rejects anything older than the last good
                   packet or more than MAX_AGE_MS away from its clock,
                   so old packets can't be replayed.

  Both sides need the same secret key (made by `relay_base setup`).
  Anyone listening on the channel sees only random-looking bytes, and
  anything they forge or replay is rejected.
]]

local M = {}
M.MAX_AGE_MS = 30000

local bit = bit32
local band, bor, bxor, bnot, rshift, rrotate =
  bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift, bit.rrotate
local unpack = table.unpack or unpack
local MOD = 4294967296

---------------------------------------------------------------------
-- SHA-256 / HMAC-SHA256
---------------------------------------------------------------------
local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function sha256(msg)
  local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
  local ml = #msg
  local bits = ml * 8
  local len = {}
  for i = 8, 1, -1 do len[i] = string.char(bits % 256); bits = math.floor(bits / 256) end
  msg = msg .. "\128" .. string.rep("\0", (55 - ml) % 64) .. table.concat(len)

  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 63 do
      local x, y = w[i - 15], w[i - 2]
      local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
      local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % MOD
    end
    local a, b, c, d, e, f, g, h = unpack(H)
    for i = 0, 63 do
      local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local t1 = (h + S1 + ch + K[i + 1] + w[i]) % MOD
      local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) % MOD, c, b, a, (t1 + S0 + maj) % MOD
    end
    H[1] = (H[1] + a) % MOD; H[2] = (H[2] + b) % MOD
    H[3] = (H[3] + c) % MOD; H[4] = (H[4] + d) % MOD
    H[5] = (H[5] + e) % MOD; H[6] = (H[6] + f) % MOD
    H[7] = (H[7] + g) % MOD; H[8] = (H[8] + h) % MOD
  end

  local out = {}
  for i = 1, 8 do
    local v = H[i]
    out[#out + 1] = string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
                                math.floor(v / 256) % 256, v % 256)
  end
  return table.concat(out)
end

local function hmac(key, msg)
  if #key > 64 then key = sha256(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local k = key:byte(i)
    ipad[i] = string.char(bxor(k, 0x36))
    opad[i] = string.char(bxor(k, 0x5c))
  end
  return sha256(table.concat(opad) .. sha256(table.concat(ipad) .. msg))
end

M.sha256, M.hmac = sha256, hmac

---------------------------------------------------------------------
-- Encoding helpers
---------------------------------------------------------------------
local function toHex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
local function fromHex(h)
  if type(h) ~= "string" or #h % 2 ~= 0 or h:find("[^0-9a-fA-F]") then return nil end
  return (h:gsub("..", function(x) return string.char(tonumber(x, 16)) end))
end
M.toHex, M.fromHex = toHex, fromHex

-- Constant-time compare (doesn't leak where the strings differ).
local function sameBytes(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  local diff = 0
  for i = 1, #a do diff = bor(diff, bxor(a:byte(i), b:byte(i))) end
  return diff == 0
end

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

local seeded = false
local function seed()
  if seeded then return end
  seeded = true
  local id = (os.getComputerID and os.getComputerID()) or 0
  math.randomseed((os.epoch("utc") % 2147483647) + id * 7919 + math.floor(os.clock() * 1000))
  for _ = 1, 50 do math.random() end
end

---------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------
-- New shared secret, as 32 hex characters (128 bits).
function M.newSecret()
  seed()
  local raw = randomBytes(32) .. tostring(os.epoch("utc")) .. tostring(os.clock())
  return toHex(sha256(raw)):sub(1, 32)
end

-- Derive separate keys for encryption, signing and the channel number.
function M.keys(secretHex)
  local secret = fromHex(secretHex)
  if not secret or #secret < 16 then return nil, "bad key (need 32 hex characters)" end
  local ch = hmac(secret, "channel")
  return {
    enc = hmac(secret, "encrypt"),
    mac = hmac(secret, "sign"),
    channel = (ch:byte(1) * 256 + ch:byte(2)) % 60000 + 1000,
  }
end

---------------------------------------------------------------------
-- Encryption (HMAC-SHA256 counter-mode keystream)
---------------------------------------------------------------------
local function crypt(encKey, nonce, data)
  local out, block = {}, 0
  for i = 1, #data, 32 do
    local ks = hmac(encKey, nonce .. ":" .. block)
    block = block + 1
    local chunk = data:sub(i, i + 31)
    local t = {}
    for j = 1, #chunk do t[j] = string.char(bxor(chunk:byte(j), ks:byte(j))) end
    out[#out + 1] = table.concat(t)
  end
  return table.concat(out)
end

---------------------------------------------------------------------
-- Seal / open
---------------------------------------------------------------------
-- plaintext: string. Returns a table ready for modem.transmit.
function M.seal(keys, plaintext)
  seed()
  local seq = os.epoch("utc")
  local nonce = toHex(randomBytes(12))
  local cipher = toHex(crypt(keys.enc, nonce .. ":" .. seq, plaintext))
  local body = "SL1|" .. nonce .. "|" .. seq .. "|" .. cipher
  return { v = "SL1", n = nonce, s = seq, c = cipher, m = toHex(hmac(keys.mac, body)) }
end

-- state: table kept by the receiver (remembers the last good sequence).
-- Returns plaintext, or nil + reason ("forged", "replay", "stale", ...).
function M.open(keys, state, packet)
  if type(packet) ~= "table" or packet.v ~= "SL1" then return nil, "not ours" end
  local n, s, c, m = packet.n, tonumber(packet.s), packet.c, packet.m
  if type(n) ~= "string" or not s or type(c) ~= "string" or type(m) ~= "string" then
    return nil, "malformed"
  end
  local body = "SL1|" .. n .. "|" .. packet.s .. "|" .. c
  if not sameBytes(fromHex(m), hmac(keys.mac, body)) then return nil, "forged" end
  if state.lastSeq and s <= state.lastSeq then return nil, "replay" end
  if math.abs(os.epoch("utc") - s) > M.MAX_AGE_MS then return nil, "stale" end
  local raw = fromHex(c)
  if not raw then return nil, "malformed" end
  state.lastSeq = s
  return crypt(keys.enc, n .. ":" .. s, raw)
end

---------------------------------------------------------------------
-- Inventory payload (simple text format, no code is ever loaded)
---------------------------------------------------------------------
-- data = { owner = "name", online = true, items = { [id] = count } }
function M.encodeInventory(data)
  local lines = { tostring(data.owner or ""), data.online and "1" or "0" }
  for id, count in pairs(data.items or {}) do
    lines[#lines + 1] = id .. " " .. math.floor(count)
  end
  return table.concat(lines, "\n")
end

function M.decodeInventory(text)
  local data, i = { items = {}, total = 0 }, 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    if i == 1 then data.owner = line ~= "" and line or nil
    elseif i == 2 then data.online = line == "1"
    else
      local id, count = line:match("^(%S+) (%d+)$")
      if id then
        data.items[id] = tonumber(count)
        data.total = data.total + tonumber(count)
      end
    end
  end
  return data
end

-- Key file helpers
M.KEY_FILE = "/.relay_key"
function M.loadSecret()
  if not fs.exists(M.KEY_FILE) then return nil end
  local f = fs.open(M.KEY_FILE, "r")
  local s = f.readAll(); f.close()
  return (s:gsub("%s", ""))
end
function M.saveSecret(secretHex)
  local f = fs.open(M.KEY_FILE, "w")
  f.write(secretHex); f.close()
end

return M
