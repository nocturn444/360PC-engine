local T = ...
local rng = require("engine.rng")

local function draws(r, n, fn)
  local out = {}
  for i = 1, n do out[i] = fn and fn(r) or r:next_u32() end
  return out
end
local function same(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- known answers (checked against a C version of the algorithms); tests/console/rng_check.lua
-- has the full list, the one to run on the console
T.check(same(draws(rng.new(0):set_state("00000001000000020000000300000004"), 4), { 11520, 0, 5927040, 70819200 }),
  "xoshiro128** from the state 1, 2, 3, 4")
T.check(same(draws(rng.new(12345), 4), { 3575353468, 3112313665, 2656487748, 1903694614 }), "new(12345)")
T.check(same(draws(rng.new("hello"), 4), { 3506056910, 1937038957, 631457701, 970021486 }), "new('hello')")
T.check(same(draws(rng.streams(12345):get("level"), 4), { 2311657471, 2850510720, 1880466809, 2145551992 }), "stream level")
T.check(same(draws(rng.streams(12345):get("loot"), 4), { 821971662, 83655320, 2488952221, 2205395368 }), "stream loot")
T.check(same(draws(rng.streams(12345):get("fx"), 4), { 1679647461, 1040663828, 3039051859, 3012428375 }), "stream fx")
T.check(rng.hash("foobar") == 3214735720 and rng.hash("") == 2166136261, "FNV-1a")
local lines = {}
local wrong = assert(loadfile("tests/console/rng_check.lua"))(function(s) lines[#lines + 1] = s end)
T.check(wrong == 0 and lines[#lines]:match("^== rng: 0 of %d+ wrong ==$"), "tests/console/rng_check.lua: " .. tostring(lines[#lines]))

-- seeds: integers modulo 2^32, strings by their hash
T.check(rng.new(-1):next_u32() == rng.new(4294967295):next_u32(), "integer seeds are taken modulo 2^32")
T.check(rng.new("hello"):next_u32() == rng.new(rng.hash("hello")):next_u32(), "a string seed is its hash")
T.check(rng.new(1):next_u32() ~= rng.new(2):next_u32(), "seeds differ")
T.check(not pcall(rng.new, 1.5) and not pcall(rng.new) and not pcall(rng.new, {}), "a seed is an integer or a string")

-- int: the bounds, and every value equally likely (also when the range is not a power of 2)
local r = rng.new(2024)
for _, range in ipairs({ { 1, 6 }, { 0, 2 }, { -5, 5 }, { 10, 10 }, { 0, 1000 } }) do
  local lo, hi = range[1], range[2]
  local n, per = hi - lo + 1, 20000
  if n > 100 then per = 200 end
  local counts, inside = {}, true
  for _ = 1, n * per do
    local v = r:int(lo, hi)
    if v < lo or v > hi or v ~= math.floor(v) then inside = false end
    counts[v] = (counts[v] or 0) + 1
  end
  T.check(inside, "int stays in " .. lo .. ".." .. hi)
  -- chi-squared against the uniform distribution: mean n - 1, deviation sqrt(2 (n - 1))
  local chi = 0
  for v = lo, hi do chi = chi + ((counts[v] or 0) - per) ^ 2 / per end
  T.check(chi <= (n - 1) + 5 * math.sqrt(2 * (n - 1)), string.format("int(%d, %d) is uniform (chi2 %.1f)", lo, hi, chi))
end
T.check(r:int(3) >= 1 and r:int(1) == 1, "int(n) is int(1, n)")
local big_ok = true
for _ = 1, 1000 do
  local v = r:int(-2147483648, 2147483647)
  local w = r:int(0, 3000000000)
  if v < -2147483648 or v > 2147483647 or w < 0 or w > 3000000000 then big_ok = false end
end
T.check(big_ok, "ranges up to 2^32 values")
T.check(not pcall(r.int, r, 2, 1) and not pcall(r.int, r, 0.5, 2) and not pcall(r.int, r, 0, 4294967296), "bad ranges are refused")

-- float, chance
local fmin, fmax, sum, hits = 1, 0, 0, 0
for _ = 1, 100000 do
  local f = r:float()
  fmin, fmax, sum = math.min(fmin, f), math.max(fmax, f), sum + f
  if f * 16777216 ~= math.floor(f * 16777216) then fmin = -1 end
  if r:chance(0.3) then hits = hits + 1 end
end
T.check(fmin >= 0 and fmax < 1, "float is in [0, 1) and a multiple of 2^-24")
T.near(sum / 100000, 0.5, "float's mean", 0.01)
T.near(hits / 100000, 0.3, "chance(0.3)", 0.01)
local a, b = rng.new(5), rng.new(5)
T.check(a:chance(0) == false and a:chance(1) == true, "chance(0) and chance(1)")
b:next_u32(); b:next_u32()
T.check(a:next_u32() == b:next_u32(), "chance always takes one draw")

-- pick, shuffle, weighted: the same seed gives the same result
local items = { "a", "b", "c", "d", "e" }
T.check(same(draws(rng.new(9), 20, function(g) return (g:pick(items)) end), draws(rng.new(9), 20, function(g) return (g:pick(items)) end)),
  "pick is deterministic")
local item, index = rng.new(9):pick(items)
T.check(items[index] == item and rng.new(9):pick({}) == nil, "pick returns the item and its index; nil for an empty list")
local deck = rng.new(7):shuffle({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
T.check(same(deck, { 5, 9, 8, 2, 6, 4, 3, 10, 1, 7 }), "shuffle: the known order for seed 7")
table.sort(deck)
T.check(same(deck, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }), "shuffle keeps every item")
local firsts = {}
r = rng.new(31)
for _ = 1, 30000 do
  local d = r:shuffle({ 1, 2, 3 })
  local key = d[1] * 100 + d[2] * 10 + d[3]
  firsts[key] = (firsts[key] or 0) + 1
end
local perms, perm_ok = 0, true
for _, c in pairs(firsts) do perms = perms + 1; if math.abs(c - 5000) > 350 then perm_ok = false end end
T.check(perms == 6 and perm_ok, "shuffle: the 6 orders of 3 items are equally likely")

local loot = { { id = "coin", weight = 6 }, { id = "gem", weight = 3 }, { id = "none", weight = 0 }, { id = "key", weight = 1 } }
local counts = {}
r = rng.new(77)
for _ = 1, 100000 do
  local it = r:weighted(loot)
  counts[it.id] = (counts[it.id] or 0) + 1
end
T.near(counts.coin / 100000, 0.6, "weighted: 6 of 10", 0.01)
T.near(counts.gem / 100000, 0.3, "weighted: 3 of 10", 0.01)
T.near(counts.key / 100000, 0.1, "weighted: 1 of 10", 0.01)
T.check(counts.none == nil, "weighted: a weight of 0 is never picked")
local function ids(seed, weight, list)
  return draws(rng.new(seed), 16, function(g) return select(2, g:weighted(list or loot, weight)) end)
end
T.check(same(ids(7), ids(7)) and same(ids(7), ids(7, "weight")), "weighted is deterministic; the field defaults to 'weight'")
T.check(same(ids(7, function(it) return it.weight end), ids(7)), "weighted with a function")
T.check(same(ids(7, nil, { 5, 1, 0, 10 }), { 4, 1, 4, 4, 1, 1, 4, 4, 1, 1, 4, 4, 1, 4, 4, 4 }), "weighted on a list of numbers: the known answers")
local fr = { 0, 0 }
r = rng.new(3)
for _ = 1, 40000 do
  local _, i = r:weighted({ { w = 0.25 }, { w = 0.75 } }, "w")
  fr[i] = fr[i] + 1
end
T.near(fr[1] / 40000, 0.25, "weighted with fractions", 0.01)
T.check(not pcall(r.weighted, r, { { weight = 0 } }) and not pcall(r.weighted, r, {}) and not pcall(r.weighted, r, { { weight = -1 } }),
  "weighted refuses lists without weight, and negative weights")

-- state, clone
a = rng.new("save")
for _ = 1, 37 do a:next_u32() end
local saved = a:state()
T.check(type(saved) == "string" and #saved == 32, "the state is 32 hex digits")
local expect = draws(a, 50)
T.check(same(draws(rng.new(0):set_state(saved), 50), expect), "state and set_state: the sequence continues")
T.check(same(draws(a:set_state(saved), 50), expect), "set_state on the same generator rewinds it")
b = a:set_state(saved):clone()
a:next_u32()
T.check(b:state() == saved and same(draws(b, 50), expect), "clone is independent")
T.check(not pcall(a.set_state, a, "xyz") and not pcall(a.set_state, a, string.rep("0", 32)) and not pcall(a.set_state, a, 5),
  "set_state refuses what is not a state")

-- streams: independent of each other and of the order they are created in
local s1, s2 = rng.streams(99), rng.streams(99)
local level1 = draws(s1:get("level"), 20)
s2:get("fx"); s2:get("loot")
for _ = 1, 500 do s2:get("fx"):next_u32(); s2:get("loot"):int(1, 6) end
T.check(same(draws(s2:get("level"), 20), level1), "drawing from fx and loot does not change level")
T.check(same(draws(rng.streams(99):get("loot"), 20), draws(rng.streams(99):get("loot"), 20)), "a stream is the same every time")
T.check(s1:get("level") == s1:get("level"), "get returns the same generator")
T.check(s1:get("boss rush"):next_u32() ~= s1:get("boss rush 2"):next_u32(), "any name the game wants")
T.check(not same(draws(rng.streams(99):get("level"), 4), draws(rng.streams(99):get("loot"), 4))
  and not same(draws(rng.streams(99):get("level"), 4), draws(rng.streams(100):get("level"), 4))
  and not same(draws(rng.streams(99):get("level"), 4), draws(rng.new(99), 4)), "streams differ by name and by seed")
T.check(rng.streams("run").seed == rng.hash("run"), "streams take string seeds too")

-- streams: save and restore
local st = rng.streams("run")
st:get("level"):int(1, 100); st:get("loot"):float(); st:get("loot"):float()
local data = st:state()
T.check(data.seed == st.seed and type(data.streams.level) == "string" and data.streams.fx == nil, "the save is a plain table")
local want_level, want_loot, want_fx = draws(st:get("level"), 10), draws(st:get("loot"), 10), draws(st:get("fx"), 10)
local back = rng.streams(0):set_state(data)
T.check(same(draws(back:get("loot"), 10), want_loot) and same(draws(back:get("level"), 10), want_level)
  and same(draws(back:get("fx"), 10), want_fx), "set_state: every stream continues; a new one starts from the seed")
local held = st:get("fx")
st:set_state(data)
T.check(held == st:get("fx") and same(draws(held, 10), want_fx), "set_state rewinds streams that are not in the save, in place")
st:reset()
T.check(same(draws(st:get("level"), 4), draws(rng.streams("run"):get("level"), 4)), "reset starts again")
st:reset(12345)
T.check(st.seed == 12345 and st:get("level"):next_u32() == 2311657471, "reset with a new seed")
T.check(not pcall(st.set_state, st, "x") and not pcall(st.get, st, 5), "bad arguments are refused")

-- seed codes
T.check(rng.seed_to_code(12345) == "0000C1S" and rng.seed_to_code(4294967295) == "3ZZZZZZ" and rng.seed_to_code(0) == "0000000",
  "seed_to_code: 7 characters")
r = rng.new(1)
local round = true
for _ = 1, 2000 do
  local n = r:next_u32()
  local code = rng.seed_to_code(n)
  if #code ~= 7 or code:find("[ILOU]") or rng.code_to_seed(code) ~= n then round = false end
end
T.check(round, "seed codes round trip, without I, L, O or U")
T.check(rng.code_to_seed("c1s") == 12345 and rng.code_to_seed(" 000-0c1s ") == 12345 and rng.code_to_seed("o0il-1") == 1057,
  "typed codes: lower case, spaces, dashes, O as 0, I and L as 1")
T.check(rng.code_to_seed("4000000") == nil and rng.code_to_seed("00000000") == nil and rng.code_to_seed("") == nil
  and rng.code_to_seed("U") == nil and select(2, rng.code_to_seed("12U")) ~= nil and rng.code_to_seed(5) == nil,
  "bad codes give nil and a message")
T.check(rng.seed_number("hello") == 1335831723 and rng.seed_to_code("hello") == rng.seed_to_code(1335831723)
  and rng.new(rng.code_to_seed(rng.seed_to_code("hello"))):next_u32() == rng.new("hello"):next_u32(),
  "the code of a string seed gives the same run")

-- the source: no other random numbers, no FFI
local src = assert(io.open("engine/rng.lua")):read("*a")
local code_only = src:gsub("%-%-[^\n]*", "")
T.check(not code_only:find("math%.random") and not code_only:find("love") and not code_only:find("ffi"),
  "engine/rng.lua uses no math.random, love.math or FFI")
