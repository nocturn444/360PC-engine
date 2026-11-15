-- 360PC-Engine: known answers of engine/rng.lua. The numbers below were checked against a C
-- version of the same algorithms (xoshiro128**, FNV-1a, the MurmurHash3 finalizer) and are
-- what every platform has to give: PC with and without the JIT, and the console.
-- On the PC:      luajit tests/console/rng_check.lua  and  luajit -joff tests/console/rng_check.lua
--                 (from the repository root; both must end with "== rng: 0 of 29 wrong ==")
-- On the console: copy this file next to the main.lua of a game that has engine/, add
--                 require("rng_check") as the first line of that main.lua, and read the log.
-- Called as a function with a log function as its argument, it logs there (the engine's tests do).
local arg1 = ...
local log = type(arg1) == "function" and arg1 or (l360 and l360.log) or print
local rng = require("engine.rng")
local bad, total = 0, 0

local function check(name, got, want)
  total = total + 1
  local ok = true
  if type(want) == "table" then
    ok = type(got) == "table" and #got == #want
    for i = 1, #want do ok = ok and got[i] == want[i] end
    if not ok and type(got) == "table" then
      local shown = {}
      for i = 1, #got do shown[i] = tostring(got[i]) end
      got = table.concat(shown, " ")
    end
  else
    ok = got == want
  end
  if not ok then bad = bad + 1 end
  log(string.format("%s %s%s", ok and "[ok] " or "[BAD]", name, ok and "" or (" = " .. tostring(got))))
end

local function draws(r, n, fn)
  local out = {}
  for i = 1, n do out[i] = fn(r) end
  return out
end
local function u32(r) return r:next_u32() end

-- the pieces
check("hash('')", rng.hash(""), 2166136261)
check("hash('a')", rng.hash("a"), 3826002220)
check("hash('foobar')", rng.hash("foobar"), 3214735720)
check("mix(1)", rng._mix(1), 1364076727)
check("mix(0xdeadbeef)", rng._mix(3735928559), 233162409)
check("0xdeadbeef * 0xfeedface", rng._mul32(3735928559, 4277009102), 3246918226)
-- xoshiro128** itself, from the state 1, 2, 3, 4
check("state 1,2,3,4", draws(rng.new(0):set_state("00000001000000020000000300000004"), 8, u32),
  { 11520, 0, 5927040, 70819200, 2031721883, 1637235492, 1287239034, 3734860849 })
-- seeds
check("new(0)", draws(rng.new(0), 8, u32),
  { 2939515614, 1211568703, 848028640, 3634930065, 382489747, 365503651, 1697441065, 2019721086 })
check("new(1)", draws(rng.new(1), 8, u32),
  { 429192560, 666673131, 900542034, 3673336588, 2670589754, 868592600, 2907523641, 2151869821 })
check("new(12345)", draws(rng.new(12345), 8, u32),
  { 3575353468, 3112313665, 2656487748, 1903694614, 1681078016, 3342830446, 1846638672, 2844646848 })
check("new(2^32-1)", draws(rng.new(4294967295), 8, u32),
  { 3261186586, 519261048, 1542603202, 2476999689, 2799777105, 1690204445, 3105590560, 816446726 })
check("new(-1) is new(2^32-1)", rng.new(-1):next_u32(), 3261186586)
check("new(2^32+12345) is new(12345)", rng.new(4294967296 + 12345):next_u32(), 3575353468)
check("new('hello')", draws(rng.new("hello"), 8, u32),
  { 3506056910, 1937038957, 631457701, 970021486, 1081165875, 3224850790, 3362156332, 281104892 })
-- streams
check("streams(12345) level", draws(rng.streams(12345):get("level"), 8, u32),
  { 2311657471, 2850510720, 1880466809, 2145551992, 1829719963, 1791105216, 3523038427, 352793998 })
check("streams(12345) loot", draws(rng.streams(12345):get("loot"), 8, u32),
  { 821971662, 83655320, 2488952221, 2205395368, 1140773711, 2215760469, 3750635333, 1893244448 })
check("streams(12345) fx", draws(rng.streams(12345):get("fx"), 8, u32),
  { 1679647461, 1040663828, 3039051859, 3012428375, 1301915112, 1971912764, 3001906500, 4138617016 })
check("streams('360PC') level", draws(rng.streams("360PC"):get("level"), 8, u32),
  { 651767559, 3565701519, 64458848, 4218088523, 2735228538, 102830882, 3158536037, 3704343611 })
-- a long run, and the state as a string
do
  local r = rng.new(1)
  for _ = 1, 100000 do r:next_u32() end
  check("new(1), draw 100001", r:next_u32(), 521855493)
  check("new(1), the state after it", r:state(), "56e79ce541ad931e748603147fbf0866")
end
-- what games call
check("int(1, 6)", draws(rng.new(7), 16, function(r) return r:int(1, 6) end),
  { 1, 3, 4, 4, 6, 3, 1, 3, 2, 1, 2, 2, 6, 3, 2, 3 })
check("int(-1000, 1000)", draws(rng.new(7), 8, function(r) return r:int(-1000, 1000) end),
  { 302, 904, -90, -350, 27, -261, -955, 850 })
check("int(0, 3e9)", draws(rng.new(7), 4, function(r) return r:int(0, 3000000000) end),
  { 577597296, 2105168782, 2184162307, 940935907 })
check("float() * 2^24", draws(rng.new(7), 6, function(r) return r:float() * 16777216 end),
  { 16200221, 2256239, 8223315, 14056914, 8531884, 3675530 })
check("chance(0.25)", draws(rng.new(7), 12, function(r) return r:chance(0.25) and 1 or 0 end),
  { 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0 })
check("shuffle 1..10", rng.new(7):shuffle({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }),
  { 5, 9, 8, 2, 6, 4, 3, 10, 1, 7 })
check("weighted 5 1 0 10", draws(rng.new(7), 16, function(r) return select(2, r:weighted({ 5, 1, 0, 10 })) end),
  { 4, 1, 4, 4, 1, 1, 4, 4, 1, 1, 4, 4, 1, 4, 4, 4 })
check("weighted .5 .25 0 1.25", draws(rng.new(7), 16, function(r) return select(2, r:weighted({ 0.5, 0.25, 0, 1.25 })) end),
  { 4, 1, 4, 4, 4, 1, 2, 4, 1, 4, 4, 4, 4, 4, 4, 4 })
check("seed codes", { rng.seed_to_code(12345), rng.seed_to_code("hello"), rng.seed_to_code(4294967295), rng.code_to_seed("38TVFND") },
  { "0000C1S", "17SYB5B", "3ZZZZZZ", 3517824685 })

log(string.format("== rng: %d of %d wrong ==", bad, total))
return bad
