-- procgen.roomtypes with a run context: chance and count functions read the game's run table,
-- `replaces` turns another type off on a floor (both outcomes, in any definition order), `max`
-- caps a count, the rng order is fixed, the old calls without `run` still work, and the
-- generator places two dead ends of one type when its count is 2.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Rng = require("engine.rng")
local P = require("engine.modules.procgen")

local function counts(list)
  local out = {}
  for i = 1, #list do out[list[i].type] = list[i].count end
  return out
end

---------------------------------------------------------------------------
-- the run table reaches chance and count
---------------------------------------------------------------------------
local types = P.roomtypes.new()
  :define("vault", { chance = function(n, total, run) return run and run.open or 0 end })
  :define("arena", { count = function(n, total, rng, run) return run and run.arena or 0 end })
local run = { open = 1, arena = 2 }
local sp = types:specials(3, 10, Rng.new(1), run)
T.check(sp[1].type == "vault" and sp[1].count == 1, "chance gets the run")
T.check(sp[2].type == "arena" and sp[2].count == 2, "count gets the run")
local without = types:specials(3, 10, Rng.new(1))
T.check(without[1].count == 0 and without[2].count == 0, "without run the functions get nil")
local a = types:specials(4, 10, Rng.new(9), run)
local b = types:specials(4, 10, Rng.new(9), run)
T.check(a[1].count == b[1].count and a[2].count == b[2].count, "the same rng state, the same specials")

-- a chance that draws: the same rng state gives the same specials
local chancey = P.roomtypes.new():define("rare", { chance = 0.5, count = { 1, 2 } })
local r1 = chancey:specials(2, 10, Rng.new(42), {})
local r2 = chancey:specials(2, 10, Rng.new(42), {})
T.check(r1[1].count == r2[1].count, "a random chance and count repeat for the same rng state")

---------------------------------------------------------------------------
-- replaces
---------------------------------------------------------------------------
local set = P.roomtypes.new()
set:define("vault", { count = 1, replaces = "treasure",
  chance = function(n, total, run) return run and run.vault or 0 end })
set:define("treasure", { count = 1 })
local on = counts(set:specials(2, 10, Rng.new(1), { vault = 1 }))
T.check(on.vault == 1 and on.treasure == 0, "an active replacer turns its target off")
local off = counts(set:specials(2, 10, Rng.new(1), { vault = 0 }))
T.check(off.vault == 0 and off.treasure == 1, "without the replacer the target stays")
local ordered = set:specials(2, 10, Rng.new(1), { vault = 1 })
T.check(ordered[1].type == "vault" and ordered[2].type == "treasure", "the output stays in definition order")

local bad = P.roomtypes.new():define("vault", { replaces = "ghost" })
T.check(not pcall(bad.specials, bad, 1, 10, Rng.new(1)), "a replaced type has to be defined by specials time")
local cyc = P.roomtypes.new():define("left", { replaces = "right" }):define("right", { replaces = "left" })
T.check(not pcall(cyc.specials, cyc, 1, 10, Rng.new(1)), "two types may not replace each other")
local self_rep = P.roomtypes.new():define("loop", { replaces = "loop" })
T.check(not pcall(self_rep.specials, self_rep, 1, 10, Rng.new(1)), "a type may not replace itself")

---------------------------------------------------------------------------
-- max
---------------------------------------------------------------------------
local capped = P.roomtypes.new()
  :define("many", { count = 5, max = 2 })
  :define("some", { count = function() return 7 end, max = 3 })
T.check(capped:count("many", 1, 10, Rng.new(1)) == 2, "max caps a number count")
T.check(capped:count("some", 1, 10, Rng.new(1)) == 3, "max caps a function count")
local sp2 = capped:specials(1, 10, Rng.new(1))
T.check(sp2[1].count == 2 and sp2[2].count == 3, "max applies in specials too")
T.check(not pcall(capped.define, capped, "bad", { max = -1 }), "max is a whole number >= 0")
T.check(not pcall(capped.define, capped, "bad", { max = 1.5 }), "max is a whole number")
T.check(not pcall(capped.define, capped, "bad", { replaces = 3 }), "replaces is a type name")

---------------------------------------------------------------------------
-- the old calls without run still work
---------------------------------------------------------------------------
local old = P.roomtypes.new():define("shop", { count = 1, max_floor = -2 })
local old_sp = old:specials(9, 10, Rng.new(1))
T.check(old_sp[1].type == "shop" and old_sp[1].count == 1, "specials without run")
T.check(old:count("shop", 10, 10, Rng.new(1)) == 0, "count without run")
T.check(table.concat(P.roomtypes.defaults():names(), ",") == "treasure,shop,miniboss", "the default set is unchanged")

---------------------------------------------------------------------------
-- the generator places two dead ends of one type, and floors pass the run
---------------------------------------------------------------------------
local function ex(...)
  local t = {}
  for i, s in ipairs({ ... }) do t[i] = { side = s } end
  return t
end
local function rooms()
  local list = {
    { id = "start", type = "start", exits = ex("left", "right", "up", "down") },
    { id = "cross", weight = 4, exits = ex("left", "right", "up", "down") },
    { id = "hall", weight = 3, exits = ex("left", "right") },
    { id = "shaft", weight = 2, exits = ex("up", "down") },
    { id = "boss", type = "boss", exits = ex("left", "right", "up", "down") },
  }
  for _, side in ipairs({ "left", "right", "up", "down" }) do
    list[#list + 1] = { id = "miniboss_" .. side, type = "miniboss", exits = ex(side) }
  end
  return list
end
local function doors(m, idx)
  local n = 0
  for i = 1, #m.doors do
    if m.doors[i].a == idx or m.doors[i].b == idx then n = n + 1 end
  end
  return n
end
for seed = 1, 60 do
  local m, err = P.generate({ templates = rooms(), seed = seed, rooms = 14,
    specials = { { type = "miniboss", count = 2 } } })
  T.check(m, "seed " .. seed .. ": " .. tostring(err))
  local n = 0
  for i = 1, #m.rooms do
    local r = m.rooms[i]
    if r.type == "miniboss" then
      n = n + 1
      T.check(doors(m, r.index) == 1, "seed " .. seed .. ": each miniboss is a dead end")
    end
  end
  T.check(n == 2, "seed " .. seed .. ": two miniboss rooms (" .. n .. ")")
end

local ft = rooms()
local tset = P.roomtypes.new():define("miniboss",
  { chance = function(n, total, run) return run and run.boss or 0 end })
local plan = P.floors.new({ count = 3, templates = ft, types = tset,
  rooms = { first = 8, last = 8, jitter = 0 } })
local opts = plan:options(2, Rng.new(1), nil, { boss = 1 })
T.check(opts.specials[1].count == 1, "floors.options passes the run to the types")
local function minis(m)
  local n = 0
  for i = 1, #m.rooms do if m.rooms[i].type == "miniboss" then n = n + 1 end end
  return n
end
local with_run = assert(plan:generate(2, Rng.new(1), nil, { boss = 1 }))
local no_run = assert(plan:generate(2, Rng.new(1), nil, nil))
T.check(minis(with_run) == 1 and minis(no_run) == 0, "floors.generate passes the run to the types")

T.no_new_globals(globals)
