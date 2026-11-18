-- procgen.roomtypes and procgen.floors: modular special room types (counts by floor, chance,
-- ranges, order), special rooms in the generator (dead ends, never looped, distance from the
-- start, never used as filler, counted in rooms), the boss far from the start, and a run of 10
-- floors that grows: more rooms, more special rooms, the same maps for the same seed.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Rng = require("engine.rng")
local P = require("engine.modules.procgen")

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
    { id = "tee", weight = 3, exits = ex("left", "right", "down") },
    { id = "tee_up", weight = 3, exits = ex("left", "right", "up") },
    { id = "big", w = 2, h = 2, exits = { { side = "left", offset = 1 }, { side = "right" },
      { side = "up", offset = 1 }, { side = "down" } } },
    { id = "deep", weight = 2, floors = { 4 }, exits = ex("left", "right", "up", "down") },
  }
  for _, kind in ipairs({ "boss", "treasure", "shop", "miniboss" }) do
    for _, side in ipairs({ "left", "right", "up", "down" }) do
      list[#list + 1] = { id = kind .. "_" .. side, type = kind, exits = ex(side) }
    end
  end
  return list
end

---------------------------------------------------------------------------
-- roomtypes
---------------------------------------------------------------------------
local types = P.roomtypes.new()
T.check(not pcall(types.define, types, "boss", {}), "boss is not a special type")
T.check(not pcall(types.define, types, "x", { count = -1 }), "a negative count is refused")
T.check(not pcall(types.define, types, "x", { count = { 3, 1 } }), "a range needs min <= max")
T.check(not pcall(types.define, types, "x", { distance = "middle" }), "an unknown distance is refused")
T.check(not pcall(types.define, types, "x", { chance = 2 }), "chance is 0..1")
types:define("shop", { count = 1, max_floor = -2 })
  :define("vault", { count = { 1, 3 }, min_floor = 3 })
  :define("arena", { count = function(n) return n >= 5 and 2 or 0 end, distance = "far" })
  :define("rare", { chance = 0.5 })
local rng = Rng.new(7)
T.check(types:count("shop", 9, 10, rng) == 1 and types:count("shop", 10, 10, rng) == 0, "max_floor -2: not on the last floor")
T.check(types:count("vault", 2, 10, rng) == 0, "min_floor")
local seen = {}
for _ = 1, 200 do seen[types:count("vault", 5, 10, rng)] = true end
T.check(seen[1] and seen[2] and seen[3] and not seen[0] and not seen[4], "a { min, max } count draws in the range")
T.check(types:count("arena", 4, 10, rng) == 0 and types:count("arena", 5, 10, rng) == 2, "a count function")
local hits = 0
for _ = 1, 1000 do hits = hits + types:count("rare", 1, 10, rng) end
T.check(hits > 400 and hits < 600, "chance 0.5 (" .. hits .. " of 1000)")
local names = table.concat(types:names(), ",")
types:define("shop", { count = 2 })
T.check(table.concat(types:names(), ",") == names and types:get("shop").count == 2, "redefining keeps the order")
local sp = types:specials(5, 10, Rng.new(1))
T.check(sp[1].type == "shop" and sp[1].count == 2 and sp[2].type == "vault", "specials in the order of the definitions")
T.check(#types:specials(1, 10, Rng.new(1)) == 4 and types:specials(1, 10, Rng.new(1))[2].count == 0,
  "a type with no room on a floor stays in the list with count 0")
local a, b = types:specials(6, 10, Rng.new(3)), types:specials(6, 10, Rng.new(3))
T.check(#a == #b and a[#a].type == b[#b].type and a[2].count == b[2].count, "the same rng, the same specials")
local d = P.roomtypes.defaults()
T.check(table.concat(d:names(), ",") == "treasure,shop,miniboss", "the default set: treasure, shop, miniboss")
local mb2, mb10 = 0, 0
for i = 1, 400 do
  mb2 = mb2 + d:count("miniboss", 2, 10, Rng.new(i))
  mb10 = mb10 + d:count("miniboss", 10, 10, Rng.new(i))
end
T.check(d:count("miniboss", 1, 10, Rng.new(1)) == 0 and mb2 < mb10 and mb10 > 300,
  "minibosses from floor 2, more likely later (" .. mb2 .. " vs " .. mb10 .. " of 400)")

---------------------------------------------------------------------------
-- special rooms in the generator
---------------------------------------------------------------------------
local function depth_from_start(m)
  local dist, queue = { [m.start] = 0 }, { m.start }
  local i = 1
  while queue[i] do
    local r = queue[i]; i = i + 1
    for _, door in ipairs(m.doors) do
      local o = door.a == r and door.b or (door.b == r and door.a or nil)
      if o and not dist[o] then dist[o] = dist[r] + 1; queue[#queue + 1] = o end
    end
  end
  return dist
end
local function doors_of(m, idx)
  local n = 0
  for _, door in ipairs(m.doors) do if door.a == idx or door.b == idx then n = n + 1 end end
  return n
end

local specials = { { type = "treasure", count = 1, min_depth = 2 }, { type = "shop", count = 1 },
  { type = "miniboss", count = 2, distance = "far", min_depth = 3 } }
local ok_maps = 0
for seed = 1, 120 do
  local m, err = P.generate({ templates = rooms(), seed = seed, rooms = 16, specials = specials, boss_distance = "far" })
  T.check(m, "seed " .. seed .. ": " .. tostring(err))
  T.check(#m.rooms == 16, "specials count in rooms (" .. #m.rooms .. ")")
  local count, dist = {}, depth_from_start(m)
  local deepest_normal = 0
  for _, r in ipairs(m.rooms) do
    count[r.type] = (count[r.type] or 0) + 1
    if r.type == "normal" then deepest_normal = math.max(deepest_normal, dist[r.index]) end
    if r.type ~= "normal" and r.type ~= "start" then
      T.check(doors_of(m, r.index) == 1, "seed " .. seed .. ": the " .. r.type .. " room is a dead end")
      T.check(r.depth == dist[r.index], "depth is the doors from the start")
    end
    if r.type == "treasure" then T.check(r.depth >= 2, "treasure: min_depth 2") end
    if r.type == "miniboss" then T.check(r.depth >= 3, "miniboss: min_depth 3") end
    T.check(r.template.type == r.type and (r.type ~= "normal" or not (r.id:find("^shop") or r.id:find("^treasure") or r.id:find("^miniboss"))), "special templates are never filler")
  end
  T.check(count.treasure == 1 and count.shop == 1 and count.miniboss == 2 and count.boss == 1,
    "seed " .. seed .. ": one treasure, one shop, two minibosses, one boss")
  T.check(dist[m.boss] >= deepest_normal - 1, "seed " .. seed .. ": the boss is about as deep as the deepest ordinary room")
  ok_maps = ok_maps + 1
end
T.check(ok_maps == 120, "120 maps with special rooms")
local h1 = P.hash(P.generate({ templates = rooms(), seed = 99, rooms = 14, specials = specials }))
local h2 = P.hash(P.generate({ templates = rooms(), seed = 99, rooms = 14, specials = specials }))
T.check(h1 == h2, "the same seed, the same map with specials")
T.check(not pcall(P.generate, { templates = rooms(), seed = 1, specials = { { type = "casino" } } }),
  "a special type without templates is an error")
T.check(not pcall(P.generate, { templates = rooms(), seed = 1, specials = { { type = "boss" } } }),
  "boss is not a special")
local plain = P.generate({ templates = rooms(), seed = 5, rooms = 12 })
local uses_special = false
for _, r in ipairs(plain.rooms) do if r.type == "shop" then uses_special = true end end
T.check(plain, "without specials the generator still runs")

---------------------------------------------------------------------------
-- a run of floors
---------------------------------------------------------------------------
local plan = P.floors.new({ count = 10, templates = rooms(), types = P.roomtypes.defaults(),
  rooms = { first = 7, last = 22 } })
local streams = Rng.streams(2026)
local sizes, specials_n, mini = {}, {}, 0
for n = 1, 10 do
  local m, err = plan:generate(n, streams:get("floor" .. n))
  T.check(m, "floor " .. n .. ": " .. tostring(err))
  T.check(m.floor == n and m.floors == 10 and math.abs(m.progress - (n - 1) / 9) < 1e-9, "the map knows its floor")
  sizes[n] = #m.rooms
  local s = 0
  for _, r in ipairs(m.rooms) do
    if r.type == "treasure" or r.type == "shop" or r.type == "miniboss" then s = s + 1 end
    if r.type == "miniboss" then mini = mini + 1 end
    if r.id == "deep" then T.check(n >= 4, "a template with floors = { 4 } only from floor 4") end
  end
  specials_n[n] = s
  T.check(m.boss, "floor " .. n .. " has a boss")
end
T.check(sizes[1] >= 7 and sizes[1] <= 8 and sizes[10] >= 22 and sizes[10] <= 23, "7 rooms on floor 1, 22 on floor 10 ("
  .. sizes[1] .. ", " .. sizes[10] .. ")")
for n = 2, 10 do T.check(sizes[n] >= sizes[n - 1] - 1, "the floors grow (" .. table.concat(sizes, ",") .. ")") end
T.check(specials_n[1] == 2 and specials_n[10] <= 2, "floor 1: treasure and shop; the last floor has no shop (" .. table.concat(specials_n, ",") .. ")")
T.check(mini >= 1, "some floor has a miniboss")
local again = Rng.streams(2026)
T.check(P.hash(plan:generate(7, again:get("floor7"))) == P.hash(plan:generate(7, Rng.streams(2026):get("floor7"))),
  "a floor depends only on the seed and its number")
-- spread over frames: the same map
local gen = plan:generator(3, Rng.streams(11):get("floor3"))
local steps = 0
while not gen:step(5) do steps = steps + 1 end
local whole = plan:generate(3, Rng.streams(11):get("floor3"))
T.check(gen.map and gen.map.floor == 3 and P.hash(gen.map) == P.hash(whole) and steps > 1, "the generator over frames gives the same floor")
-- the game's own changes
local touched
local plan2 = P.floors.new({ count = 3, templates = rooms(), rooms = function(n) return 5 + n end,
  options = function(o, n) touched = n; o.loops = false end })
local m3 = plan2:generate(3, Rng.new(1))
T.check(touched == 3 and #m3.rooms == 8, "rooms as a function, and the options hook")
T.check(not pcall(plan2.generate, plan2, 4, Rng.new(1)), "a floor past the count is an error")
T.check(not pcall(P.floors.new, { count = 0, templates = rooms() }), "count >= 1")

-- seeds: a floor of a plan, the same hash as generating it by hand
local h = P.seeds.hash({ plan = plan, floor = 4 }, 77)
T.check(h == P.hash(plan:generate(4, Rng.streams(77):get("floor4"))), "seeds.hash with a plan and a floor")

---------------------------------------------------------------------------
-- biomes
---------------------------------------------------------------------------
local B = P.biomes
T.check(not pcall(B.new, { { id = "a", span = 0 } }), "a span of 0 is refused")
T.check(not pcall(B.new, { { id = "a" }, { id = "a" } }), "two biomes with one id")
local function biome_set(unlocked)
  return B.new({
    { id = "cellar", span = 2, fixed = "first", difficulty = 1 },
    { id = "caves", span = { 1, 3 }, weight = 3, difficulty = 2 },
    { id = "garden", span = 2, difficulty = 2 },
    { id = "depths", span = { 1, 2 }, difficulty = 3, min_floor = 5 },
    { id = "secret", span = 1, unlock = "key_of_secrets", difficulty = 3 },
    { id = "ruins", span = 1, when = function(run) return run and run.spared end, difficulty = 3 },
    { id = "crypt", span = { 2, 3 }, after = { "ruins" }, difficulty = 4 },
    { id = "core", span = 1, fixed = "last", difficulty = 5 },
  }, { floors = 10, unlocked = unlocked })
end
local function walk(set, seed, run, choose)
  local path, rng = set:path(), Rng.new(seed)
  local ids = {}
  for n = 1, 10 do ids[n] = path:enter(n, run, rng, choose and choose(n, path) or nil).id end
  return ids, path
end
local seen_spans, seen_ids = {}, {}
for seed = 1, 300 do
  local ids, path = walk(biome_set(), seed, {})
  T.check(ids[1] == "cellar" and ids[2] == "cellar" and ids[10] == "core", "seed " .. seed .. ": fixed first (2 floors) and last")
  local run_len, i = 0, 1
  for _, step in ipairs(path:state()) do
    local len = step.last - step.first + 1
    seen_spans[len] = true
    seen_ids[step.id] = true
    T.check(step.first == i, "the steps cover the floors in order")
    i = step.last + 1
    if step.id == "depths" then T.check(step.first >= 5, "min_floor") end
    T.check(step.id ~= "secret" and step.id ~= "ruins" and step.id ~= "crypt", "locked, conditional and after-only biomes stay out")
  end
  T.check(i == 11, "seed " .. seed .. ": the path fills the 10 floors (" .. table.concat(ids, ",") .. ")")
  local count = {}
  for _, step in ipairs(path:state()) do count[step.id] = (count[step.id] or 0) + 1 end
  for id, c in pairs(count) do T.check(c == 1, "once: " .. id .. " appears in one stretch") end
end
T.check(seen_spans[1] and seen_spans[2] and seen_spans[3], "biomes last 1, 2 or 3 floors")
T.check(seen_ids.caves and seen_ids.garden and seen_ids.depths, "the variable biomes all come up")
local a1 = walk(biome_set(), 42, {})
local a2 = walk(biome_set(), 42, {})
T.check(table.concat(a1, ",") == table.concat(a2, ","), "the same seed and run, the same path")
-- unlocks, the run's choices, alternative paths, a forced choice
local got_secret, got_ruins_crypt = false, false
for seed = 1, 200 do
  local ids = walk(biome_set({ "key_of_secrets" }), seed, { spared = true })
  local str = table.concat(ids, ",")
  if str:find("secret") then got_secret = true end
  if str:find("ruins,crypt") then got_ruins_crypt = true end
  if str:find("crypt") then T.check(str:find("ruins,crypt"), "crypt only right after ruins") end
end
T.check(got_secret and got_ruins_crypt, "an unlocked biome and a biome the run allowed come up, and their follow-up")
local forced = walk(biome_set(), 3, {}, function(n) return n == 3 and "garden" or nil end)
T.check(forced[3] == "garden" and forced[4] == "garden", "a forced choice (the player picked a path)")
local p = biome_set():path()
local r = Rng.new(1)
p:enter(1, {}, r); p:enter(2, {}, r); p:enter(3, {}, r)
T.check(not pcall(p.enter, p, p.current.last + 2, {}, r), "floors are entered in order")
local saved = p:state()
local p2 = biome_set():path()
T.check(p2:set_state(saved) and p2:enter(3, {}, Rng.new(9)).id == p:enter(3, {}, r).id, "the path saves and loads")
local cands = biome_set():path()
cands:enter(1, {}, Rng.new(1))
local list, room = cands:candidates(3, {})
T.check(#list >= 2 and room == 7, "candidates: what could start on floor 3 (for a choice screen)")

-- floors read the biome: its templates, size, difficulty
local bset = B.new({ { id = "ice", span = 10, fixed = "first", difficulty = 4, rooms_add = 3 } }, { floors = 10 })
local tlist = rooms()
tlist[#tlist + 1] = { id = "ice_hall", weight = 50, biomes = { "ice" }, exits = ex("left", "right") }
tlist[#tlist + 1] = { id = "lava_hall", weight = 50, biomes = { "lava" }, exits = ex("left", "right") }
local bplan = P.floors.new({ count = 10, templates = tlist, types = P.roomtypes.defaults(), rooms = { first = 7, last = 7, jitter = 0 } })
local ice = bset:path():enter(1, {}, Rng.new(1))
local m = assert(bplan:generate(1, Rng.new(5), ice))
local has_ice, has_lava = false, false
for _, room in ipairs(m.rooms) do
  if room.id == "ice_hall" then has_ice = true end
  if room.id == "lava_hall" then has_lava = true end
end
T.check(has_ice and not has_lava, "a biome uses its own templates and the shared ones, never another biome's")
T.check(#m.rooms == 10 and m.biome == "ice" and m.difficulty == 4 and m.biome_def == ice, "rooms_add, map.biome and map.difficulty")

-- items: entries of a biome only come out there
local items = require("engine.modules.items")
local pool = items.pool.new({ { id = "snowball", biomes = { "ice" } }, { id = "coin" } })
local only_ice = true
for i = 1, 50 do
  local e = pool:draw(Rng.new(i), { biome = "lava" })
  if e.id == "snowball" then only_ice = false end
end
local ice_seen = false
for i = 1, 50 do if pool:draw(Rng.new(i), { biome = "ice" }).id == "snowball" then ice_seen = true end end
T.check(only_ice and ice_seen, "items with biomes come out only in their biome")

T.no_new_globals(globals)
