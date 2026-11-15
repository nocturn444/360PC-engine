-- 360PC-Engine: seeded random numbers that are the same, bit for bit, on PC (LuaJIT with the
-- JIT) and on the console (LuaJIT interpreter, PowerPC, DUALNUM). Reference: docs/ENGINE.md.
--
-- Generator: xoshiro128** (Blackman and Vigna, public domain), 4 words of 32 bits of state.
-- Everything is done with the `bit` library on values that fit in a signed 32-bit integer:
-- the multiplications are done in limbs, so no intermediate result reaches 2^31. That keeps
-- the code away from integer overflow, from the conversion of big doubles to 32 bits and from
-- float rounding, which are the places where two LuaJIT builds could differ.
-- No math.random, no love.math, no FFI. Nothing is allocated per draw.
local bit = require("bit")
local band, bor, bxor, lshift, rshift = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local floor = math.floor

local rng = {}
local Rng = {}
Rng.__index = Rng
local Streams = {}
Streams.__index = Streams

local TWO32, TWO31 = 4294967296, 2147483648
local INV24 = 1 / 16777216   -- 2^-24, exact

-- [0, 2^32) as a number  <->  the same 32 bits as the signed integer the bit library uses
local function to_signed(n) if n >= TWO31 then return n - TWO32 end return n end
local function to_unsigned(x) if x < 0 then return x + TWO32 end return x end

-- x * k mod 2^32 for a small k (k < 2^15), in 16-bit limbs
local function mul_small(x, k)
  local lo = band(x, 0xffff) * k
  return bor(lshift(rshift(x, 16) * k + rshift(lo, 16), 16), band(lo, 0xffff))
end

-- a + b mod 2^32, in 16-bit limbs
local function add32(a, b)
  local lo = band(a, 0xffff) + band(b, 0xffff)
  return bor(lshift(rshift(a, 16) + rshift(b, 16) + rshift(lo, 16), 16), band(lo, 0xffff))
end

-- a * b mod 2^32, in limbs of 11, 11 and 10 bits: every product is under 2^22
local function mul32(a, b)
  local a0, a1, a2 = band(a, 0x7ff), band(rshift(a, 11), 0x7ff), rshift(a, 22)
  local b0, b1, b2 = band(b, 0x7ff), band(rshift(b, 11), 0x7ff), rshift(b, 22)
  local c0 = a0 * b0
  local c1 = a0 * b1 + a1 * b0 + rshift(c0, 11)
  local c2 = a0 * b2 + a1 * b1 + a2 * b0 + rshift(c1, 11)
  return bor(band(c0, 0x7ff), lshift(band(c1, 0x7ff), 11), lshift(band(c2, 0x3ff), 22))
end

-- The 32-bit finalizer of MurmurHash3 (a bijection that mixes every bit)
local function mix(x)
  x = bxor(x, rshift(x, 16))
  x = mul32(x, -2048144789)   -- 0x85ebca6b
  x = bxor(x, rshift(x, 13))
  x = mul32(x, -1028477387)   -- 0xc2b2ae35
  return bxor(x, rshift(x, 16))
end

-- FNV-1a, 32 bits, on the bytes of the string (signed result)
local function fnv1a(s)
  local h = -2128831035        -- 0x811c9dc5
  for i = 1, #s do
    h = bxor(h, s:byte(i))
    -- h * 0x01000193 = h * 0x193 + (h << 24)
    h = add32(mul_small(h, 0x193), lshift(h, 24))
  end
  return h
end

-- A seed (integer or string) as 32 bits, signed. Integers are taken modulo 2^32.
local function seed_bits(seed)
  if type(seed) == "string" then return fnv1a(seed) end
  if type(seed) ~= "number" or seed ~= floor(seed) or seed > 9007199254740992 or seed < -9007199254740992 then
    error("rng: the seed must be an integer or a string", 3)
  end
  return to_signed(seed - floor(seed / TWO32) * TWO32)
end

-- Fills the 4 words from 64 bits (a = the seed, b = the hash of the stream name or 0).
-- mix is a bijection and the 4 values of a differ, so the state is never all zeros... for one
-- b; with b in the mix it could be in theory, so that case is replaced by a fixed state.
local function fill(r, a, b)
  for i = 1, 4 do
    a = add32(a, -1640531527)  -- 0x9e3779b9
    b = add32(b, 2135587861)   -- 0x7f4a7c15
    r[i] = mix(bxor(mix(a), b))
  end
  if r[1] == 0 and r[2] == 0 and r[3] == 0 and r[4] == 0 then r[1] = 1 end
  return r
end

-- The next 32 bits, as a signed integer (what the bit library works with)
local function raw(r)
  local s0, s1, s2, s3 = r[1], r[2], r[3], r[4]
  local x = mul_small(s1, 5)
  local out = mul_small(bor(lshift(x, 7), rshift(x, 25)), 9)
  local t = lshift(s1, 9)
  s2 = bxor(s2, s0)
  s3 = bxor(s3, s1)
  r[2] = bxor(s1, s2)
  r[1] = bxor(s0, s3)
  r[3] = bxor(s2, t)
  r[4] = bor(lshift(s3, 11), rshift(s3, 21))
  return out
end

-- ---------------------------------------------------------------- generators

-- rng.new(seed): seed is an integer (taken modulo 2^32) or a string (hashed with FNV-1a).
function rng.new(seed)
  return fill(setmetatable({ 0, 0, 0, 0 }, Rng), seed_bits(seed), 0)
end

-- The next 32 bits: an integer in [0, 2^32)
function Rng:next_u32()
  return to_unsigned(raw(self))
end

-- r:int(lo, hi): an integer in [lo, hi], every value equally likely. r:int(n) is r:int(1, n).
-- Rejection with a bit mask: no division, and fewer than 2 draws on average.
function Rng:int(lo, hi)
  if hi == nil then lo, hi = 1, lo end
  local m = hi - lo
  if not (m >= 0 and m < TWO32) or lo ~= floor(lo) or hi ~= floor(hi) then
    error("rng:int(lo, hi): integers with lo <= hi and hi - lo < 2^32", 2)
  end
  if m >= TWO31 then
    local v = to_unsigned(raw(self))
    while v > m do v = to_unsigned(raw(self)) end
    return lo + v
  end
  local mask = bor(m, rshift(m, 1))
  mask = bor(mask, rshift(mask, 2))
  mask = bor(mask, rshift(mask, 4))
  mask = bor(mask, rshift(mask, 8))
  mask = bor(mask, rshift(mask, 16))
  local v = band(raw(self), mask)
  while v > m do v = band(raw(self), mask) end
  return lo + v
end

-- A number in [0, 1): k / 2^24 from the top 24 bits. Exact in a double, and still under 1
-- when something stores it in a 32-bit float.
function Rng:float()
  return rshift(raw(self), 8) * INV24
end

-- true with probability p. Always takes one draw, also for p <= 0 and p >= 1.
function Rng:chance(p)
  return rshift(raw(self), 8) * INV24 < p
end

-- One item of the list (nil, without a draw, if it is empty); also returns its index
function Rng:pick(list)
  local n = #list
  if n == 0 then return nil end
  local i = self:int(1, n)
  return list[i], i
end

local function weight_of(item, i, weight)
  local w
  if type(weight) == "function" then w = weight(item, i)
  elseif type(item) == "number" then w = item
  else w = item[weight] end
  if type(w) ~= "number" or not (w >= 0) then error("rng:weighted: weights are numbers >= 0", 3) end
  return w
end

-- r:weighted(list, weight): one item, with a probability proportional to its weight; also
-- returns its index. weight is the name of the field (default "weight"), or a function
-- (item, index) -> number (called twice per item: it must not draw or change anything); a
-- list of plain numbers is its own weights. Whole weights (the recommended kind) are exact:
-- one r:int(1, total). Weights with fractions use r:float() * total.
function Rng:weighted(list, weight)
  weight = weight or "weight"
  local n, total, whole = #list, 0, true
  for i = 1, n do
    local w = weight_of(list[i], i, weight)
    if w ~= floor(w) then whole = false end
    total = total + w
  end
  if not (total > 0) then error("rng:weighted: no item has a weight above 0", 2) end
  local last
  if whole and total < TWO32 then
    local roll, sum = self:int(1, total), 0
    for i = 1, n do
      sum = sum + weight_of(list[i], i, weight)
      if roll <= sum then return list[i], i end
    end
  else
    local roll, sum = rshift(raw(self), 8) * INV24 * total, 0
    for i = 1, n do
      local w = weight_of(list[i], i, weight)
      if w > 0 then
        sum = sum + w
        last = i
        if roll < sum then return list[i], i end
      end
    end
  end
  return list[last], last   -- only if the float sum rounded differently the second time
end

-- Shuffles the list in place (Fisher-Yates) and returns it
function Rng:shuffle(list)
  for i = #list, 2, -1 do
    local j = self:int(1, i)
    list[i], list[j] = list[j], list[i]
  end
  return list
end

local function hex(x) return string.format("%04x%04x", rshift(x, 16), band(x, 0xffff)) end

-- The state as a string of 32 hex digits (for saves), and back
function Rng:state()
  return hex(self[1]) .. hex(self[2]) .. hex(self[3]) .. hex(self[4])
end

function Rng:set_state(s)
  if type(s) ~= "string" or #s ~= 32 or s:find("[^0-9a-fA-F]") or not s:find("[^0]") then
    error("rng:set_state: not a state from rng:state()", 2)
  end
  for i = 1, 4 do
    local o = (i - 1) * 8
    self[i] = bor(lshift(tonumber(s:sub(o + 1, o + 4), 16), 16), tonumber(s:sub(o + 5, o + 8), 16))
  end
  return self
end

-- An independent copy that continues with the same numbers
function Rng:clone()
  return setmetatable({ self[1], self[2], self[3], self[4] }, Rng)
end

-- ---------------------------------------------------------------- named streams

-- rng.streams(seed): a set of generators by name, each made from (seed, name) alone. Drawing
-- from one never changes another, and the order in which they are first asked for does not
-- matter. Two names with the same FNV-1a hash (1 in 2^32 per pair) would share a sequence.
function rng.streams(seed)
  return setmetatable({ seed = to_unsigned(seed_bits(seed)), list = {} }, Streams)
end

function Streams:get(name)
  local r = self.list[name]
  if not r then
    if type(name) ~= "string" then error("streams:get(name): the name is a string", 2) end
    r = fill(setmetatable({ 0, 0, 0, 0 }, Rng), to_signed(self.seed), fnv1a(name))
    self.list[name] = r
  end
  return r
end

-- Starts again from a seed (the same one if none is given). Generators handed out by get()
-- stay valid: they are rewound in place.
function Streams:reset(seed)
  if seed ~= nil then self.seed = to_unsigned(seed_bits(seed)) end
  for name, r in pairs(self.list) do fill(r, to_signed(self.seed), fnv1a(name)) end
  return self
end

-- A plain table for saves: { seed = number, streams = { name = state string } }
function Streams:state()
  local out = { seed = self.seed, streams = {} }
  for name, r in pairs(self.list) do out.streams[name] = r:state() end
  return out
end

-- Puts a saved table back. Streams that were not in the save start from the seed again.
function Streams:set_state(data)
  if type(data) ~= "table" or type(data.streams) ~= "table" then
    error("streams:set_state: not a table from streams:state()", 2)
  end
  self:reset(data.seed)
  for name, s in pairs(data.streams) do self:get(name):set_state(s) end
  return self
end

-- ---------------------------------------------------------------- seeds for people

-- Crockford's base 32: no I, L, O or U. 7 characters hold 32 bits.
local ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
local DIGIT = {}
for i = 1, #ALPHABET do DIGIT[ALPHABET:sub(i, i)] = i - 1 end
DIGIT.O, DIGIT.I, DIGIT.L = 0, 1, 1

-- The seed as the number in [0, 2^32) that rng.new and rng.streams really use
function rng.seed_number(seed)
  return to_unsigned(seed_bits(seed))
end

-- The seed as 7 characters to show and type, like "1D7Q0ZK"
function rng.seed_to_code(seed)
  local x, out = seed_bits(seed), ""
  for shift = 30, 0, -5 do
    local d = band(rshift(x, shift), 31)
    out = out .. ALPHABET:sub(d + 1, d + 1)
  end
  return out
end

-- The number for a typed code, or nil and a message. Lower case, spaces and dashes are
-- accepted, O reads as 0, I and L as 1; fewer than 7 characters is a small number.
function rng.code_to_seed(code)
  if type(code) ~= "string" then return nil, "the code is a string" end
  local x, n = 0, 0
  for c in code:upper():gmatch("[^%s%-]") do
    local d = DIGIT[c]
    if not d then return nil, "'" .. c .. "' is not used in seed codes" end
    n = n + 1
    if n > 7 or rshift(x, 27) ~= 0 then return nil, "the code is too long" end
    x = bor(lshift(x, 5), d)
  end
  if n == 0 then return nil, "the code is empty" end
  return to_unsigned(x)
end

-- The pieces, for the tests
rng.hash = function(s) return to_unsigned(fnv1a(s)) end
rng._mix = function(n) return to_unsigned(mix(to_signed(n))) end
rng._mul32 = function(a, b) return to_unsigned(mul32(to_signed(a), to_signed(b))) end

return rng
