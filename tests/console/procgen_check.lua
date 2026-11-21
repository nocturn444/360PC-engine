-- 360PC-Engine: known answers of engine/modules/procgen. A map is only the same on every
-- platform if the rng, the order of the work and the hash are: these are the layout hashes
-- (procgen.hash) of a few seeds with a fixed set of templates, on the PC with and without the JIT.
-- On the PC:      luajit tests/console/procgen_check.lua  and  luajit -joff tests/console/procgen_check.lua
--                 (from the repository root; both must end with "== procgen: 0 of 6 wrong ==")
-- On the console: copy this file next to the main.lua of a game that has engine/, add
--                 require("procgen_check") as the first line of that main.lua, and read the log.
-- Called as a function with a log function as its argument, it logs there (the engine's tests do).
local arg1 = ...
local log = type(arg1) == "function" and arg1 or (l360 and l360.log) or print
if type(arg1) ~= "function" and not l360 then package.path = "./?.lua;./?/init.lua;" .. package.path end
local rng = require("engine.rng")
local procgen = require("engine.modules.procgen")
local bad, total = 0, 0

local function ex(...)
  local t = {}
  for i, s in ipairs({ ... }) do t[i] = { side = s } end
  return t
end
local function rooms()
  return {
    { id = "start", type = "start", exits = ex("left", "right", "down") },
    { id = "cross", weight = 3, exits = ex("left", "right", "up", "down") },
    { id = "hall", weight = 3, exits = ex("left", "right") },
    { id = "shaft", weight = 2, exits = ex("up", "down") },
    { id = "big", w = 2, h = 2, exits = { { side = "left", offset = 1 }, { side = "right" },
      { side = "up", offset = 1 }, { side = "down" } } },
    { id = "corner_a", weight = 2, exits = ex("left", "down") },
    { id = "corner_b", weight = 2, exits = ex("right", "up") },
    { id = "shop", type = "shop", exits = ex("left", "right") },
    { id = "item_l", item = true, exits = ex("left") },
    { id = "item_r", item = true, exits = ex("right") },
    { id = "item_u", item = true, exits = ex("up") },
    { id = "boss_l", type = "boss", exits = ex("left") },
    { id = "boss_u", type = "boss", exits = ex("up") },
  }
end
local ABIL = { "dash", "double_jump", "swim" }

local function check(name, got, want)
  total = total + 1
  local ok = got == want
  if not ok then bad = bad + 1 end
  log(string.format("%s %s%s", ok and "[ok] " or "[BAD]", name, ok and "" or (" = " .. tostring(got))))
end
local function hash(o)
  o.templates = rooms()
  local m, err = procgen.generate(o)
  return m and procgen.hash(m) or ("no map: " .. tostring(err))
end

check("seed 360, 16 rooms", hash({ seed = 360, rooms = 16, abilities = ABIL }), 2752255524)
check("seed 1, 16 rooms", hash({ seed = 1, rooms = 16, abilities = ABIL }), 4051614553)
check("seed 'hello', 30 rooms", hash({ seed = "hello", rooms = 30, abilities = ABIL }), 1412230188)
check("streams(12345) level, 16 rooms", hash({ rng = rng.streams(12345):get("level"), rooms = 16, abilities = ABIL }), 721847579)
check("seed 7, no loops", hash({ seed = 7, rooms = 16, abilities = ABIL, loops = false }), 3039181901)
check("seed 7, shops", hash({ seed = 7, rooms = 16, abilities = ABIL, types = { normal = 1, shop = 3 } }), 2981819364)

log(string.format("== procgen: %d of %d wrong ==", bad, total))
return bad
