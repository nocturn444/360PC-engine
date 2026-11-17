-- engine/modules/rooms: the map in room pixels (sizes, arrival points, spawns), leaving through
-- an exit and where its door leads, locked doors, a walk through every door of a generated map
-- (each arrival is inside the room and leads back), explored rooms and the minimap, the state
-- for the run's save, the transitions (fade and slide), and a static check.
local T = ...
local globals = {}
for k in pairs(_G) do globals[k] = true end
local P = require("engine.modules.procgen")
local rooms = require("engine.modules.rooms")
local Save = require("engine.save")

local function ex(...)
  local t = {}
  for i, s in ipairs({ ... }) do t[i] = { side = s } end
  return t
end
local function templates()
  return {
    { id = "start", type = "start", exits = ex("left", "right", "down"), spawn = { tx = 10, ty = 6 } },
    { id = "cross", weight = 3, exits = ex("left", "right", "up", "down") },
    { id = "hall", weight = 3, exits = { { side = "left", tx = 1, ty = 8 }, { side = "right", tx = 20, ty = 8 } } },
    { id = "shaft", weight = 2, exits = ex("up", "down") },
    { id = "big", w = 2, h = 2, exits = { { side = "left", offset = 1 }, { side = "right" },
      { side = "up", offset = 1 }, { side = "down" } } },
    { id = "corner_a", weight = 2, exits = ex("left", "down") },
    { id = "corner_b", weight = 2, exits = ex("right", "up") },
    { id = "item_l", item = true, exits = ex("left") },
    { id = "item_r", item = true, exits = ex("right") },
    { id = "boss_l", type = "boss", exits = ex("left") },
  }
end
local CW, CH, TS = 320, 192, 16
local map = assert(P.generate({ templates = templates(), seed = 7, rooms = 14, abilities = { "dash" } }))
local nav = rooms.nav.new(map, { cell_w = CW, cell_h = CH, tile_size = TS })

-- Start
local x, y = nav:enter(map.start)
T.check(nav.index == map.start and nav.room == map.rooms[map.start] and nav:is_explored(map.start), "enter the start room")
T.check(x == 9.5 * TS and y == 5.5 * TS, "the start room's spawn tile (" .. x .. ", " .. y .. ")")
local bx0, by0, bx1, by1 = nav:bounds()
T.check(bx0 == 0 and by0 == 0 and bx1 == CW and by1 == CH, "bounds of a one-cell room")
T.check(nav:leaving(CW / 2, CH / 2) == nil, "inside the room: not leaving")
T.check(not pcall(rooms.nav.new, map, { cell_w = 0, cell_h = 10 }) and not pcall(rooms.nav.new, {}, { cell_w = 1, cell_h = 1 }),
  "new refuses a bad cell size or a non-map")

-- Every door of the map, from both sides: leave by the exit's edge, arrive inside the other
-- room, and leaving there by the arrival exit's edge leads straight back
local function edge_point(index, e)
  local r = map.rooms[index]
  local ox, oy = P.templates.exit_cell(r.template, r.template.exits[e])
  local side = r.template.exits[e].side
  if side == "left" then return -1, (oy + 0.5) * CH end
  if side == "right" then return r.w * CW + 1, (oy + 0.5) * CH end
  if side == "up" then return (ox + 0.5) * CW, -1 end
  return (ox + 0.5) * CW, r.h * CH + 1
end
local walked, ok_all = 0, true
for d = 1, #map.doors do
  local door = map.doors[d]
  for pass = 1, 2 do
    local from, e = door.a, door.ea
    if pass == 2 then from, e = door.b, door.eb end
    nav:enter(from)
    local lx, ly = edge_point(from, e)
    local le, ld, side = nav:leaving(lx, ly)
    if le ~= e or ld ~= d or side ~= map.rooms[from].template.exits[e].side then ok_all = false end
    local ax, ay, to, back = nav:go(d)
    local w, h = nav:size()
    if to ~= (pass == 1 and door.b or door.a) or ax <= 0 or ay <= 0 or ax >= w or ay >= h then ok_all = false end
    local rx, ry = edge_point(to, back)
    local be, bd = nav:leaving(rx, ry)
    if be ~= back or bd ~= d then ok_all = false end
    walked = walked + 1
  end
end
T.check(ok_all and walked == 2 * #map.doors, "every door, both ways: leave, arrive inside, and back (" .. walked .. ")")

-- Arrival points
local hall
for i, r in ipairs(map.rooms) do if r.template.id == "hall" then hall = i end end
if hall then
  local ax, ay = nav:arrival(hall, 1)
  T.check(ax == 0.5 * TS and ay == 7.5 * TS, "an exit with a tile arrives on that tile")
end
local big
for i, r in ipairs(map.rooms) do if r.template.id == "big" then big = i end end
T.check(big ~= nil, "seed 7 has a big room")
local bw, bh = nav:size(big)
T.check(bw == 2 * CW and bh == 2 * CH, "a 2 x 2 room is two cells each way")
local ax, ay = nav:arrival(big, 1)               -- left, offset 1
T.check(ax == 24 and ay == 1.5 * CH, "left exit at offset 1: the lower cell, 1.5 tiles in")
ax, ay = nav:arrival(big, 3)                     -- up, offset 1
T.check(ax == 1.5 * CW and ay == 24, "up exit at offset 1: the right cell")
ax, ay = nav:arrival(big, 4)                     -- down, offset 0
T.check(ax == 0.5 * CW and ay == 2 * CH - 24, "down exit at offset 0")
nav:enter(big)
local e1 = nav:leaving(-1, 1.2 * CH)
local e0, _, s0 = nav:leaving(-1, 0.5 * CH)
T.check(e1 == 1 and e0 == nil and s0 == "left", "leaving the left edge: only the lower cell has an exit")
T.check(nav:leaving(2 * CW + 5, -100) == 2, "a corner past the edge counts on the nearest cell")

-- Locks
local locked
for d = 1, #map.doors do if #map.doors[d].requires > 0 then locked = d end end
T.check(locked ~= nil, "the map has a locked door")
local okp, missing = nav:can_pass(locked, {})
T.check(not okp and missing == "dash", "a locked door: the tag missing")
T.check(nav:can_pass(locked, { "dash" }) and nav:can_pass(locked, { dash = true }), "the ability opens it (array or set)")
local free
for d = 1, #map.doors do if #map.doors[d].requires == 0 then free = d; break end end
T.check(nav:can_pass(free), "a free door needs nothing")
nav:enter(map.start)
local other
for d = 1, #map.doors do
  if map.doors[d].a ~= map.start and map.doors[d].b ~= map.start then other = d; break end
end
T.check(not pcall(nav.through, nav, other), "through refuses a door of another room")

-- Explored rooms, the minimap and the run's save
local fresh = rooms.nav.new(map, { cell_w = CW, cell_h = CH })
fresh:enter(map.start)
local mm = fresh:minimap()
local seen_cells, other_cells = 0, 0
for i = 1, #mm.cells do
  local c = mm.cells[i]
  if c then
    if c.room == map.start then seen_cells = seen_cells + (c.explored and 1 or 0)
    elseif c.explored then other_cells = other_cells + 1 end
  end
end
T.check(seen_cells == 1 and other_cells == 0, "minimap: the start room explored, nothing else")
local d1 = map.rooms[map.start].doors[1] or map.rooms[map.start].doors[2] or map.rooms[map.start].doors[3]
local _, _, next_room, came = fresh:go(d1)
local explored_next = false
for i = 1, #mm.cells do if mm.cells[i] and mm.cells[i].room == next_room and mm.cells[i].explored then explored_next = true end end
T.check(explored_next and fresh.visits[next_room] == 1, "going through a door explores the next room on the minimap")
local text = assert(Save.serialize(fresh:state()))
local back = rooms.nav.new(map, { cell_w = CW, cell_h = CH })
back:minimap()
local bx, by = back:set_state(select(2, Save.parse(text)))
local fx, fy = fresh:arrival(next_room, came)
T.check(back.index == next_room and back:is_explored(map.start) and back:is_explored(next_room) and bx == fx and by == fy,
  "state through engine.save: same room, same arrival, same explored rooms")
local n_explored = 0
for i = 1, #map.rooms do if back:is_explored(i) then n_explored = n_explored + 1 end end
T.check(n_explored == 2, "and nothing more explored")
back:set_state({ room = 999, explored = { 1, 999 } })
T.check(back.index == map.start and back:is_explored(1), "a state with rooms the map does not have: the start room")
local calls = 0
local hooked = rooms.nav.new(map, { cell_w = CW, cell_h = CH, on_enter = function(n, i, e) calls = calls + 1 end })
hooked:enter(map.start); hooked:go(d1)
T.check(calls == 2, "on_enter after each enter")

-- Transitions
local fade = rooms.transition.new({ kind = "fade", time = 0.3 })
local swaps = 0
T.check(fade:start(function() swaps = swaps + 1 end) and not fade:start(function() end), "a running transition ignores start")
local covers = {}
for i = 1, 20 do fade:update(1 / 60); covers[i] = fade:cover(1) end
T.check(swaps == 1, "the swap runs once")
T.near(covers[9], 1, "fully covered at the middle (step 9 of 18)", 1e-6)
T.check(covers[4] > 0.3 and covers[4] < 0.6 and covers[14] > 0.3 and covers[14] < 0.6, "covering and uncovering")
T.check(not fade:busy() and covers[18] == 0 and covers[20] == 0, "done after 0.3 s")
local slide = rooms.transition.new({ kind = "slide", time = 0.5 })
slide:start(nil, "right")
local first, second
for i = 1, 30 do
  slide:update(1 / 60)
  if i == 10 then first = { slide:offset(1, 320, 180) } end
  if i == 20 then second = { slide:offset(1, 320, 180) } end
end
T.check(first[1] < 0 and first[2] == 0 and second[1] > 0, "slide right: the old room leaves left, the new one comes from the right")
T.check(select(1, slide:offset(1, 320, 180)) == 0, "slide ends in place")
slide:start(nil, "up"); for _ = 1, 10 do slide:update(1 / 60) end
local _, oy = slide:offset(1, 320, 180)
T.check(oy > 0, "slide up: the old room goes down")
T.check(not pcall(rooms.transition.new, { kind = "wipe" }) and not pcall(rooms.transition.new, { time = 0 }), "new refuses a bad kind or time")

-- Static checks
for _, file in ipairs({ "init", "nav", "transition" }) do
  local f = assert(io.open("engine/modules/rooms/" .. file .. ".lua", "rb"))
  local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."), file .. ": no goto, FFI or jit")
  T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
    file .. ": no love, nothing random, no clock")
  T.check(not src:find("[^%w_]pairs%("), file .. ": no pairs()")
end
T.no_new_globals(globals)
