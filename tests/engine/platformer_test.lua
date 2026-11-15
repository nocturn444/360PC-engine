-- engine/modules/platformer on bump.lua (lib/bump, unchanged): the grid helper, tiles merged
-- into rectangles, solid and one-way collisions, the controller (coyote time, jump buffer,
-- jump cut, drop-through), parameters changed by engine.modifiers, the reach numbers, and a
-- static check that bump and the module use nothing the console lacks.
local T = ...
local F = require("fake_love")
F.install()
local globals = {}
for k in pairs(_G) do globals[k] = true end
local Input = require("engine.input")
local Modifiers = require("engine.modifiers")
local Timestep = require("engine.timestep")
local P = require("engine.modules.platformer")
local bump = P.collision.bump
T.check(bump._VERSION == "bump v3.1.7", "lib/bump is v3.1.7")

local dt = Timestep.new({ rate = 60 }).dt
local input = Input.new({ actions = {
  left = { keys = { "left" } }, right = { keys = { "right" } },
  jump = { keys = { "z" } }, down = { keys = { "down" } },
  hop = { keys = { "x" } },
} })
local function keys(list)
  for k in pairs(F.keys) do F.keys[k] = nil end
  for k in (list or ""):gmatch("%S+") do F.keys[k] = true end
end
local function step(body, n)
  for _ = 1, n or 1 do
    input:poll(); input:step()
    body:step(input, dt)
  end
end
-- Puts the body down somewhere and lets it come to rest
local function place(body, x, y)
  keys()
  body:teleport(x, y)
  step(body, 90)
  T.check(body.on_ground, "the body rests on something")
end

---------------------------------------------------------------------------
-- The grid and its rectangles
---------------------------------------------------------------------------
local grid = P.grid.new({
  "#..............#",
  "#..............#",
  "#..............#",
  "#..............#",
  "#....===.......#",
  "#.........###..#",
  "#..............#",
  "################",
})
T.check(grid.width == 16 and grid.height == 8 and grid.tile_size == 16, "size from string rows")
T.check(grid:kind(1, 1) == "solid" and grid:kind(2, 1) == nil and grid:kind(6, 5) == "one_way"
  and grid:kind(16, 8) == "solid", "kinds from the legend")
T.check(grid:kind(0, 1) == nil and grid:kind(17, 1) == nil and grid:kind(1, 9) == nil, "outside the grid is empty")
local tx, ty = grid:toTile(80, 64)
T.check(tx == 6 and ty == 5, "pixel to tile")

local arrays = P.grid.new({ { 0, 2, 2 }, { 1, 1 }, { "solid", false, "one_way" } }, { tile_size = 8 })
T.check(arrays.width == 3 and arrays.height == 3 and arrays.tile_size == 8, "size from array rows")
T.check(arrays:kind(1, 1) == nil and arrays:kind(2, 1) == "one_way" and arrays:kind(1, 2) == "solid"
  and arrays:kind(3, 2) == nil and arrays:kind(1, 3) == "solid" and arrays:kind(3, 3) == "one_way", "array rows, short rows padded")
local custom = P.grid.new({ "X-" }, { legend = { X = "solid", ["-"] = "one_way" } })
T.check(custom:kind(1, 1) == "solid" and custom:kind(2, 1) == "one_way", "a custom legend")
T.check(not pcall(P.grid.new, { "X" }, { legend = { X = "lava" } }), "unknown kinds are refused")
arrays:set(3, 2, "solid")
T.check(arrays:kind(3, 2) == "solid" and not pcall(arrays.set, arrays, 4, 1, "solid"), "set")

local world, rects = P.collision.newWorld(grid)
T.check(world:countItems() == 5 and #P.collision.rects(grid) == 5, "the rectangles are in the bump world")
local function find(x, y)
  for _, r in ipairs(rects) do
    if r.x == x and r.y == y then return r end
  end
end
T.check(#rects == 5, "5 rectangles for 33 tiles: " .. #rects)
local wall, floor_r, plat, ledge = find(0, 0), find(0, 112), find(80, 64), find(160, 80)
T.check(wall.w == 16 and wall.h == 112 and wall.kind == "solid", "a column of solids is one rectangle")
T.check(floor_r.w == 256 and floor_r.h == 16, "a row of solids is one rectangle")
T.check(plat.w == 48 and plat.h == 16 and plat.kind == "one_way", "a run of one-way tiles")
T.check(ledge.w == 48 and ledge.kind == "solid", "a run of solids")
local stacked = P.collision.rects(P.grid.new({ "==#", "==#", "###" }), 100, 50)
T.check(#stacked == 4 and stacked[1].kind == "one_way" and stacked[1].h == 16 and stacked[1].x == 100
  and stacked[1].y == 50 and stacked[3].y == 66, "one-way rows are not joined vertically; the offset")
-- an object with the four things asked of a grid is enough
local duck = { width = 2, height = 1, tile_size = 10, kind = function(_, x) return x == 2 and "solid" or nil end }
local duck_rects = P.collision.rects(duck)
T.check(#duck_rects == 1 and duck_rects[1].x == 10 and duck_rects[1].w == 10, "any object with width, height, tile_size and kind")

P.collision.remove(world, rects)
T.check(world:countItems() == 0, "remove takes them out")
for _, r in ipairs(rects) do world:add(r, r.x, r.y, r.w, r.h) end

---------------------------------------------------------------------------
-- Solid tiles
---------------------------------------------------------------------------
local body = P.controller.new(world, { x = 30, y = 20, w = 10, h = 14 })
T.check(world:countItems() == 6 and not body.on_ground, "the body is in the world, in the air")
local landings = 0
for _ = 1, 90 do
  step(body)
  if body.landed then landings = landings + 1 end
end
T.near(body.y, 112 - 14, "it falls onto the floor")
T.check(body.on_ground and body.ground == floor_r and not body.on_one_way and body.vy == 0 and landings == 1,
  "on the ground, landed once")
keys("left")
step(body, 120)
T.near(body.x, 16, "the wall stops it")
T.check(body.wall == -1 and body.vx == 0 and body.facing == -1 and body.on_ground, "wall on the left")
keys("right")
step(body, 5)
T.check(body.x > 16 and body.vx > 0 and body.vx <= 90 and body.wall == 0 and body.px < body.x, "it accelerates away")
step(body, 60)
T.near(body.vx, 90, "up to max_speed")
keys()
step(body, 2)
T.check(body.vx < 90 and body.vx > 0, "and decelerates")
step(body, 10)
T.check(body.vx == 0, "to a stop")

-- the ceiling: under the ledge (bottom at 96) there are 2 pixels above the head
place(body, 170, 98)
keys("z")
step(body)
T.check(body.jumped and body.ceiling and body.vy >= 0, "the head hits the ledge")
T.near(body.y, 96, "and stops under it")
step(body, 10)
T.near(body.y, 98, "back on the floor")

---------------------------------------------------------------------------
-- One-way platforms
---------------------------------------------------------------------------
place(body, 100, 98)
keys("z")
local top = body.y
for _ = 1, 90 do
  step(body)
  if body.y < top then top = body.y end
end
T.check(top < 64 - 14, "a jump from below goes up through the platform")
T.near(body.y, 64 - 14, "and lands on it from above")
T.check(body.on_ground and body.ground == plat and body.on_one_way, "standing on the one-way platform")
-- sideways and from below it is not there
place(body, 60, 98)
keys("z right")
step(body, 12)
local inside = body.y + body.h > 64 and body.y < 80
keys("right")
step(body, 4)
T.check(inside and body.x + body.w > 80 and body.wall == 0, "it does not block from the side")

-- drop through with down + jump
place(body, 100, 20)
T.near(body.y, 50, "on the platform again")
keys("down")
step(body, 5)
T.check(body.on_ground and body.y < 51, "down alone does nothing")
keys("down z")
step(body)
T.check(body.dropped and not body.jumped and not body.on_ground and body.vy > 0, "down + jump drops")
keys("down")
step(body, 2)
keys("down z")       -- a new press in the air: no coyote jump out of a drop
local rose = false
for _ = 1, 60 do
  step(body)
  keys("down")
  if body.vy < 0 or body.jumped then rose = true end
end
T.check(not rose, "no jump while dropping")
T.near(body.y, 98, "it lands on the floor below")
T.check(body.on_ground and body.ground == floor_r, "on the solid floor")
keys("down z")
step(body)
T.check(body.jumped and not body.dropped and body.vy < 0, "down + jump on solid ground is a jump")

---------------------------------------------------------------------------
-- Coyote time (0.1 s: 6 steps at 60 Hz)
---------------------------------------------------------------------------
local function walk_off(wait)
  place(body, 190, 60)
  T.near(body.y, 80 - 14, "on the ledge")
  keys("right")
  local n = 0
  while body.on_ground and n < 200 do step(body); n = n + 1 end
  T.check(not body.on_ground and body.x >= 208, "it walked off the ledge")
  step(body, wait)
  keys("right z")
  step(body)
  return body.jumped
end
T.check(walk_off(3), "a jump 3 steps after the ledge still starts")
T.check(body.vy < 0 and body.coyote == 0, "and it is a real jump")
keys("right")
step(body)
keys("right z")
step(body)
T.check(not body.jumped, "but only one")
T.check(not walk_off(8), "8 steps after the ledge it does not")

---------------------------------------------------------------------------
-- Jump buffer (0.1 s)
---------------------------------------------------------------------------
local function fall(press_at)
  keys()
  body:teleport(40, 58)
  local landed_at, jumped_at
  for i = 1, 60 do
    if i == press_at then keys("z") end
    step(body)
    if body.landed and not landed_at then landed_at = i end
    if body.jumped then jumped_at = i end
  end
  return landed_at, jumped_at
end
local n = fall(nil)
T.check(n and n > 12, "the fall takes more than 12 steps: " .. tostring(n))
local landed_at, jumped_at = fall(n - 3)
T.check(landed_at == n and jumped_at == n + 1, "a press 3 steps before landing jumps on landing")
landed_at, jumped_at = fall(n - 10)
T.check(landed_at == n and jumped_at == nil, "a press 10 steps before landing is forgotten")

---------------------------------------------------------------------------
-- Variable jump height
---------------------------------------------------------------------------
local function jump_peak(b, hold, key)
  keys()
  step(b, 2)
  local y0, peak = b.y, b.y
  keys(key or "z")
  for i = 1, 120 do
    if i > hold then keys() end
    step(b)
    if b.y < peak then peak = b.y end
  end
  T.check(b.on_ground, "the jump is over")
  return y0 - peak
end
place(body, 40, 98)
keys("z")
step(body)
T.near(body.vy, -310 + 900 * dt, "the jump velocity, then a step of gravity")
keys()
step(body)
T.near(body.vy, (-310 + 900 * dt) * 0.4 + 900 * dt, "releasing while rising cuts the upward speed")
T.check(not body.jumping, "once")
place(body, 40, 98)
local full, tap = jump_peak(body, 120), jump_peak(body, 1)
T.check(tap < full * 0.5 and tap > 0, "a tap is a lower jump: " .. tap .. " < " .. full)

---------------------------------------------------------------------------
-- Reach numbers (for level generation) against the real controller
---------------------------------------------------------------------------
local reach = P.params.reach(P.params.new())
T.near(full, reach.jump_height, "reach.jump_height is the height of a real jump")
T.check(reach.tile_size == 16 and reach.jump_height_tiles == reach.jump_height / 16
  and reach.jump_distance_tiles == reach.jump_distance / 16, "in tiles")
T.check(reach.jump_height_tiles > 3 and reach.jump_height_tiles < 3.5, "the defaults clear 3 tiles: " .. reach.jump_height_tiles)
T.near(reach.coyote_distance, 9, "coyote distance")
local again = P.params.reach(P.params.new())
for k, v in pairs(reach) do T.check(again[k] == v, "reach is deterministic: " .. k) end
T.check(P.params.reach(P.params.new(), { tile_size = 8 }).jump_height_tiles == reach.jump_height / 8, "another tile size")

local rows = {}
for i = 1, 15 do rows[i] = "#" .. ("."):rep(38) .. "#" end
rows[16] = ("#"):rep(40)
local big = P.grid.new(rows)
local big_world = P.collision.newWorld(big)
local runner = P.controller.new(big_world, { x = 20, y = 200, w = 10, h = 14 })
local function long_jump(b)
  keys("right")
  step(b, 40)
  T.check(b.on_ground and b.vx == b.stats:get("max_speed"), "running at full speed")
  local x0 = b.x
  keys("right z")
  local steps = 0
  repeat step(b); steps = steps + 1 until b.landed or steps > 600
  return b.x - x0, steps * dt
end
place(runner, 20, 200)
local dist, time = long_jump(runner)
T.near(dist, reach.jump_distance, "reach.jump_distance is the length of a real jump")
T.near(time, reach.air_time, "and reach.air_time its duration")
T.check(P.params.jump_distance(P.params.new(), reach.jump_height + 1) == nil, "a surface above the jump is out of reach")
local up, down = P.params.jump_distance(P.params.new(), 32), P.params.jump_distance(P.params.new(), -32)
T.check(up and up < reach.jump_distance and down > reach.jump_distance, "higher surfaces are nearer, lower ones farther")
T.check(P.params.jump_distance(P.params.new(), 0) == reach.jump_distance, "rise 0 is the level jump")
T.check(not pcall(P.params.new, { jump_speed = 1 }), "unknown parameters are refused")

---------------------------------------------------------------------------
-- Parameters through engine.modifiers
---------------------------------------------------------------------------
local mods = Modifiers.new()
mods:defineAll({
  { id = "spring", stats = { { "jump_velocity", "mul_base", 0.5 } } },
  { id = "moon", stats = { { "gravity", "mul", 0.5 } } },
  { id = "sprint", stats = { { "max_speed", "add", 30 } }, duration = 0.5 },
})
local hero = {}
local set = mods:attach(hero, P.params.new({ jump_velocity = 280 }))
local modded = P.controller.new(big_world, { x = 60, y = 200, w = 10, h = 14, stats = set,
  actions = { jump = "hop" } })
place(modded, 60, 200)
local plain = jump_peak(modded, 120, "x")
T.near(plain, P.params.reach(P.params.new({ jump_velocity = 280 })).jump_height, "base stats: the plain jump (and a renamed action)")
set:add("spring")
local sprung = jump_peak(modded, 120, "x")
T.check(sprung > plain * 2, "a modifier on jump_velocity gives a higher jump: " .. sprung .. " > " .. plain)
T.near(sprung, P.params.reach(P.params.resolve(set)).jump_height, "and reach, from the resolved stats, agrees")
T.check(P.params.resolve(set).jump_velocity == 420 and P.params.resolve(set).gravity == 900, "resolve reads every stat")
set:remove("spring"); set:add("moon")
local floaty = jump_peak(modded, 120, "x")
T.near(floaty, P.params.reach(P.params.resolve(set)).jump_height, "a modifier on gravity too")
T.check(floaty > plain * 1.9, "half the gravity, about twice the height")
set:remove("moon"); set:add("sprint")
keys("right")
step(modded, 20)
T.near(modded.vx, 120, "a timed modifier on max_speed")
set:update(1)
step(modded, 20)
T.near(modded.vx, 90, "and it runs out")
modded:remove()
T.check(not big_world:hasItem(modded), "remove takes the body out of the world")
-- a plain table of parameters can change while the game runs
local tuned = P.params.new()
local third = P.controller.new(big_world, { x = 100, y = 200, w = 10, h = 14, params = tuned })
place(third, 100, 200)
tuned.jump_velocity = 200
T.near(jump_peak(third, 120), P.params.reach(tuned).jump_height, "a plain params table is read live")

---------------------------------------------------------------------------
-- Static checks: nothing the console lacks, nothing random, no game, and engine/ does not
-- need the module
---------------------------------------------------------------------------
local function read(path)
  local f = assert(io.open(path, "rb"))
  local src = f:read("*a"); f:close()
  return src
end
local files = { "lib/bump/bump.lua" }
for _, m in ipairs({ "init", "grid", "collision", "params", "controller" }) do
  files[#files + 1] = "engine/modules/platformer/" .. m .. ".lua"
end
for _, path in ipairs(files) do
  local src = read(path):gsub("%-%-[^\n]*", "")
  T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("require%(?%s*[\"']ffi[\"']")
    and not src:find("%f[%w_]jit%."), path .. ": no goto, no FFI, no jit")
  T.check(not src:find("%f[%w_]love%f[%W]"), path .. ": calls nothing in love")
  T.check(not src:find("math%.random") and not src:find("os%.time") and not src:find("os%.clock"),
    path .. ": nothing random, no clock")
  if path ~= files[1] then
    T.check(not src:find("modifiers"), path .. ": does not know engine.modifiers")
  end
end
for _, m in ipairs({ "init", "state", "timestep", "input", "camera", "pixel", "layers", "anim", "entity",
    "modifiers", "rng", "save", "ui" }) do
  local src = read("engine/" .. m .. ".lua"):gsub("%-%-[^\n]*", "")
  T.check(not src:find("modules") and not src:find("platformer") and not src:find("bump"),
    "engine/" .. m .. ".lua does not need the platformer module")
end
T.no_new_globals(globals)
