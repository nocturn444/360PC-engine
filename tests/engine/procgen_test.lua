-- engine/modules/procgen: templates, generation (same seed, same map; locks after their keys;
-- every map solvable), the incremental generator against the one-shot one, the minimap data,
-- the lock and key search on hand-made maps, the reach of a room's exits on tile grids, and a
-- static check that the module uses nothing the console lacks.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Rng = require("engine.rng")
local P = require("engine.modules.procgen")
local Grid = require("engine.modules.platformer.grid")

local function ex(...)
  local t = {}
  for i, s in ipairs({ ... }) do t[i] = { side = s } end
  return t
end
-- A fresh set each time (templates.new fills defaults in place)
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

---------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------
local set = P.templates.new(rooms())
T.check(set.by_id.hall.w == 1 and set.by_id.hall.h == 1 and set.by_id.hall.type == "normal"
  and set.by_id.start.weight == 1 and set.by_id.hall.exits[1].offset == 0 and #set.by_id.hall.exits[1].requires == 0,
  "defaults are filled in")
T.check(set.types[1] == "start" and set.types[2] == "normal" and set.types[3] == "shop" and set.has_items,
  "types in order of first appearance; item rooms are found")
T.check(P.templates.new(set) == set, "a set is accepted as it is")
local function refuses(list, what, pattern)
  local ok, err = pcall(P.templates.new, list)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end
refuses({}, "an empty list", "non-empty array")
refuses({ { id = "a" }, { id = "a" } }, "two templates with one id", "two templates have the id a")
refuses({ { id = "a", exits = { { side = "north" } } } }, "an unknown side", "needs side")
refuses({ { id = "a", h = 2, exits = { { side = "left", offset = 2 } } } }, "an offset outside the side", "from 0 to 1")
refuses({ { id = "a", exits = { { side = "left" }, { side = "left" } } } }, "two exits on one cell side", "two exits")
refuses({ { id = "a", w = 0 } }, "a size below one", "whole numbers >= 1")
local cx, cy = P.templates.exit_cell(set.by_id.big, set.by_id.big.exits[1])
local dx, dy = P.templates.exit_cell(set.by_id.big, set.by_id.big.exits[2])
T.check(cx == 0 and cy == 1 and dx == 1 and dy == 0, "the cell of an exit, from the room's top left cell")

---------------------------------------------------------------------------
-- Generation: rules every map keeps
---------------------------------------------------------------------------
local function opts(seed, extra)
  local o = { templates = rooms(), rng = Rng.new(seed), rooms = 16, abilities = ABIL }
  for k, v in pairs(extra or {}) do o[k] = v end
  return o
end

-- Checks a map without the module's own validator, from its rooms and doors
local function audit(m, what)
  local cells, zone_of_tag = {}, {}
  for i, r in ipairs(m.rooms) do
    T.check(r.index == i and r.doors and #r.doors == #r.template.exits, what .. ": room " .. i .. " is well formed")
    for x = r.x, r.x + r.w - 1 do
      for y = r.y, r.y + r.h - 1 do
        T.check(not cells[x .. "," .. y], what .. ": rooms do not overlap")
        cells[x .. "," .. y] = i
      end
    end
    if r.grants then zone_of_tag[r.grants] = r.zone end
  end
  for i, d in ipairs(m.doors) do
    local a, b = m.rooms[d.a], m.rooms[d.b]
    T.check(a.doors[d.ea] == i and b.doors[d.eb] == i, what .. ": door " .. i .. " is on both rooms")
    local ea, eb = a.template.exits[d.ea], b.template.exits[d.eb]
    T.check(P.templates.opposite[ea.side] == eb.side, what .. ": a door joins facing exits")
    local ax, ay = P.templates.exit_cell(a.template, ea)
    local bx, by = P.templates.exit_cell(b.template, eb)
    ax, ay = a.x + ax + P.templates.dx[ea.side], a.y + ay + P.templates.dy[ea.side]
    T.check(ax == b.x + bx and ay == b.y + by, what .. ": the exits of a door touch")
    if d.lock then
      T.check(b.zone > a.zone and zone_of_tag[d.lock] ~= nil and zone_of_tag[d.lock] < b.zone,
        what .. ": the key of " .. d.lock .. " is in a zone before its lock")
    else
      T.check(a.zone == b.zone, what .. ": a free door stays in one zone")
    end
  end
  for i, r in ipairs(m.rooms) do
    local n = 0
    for e = 1, #r.doors do if not r.doors[e] then n = n + 1 end end
    T.check(#r.closed == n, what .. ": closed lists every exit without a door")
  end
  T.check(m.rooms[m.start].type == "start" and m.rooms[m.boss].type == "boss", what .. ": start and boss")
  local boss_doors = 0
  for e = 1, #m.rooms[m.boss].doors do if m.rooms[m.boss].doors[e] then boss_doors = boss_doors + 1 end end
  T.check(boss_doors == 1 and m.rooms[m.boss].zone == #ABIL, what .. ": the boss is a dead end of the last zone")
  T.check(P.graph.validate(m), what .. ": solvable")
end

local hashes, seen_distinct, worst = {}, 0, 0
for seed = 1, 200 do
  local m, err = P.generate(opts(seed))
  T.check(m ~= nil, "seed " .. seed .. " gives a map (" .. tostring(err) .. ")")
  T.check(#m.rooms == 16, "seed " .. seed .. ": 16 rooms")
  audit(m, "seed " .. seed)
  local h = P.hash(m)
  if not hashes[h] then seen_distinct = seen_distinct + 1; hashes[h] = true end
  if m.attempts > worst then worst = m.attempts end
end
T.check(seen_distinct >= 195, "different seeds give different maps (" .. seen_distinct .. " of 200)")
T.check(worst <= 50, "no seed needed more than the default attempts")

-- Same seed, same map; a stream of engine.rng works like a generator
local a = P.generate(opts(42))
local b = P.generate(opts(42))
T.check(P.hash(a) == P.hash(b) and P.hash(a) == P.hash(P.generate({ templates = rooms(), seed = 42, rooms = 16, abilities = ABIL })),
  "same seed, same hash (an rng or a seed)")
local s1, s2 = Rng.streams(9), Rng.streams(9)
T.check(P.hash(P.generate(opts(0, { rng = s1:get("level") }))) == P.hash(P.generate(opts(0, { rng = s2:get("level") }))),
  "a level stream of the run's streams")
-- Known answer: the same on the PC with or without the JIT and on the console
-- (tests/console/procgen_check.lua checks this number on hardware)
local KNOWN = 2752255524
local known = P.hash(P.generate({ templates = rooms(), seed = 360, rooms = 16, abilities = ABIL }))
T.check(known == KNOWN, "known hash for seed 360: " .. known)
local lines = {}
local wrong = assert(loadfile("tests/console/procgen_check.lua"))(function(line) lines[#lines + 1] = line end)
T.check(wrong == 0 and lines[#lines] == "== procgen: 0 of 6 wrong ==", "tests/console/procgen_check.lua: " .. tostring(lines[#lines]))

---------------------------------------------------------------------------
-- Spread over frames: the same map for any budget
---------------------------------------------------------------------------
for _, budget in ipairs({ 1, 3, 7, 1000 }) do
  for _, seed in ipairs({ 5, 77, 360 }) do
    local gen = P.generator.new(opts(seed))
    local frames = 0
    repeat frames = frames + 1 until gen:step(budget) or frames > 100000
    local one = P.generate(opts(seed))
    T.check(gen.map and P.hash(gen.map) == P.hash(one), "budget " .. budget .. ", seed " .. seed .. ": same map as one call")
    T.check(budget > 100 or frames > 1, "budget " .. budget .. ": the work was spread (" .. frames .. " steps)")
    T.check(gen:step(1) == true and gen.ops >= frames - 1, "a finished generator stays finished")
  end
end
do
  local gen = P.generator.new(opts(5))
  local before = gen.ops
  gen:step(2)
  T.check(gen.ops - before <= 2, "a step does at most its budget of operations")
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------
local tree = P.generate(opts(3, { loops = false }))
T.check(#tree.doors == #tree.rooms - 1, "loops = false: a tree")
local looped = 0
for seed = 1, 40 do
  local m = P.generate(opts(seed))
  for _, d in ipairs(m.doors) do if d.loop then looped = looped + 1 end end
end
T.check(looped > 0, "loops join neighbours of a zone (" .. looped .. " loops in 40 maps)")
-- branching: the default avoids filling the gaps between rooms more than branching = 0
local function touching_without_door(m)
  local cells, linked, seen = {}, {}, {}
  for _, r in ipairs(m.rooms) do
    for x = r.x, r.x + r.w - 1 do
      for y = r.y, r.y + r.h - 1 do cells[x .. "," .. y] = r.index end
    end
  end
  for _, d in ipairs(m.doors) do linked[math.min(d.a, d.b) .. "," .. math.max(d.a, d.b)] = true end
  local n = 0
  for _, r in ipairs(m.rooms) do
    for x = r.x, r.x + r.w - 1 do
      for y = r.y, r.y + r.h - 1 do
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local o = cells[(x + d[1]) .. "," .. (y + d[2])]
          if o and o ~= r.index then
            local a, b = math.min(o, r.index), math.max(o, r.index)
            if not linked[a .. "," .. b] and not seen[a .. "," .. b] then
              seen[a .. "," .. b], n = true, n + 1
            end
          end
        end
      end
    end
  end
  return n
end
local gaps0, gapsd = 0, 0
for seed = 1, 20 do
  gaps0 = gaps0 + touching_without_door(assert(P.generate(opts(seed, { branching = 0 }))))
  gapsd = gapsd + touching_without_door(assert(P.generate(opts(seed))))
end
T.check(gapsd < gaps0, "branching: the default fills fewer gaps (" .. gapsd .. " vs " .. gaps0 .. ")")
T.check(not pcall(P.generator.new, { templates = rooms(), seed = 1, branching = 2 }),
  "branching: a value above 1 is an error")
T.check(not pcall(P.generator.new, { templates = rooms(), seed = 1, branching = "x" }),
  "branching: a non-number is an error")
local shops, normals = 0, 0
for seed = 1, 20 do
  local m = assert(P.generate(opts(seed, { types = { normal = 1 } })))
  for _, r in ipairs(m.rooms) do
    T.check(r.type ~= "shop", "types: a type left out is never picked")
  end
  m = assert(P.generate(opts(seed, { types = { normal = 1, shop = 3 } })))
  for _, r in ipairs(m.rooms) do
    if r.type == "shop" then shops = shops + 1 elseif r.type == "normal" and not r.template.item then normals = normals + 1 end
  end
end
T.check(shops > normals / 2, "types: a type's weight counts (" .. shops .. " shops, " .. normals .. " others)")
T.check(not pcall(P.generator.new, { templates = rooms(), seed = 1, types = { cave = 1 } }), "types: an unknown type only is an error")
local plain = P.generate({ templates = rooms(), seed = 1, rooms = 6 })
T.check(plain and #plain.rooms == 6 and plain.rooms[plain.boss].zone == 0, "no abilities: one zone")
local m0, err0 = P.generate({ templates = rooms(), seed = 1, rooms = 4, abilities = ABIL })
T.check(m0 == nil and err0:find("too few rooms", 1, true), "too few rooms for the abilities: an error, at once")
local calls = 0
local mc = P.generate(opts(8, { check = function(m) calls = calls + 1; return calls >= 3, "not yet" end }))
T.check(mc and mc.attempts >= 3 and calls == 3, "check: a refused map is tried again")
local mx, errx = P.generate(opts(1, { attempts = 2, check = function() return false, "never" end }))
T.check(mx == nil and errx:find("2 attempts", 1, true) and errx:find("never", 1, true), "out of attempts: the last reason")
local no_items = rooms()
for i = #no_items, 1, -1 do if no_items[i].item then table.remove(no_items, i) end end
local mi = P.generate({ templates = no_items, seed = 4, rooms = 12, abilities = { "dash" } })
local granted
for _, r in ipairs(mi.rooms) do if r.grants then granted = r end end
T.check(granted and granted.zone == 0 and not granted.template.item, "without item rooms the key goes in a room of its zone")
T.check(not pcall(P.generator.new, { templates = rooms() }), "an rng or a seed is needed")
T.check(not pcall(P.generator.new, { templates = rooms(), seed = 1, abilities = { "a", "a" } }), "abilities are distinct")

---------------------------------------------------------------------------
-- Minimap
---------------------------------------------------------------------------
do
  local m = P.generate(opts(11))
  local mm = P.map.minimap(m)
  local count, sides, items = 0, 0, 0
  for cyy = 1, mm.h do
    for cxx = 1, mm.w do
      local c = mm.cells[(cyy - 1) * mm.w + cxx]
      if c then
        count = count + 1
        local r = m.rooms[c.room]
        T.check(P.map.room_at(m, mm.x + cxx - 1, mm.y + cyy - 1) == r and c.zone == r.zone and c.explored == false,
          "minimap: a cell knows its room")
        if c.item then items = items + 1 end
        for _, side in ipairs(P.templates.sides) do
          if c[side] then
            sides = sides + 1
            local d = m.doors[c[side].door]
            local nx, ny = cxx + P.templates.dx[side], cyy + P.templates.dy[side]
            local n = mm.cells[(ny - 1) * mm.w + nx]
            T.check(n and n[P.templates.opposite[side]] and n[P.templates.opposite[side]].door == c[side].door,
              "minimap: a door shows on both cells")
            T.check(c[side].requires == d.requires, "minimap: a door's tags")
          end
        end
      end
    end
  end
  local area = 0
  for _, r in ipairs(m.rooms) do area = area + r.w * r.h end
  T.check(count == area and sides == 2 * #m.doors and items == #ABIL, "minimap: every cell, door and item")
  T.check(P.map.room_at(m, mm.x - 1, mm.y - 1) == nil, "room_at outside the map")
end

---------------------------------------------------------------------------
-- Locks and keys on hand-made maps
---------------------------------------------------------------------------
local function hand(grants, doors)
  local rs = {}
  for i, g in ipairs(grants) do
    rs[i] = { index = i, id = "r" .. i, grants = g or nil, doors = {} }
  end
  local ds = {}
  for i, d in ipairs(doors) do
    ds[i] = { a = d[1], b = d[2], requires = d[3] or {} }
    table.insert(rs[d[1]].doors, i)
    table.insert(rs[d[2]].doors, i)
  end
  return { rooms = rs, doors = ds, start = 1, abilities = { "dash", "swim" } }
end
local good = hand({ false, "dash", false, "swim", false }, { { 1, 2 }, { 1, 3, { "dash" } }, { 3, 4 }, { 4, 5, { "swim" } } })
T.check(P.graph.validate(good), "a map whose keys come before their locks")
local order = P.graph.solve(good).order
T.check(order[1] == "dash" and order[2] == "swim", "solve: the order the abilities are found")
local own = hand({ false, false, "dash", false, "swim" }, { { 1, 2 }, { 2, 3, { "dash" } }, { 2, 4 }, { 4, 5 } })
local ok1, why1 = P.graph.validate(own)
T.check(not ok1 and why1:find("room 3", 1, true), "a key behind its own lock is refused (" .. tostring(why1) .. ")")
local cut = hand({ false, "dash", "swim", false }, { { 1, 2 }, { 1, 3 }, { 3, 4, { "fly" } } })
local ok2, why2 = P.graph.validate(cut)
T.check(not ok2 and why2:find("never reached", 1, true), "a room behind a tag nobody gives is refused")
local both = hand({ false, "dash", "swim", false }, { { 1, 2 }, { 1, 3, { "dash" } }, { 3, 4, { "dash", "swim" } } })
T.check(P.graph.validate(both), "a door that needs two tags")
T.check(P.graph.solve(both, { have = { "dash", "swim" } }).count == 4 and P.graph.solve(both, { without = "dash" }).count == 2,
  "solve: tags held from the start, and a tag never picked up")

---------------------------------------------------------------------------
-- Reach inside a room
---------------------------------------------------------------------------
-- 3 tiles high ledge on the right: a jump of 3 tiles makes it, 2 does not
local ledge = { id = "ledge", grid = Grid.new({
  "..........",
  "......####",
  "......#...",
  "......#...",
  "..........",
  "##########",
}), exits = { { side = "left", tx = 1, ty = 5 }, { side = "right", tx = 10, ty = 1 } } }
P.templates.new({ ledge })
T.check(P.reach.check(ledge, { jump_height_tiles = 4.2, jump_distance_tiles = 3.8 }), "reach: a jump of 4 tiles climbs the wall")
local okr, whyr = P.reach.check(ledge, { jump_height_tiles = 2.9, jump_distance_tiles = 3.8 })
T.check(not okr and whyr:find("exit 2 (right) is not reached from exit 1 (left)", 1, true), "reach: a jump of 2 does not")
T.check(P.reach.from(ledge, { jump_height_tiles = 2, jump_distance_tiles = 3 }, 2)[1], "reach: going down is always possible")
-- A gap of 5 tiles: distance 3 does not cross, 5 does
local gap = { id = "gap", grid = Grid.new({
  "............",
  "............",
  "####.....###",
  "####.....###",
}), exits = { { side = "left", tx = 1, ty = 2 }, { side = "right", tx = 12, ty = 2 } } }
P.templates.new({ gap })
T.check(not P.reach.check(gap, { jump_height_tiles = 3, jump_distance_tiles = 3 }), "reach: a gap wider than the jump")
T.check(P.reach.check(gap, { jump_height_tiles = 3, jump_distance_tiles = 6 }), "reach: a gap the jump crosses")
-- Coming in from above: the body falls to the floor
local drop = { id = "drop", grid = Grid.new({
  "..........",
  "..........",
  "..........",
  "##########",
}), exits = { { side = "up", tx = 5, ty = 1 }, { side = "right", tx = 10, ty = 3 } } }
P.templates.new({ drop })
T.check(P.reach.check(drop, { jump_height_tiles = 3, jump_distance_tiles = 3 }), "reach: in from above, out at the side and back up")
T.check(not P.reach.check(drop, { jump_height_tiles = 1, jump_distance_tiles = 3 }), "reach: back up needs the height")
T.check(not pcall(P.reach.check, { id = "x", exits = {} }, {}), "reach: a template without a grid is an error")

---------------------------------------------------------------------------
-- Static checks
---------------------------------------------------------------------------
local function read(path)
  local f = assert(io.open(path, "rb"))
  local src = f:read("*a"); f:close()
  return src
end
for _, name in ipairs({ "init", "templates", "graph", "map", "generator", "reach", "roomtypes", "floors", "biomes" }) do
  local path = "engine/modules/procgen/" .. name .. ".lua"
  local src = read(path):gsub("%-%-[^\n]*", "")
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("require%(?%s*[\"']ffi[\"']")
    and not src:find("%f[%w_]jit%."), path .. ": no goto, no FFI, no jit")
  T.check(not src:find("%f[%w_]love%f[%W]"), path .. ": calls nothing in love")
  T.check(not src:find("math%.random") and not src:find("os%.time") and not src:find("os%.clock"),
    path .. ": nothing random of its own, no clock")
  T.check(not src:find("[^%w_]pairs%("), path .. ": no pairs() (the order of a map must not depend on it)")
  T.check(not src:find("platformer") and not src:find("combat"), path .. ": needs no other genre module")
end
for _, name in ipairs({ "init", "state", "timestep", "input", "camera", "pixel", "layers", "anim", "entity",
    "modifiers", "rng", "save", "ui" }) do
  T.check(not read("engine/" .. name .. ".lua"):gsub("%-%-[^\n]*", ""):find("procgen"),
    "engine/" .. name .. ".lua does not need procgen")
end

T.no_new_globals(globals)
