-- engine/modules/abilities: kind registration and config checks, air jumps (uses, stacks,
-- refill), wall jumps (priority, lock, slide), the dash (button and double tap, air uses,
-- cooldown, reset), the hook (flight, attach, rope, reel, pump, release), state/set_state,
-- reset, one test on a real softbody, and nothing allocated in a step with every kind granted.
-- Usage, from the repository root: luajit -joff tests/engine/abilities_test.lua
-- Also works as tests/engine/run.lua's `T`-taking style.
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;" .. package.path

local T = ...
if type(T) ~= "table" then
  T = { checks = 0 }
  function T.check(cond, what)
    T.checks = T.checks + 1
    if not cond then error("FAILED: " .. what, 2) end
  end
  function T.near(a, b, what, eps)
    T.checks = T.checks + 1
    if math.abs(a - b) > (eps or 1e-6) then
      error(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)), 2)
    end
  end
  function T.no_new_globals(before)
    for k in pairs(_G) do
      if not before[k] then error("FAILED: the engine created the global " .. tostring(k), 2) end
    end
  end
end

local globals = {}
for k in pairs(_G) do globals[k] = true end
local abilities = require("engine.modules.abilities")
local softbody = require("engine.modules.softbody")
local gridmod = require("engine.modules.platformer.grid")

local DT = 1 / 60

-- A body adapter: a plain table with the six methods a set reads.
local function fake(x, y)
  local b = { x = x or 0, y = y or 0, vx = 0, vy = 0, ground = false, wall = 0 }
  function b:on_ground() return self.ground end
  function b:wall_side() return self.wall end
  function b:center() return self.x, self.y end
  function b:velocity() return self.vx, self.vy end
  function b:set_velocity(vx, vy)
    if vx ~= nil then self.vx = vx end
    if vy ~= nil then self.vy = vy end
  end
  function b:impulse(vx, vy) self.vx = self.vx + vx; self.vy = self.vy + (vy or 0) end
  return b
end

local intent = {
  move_x = 0, move_y = 0, jump = false, jump_held = false, dash = false, hook = false,
  jump_speed = 260, facing = 1, consumed_jump = false,
}
local function tick(set, changes)
  intent.move_x, intent.move_y, intent.facing = 0, 0, 1
  intent.jump, intent.jump_held, intent.dash, intent.hook = false, false, false, false
  intent.jump_speed, intent.consumed_jump = 260, false
  if changes then
    for k, v in pairs(changes) do intent[k] = v end
  end
  set:step(DT, intent)
end

local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  T.check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

---------------------------------------------------------------------------
-- Configs and the registry
---------------------------------------------------------------------------
local b = fake()
local set = abilities.new(b)
T.check(type(set.step) == "function" and not set:has("x") and set:stacks("x") == 0,
  "an empty set")
refuses(function() set:grant("air_jump") end, "a definition is a table", "definition is a table")
refuses(function() set:grant({ kind = "laser", id = "x" }) end, "an unknown kind", "unknown kind")
refuses(function() set:grant({ kind = "air_jump" }) end, "a missing id", "id is a non-empty string")
refuses(function() set:grant({ kind = "air_jump", id = "x", spin = 1 }) end,
  "an unknown field", "air_jump has no field spin")
refuses(function() set:grant({ kind = "air_jump", id = "x", power = "high" }) end,
  "a wrong type", "power is a number")
refuses(function() set:grant({ kind = "dash", id = "x", trigger = "key" }) end,
  "a wrong trigger", "dash.trigger is button or double_tap")
refuses(function() set:grant({ kind = "dash", id = "x", dirs = 6 }) end,
  "wrong dirs", "dash.dirs is 4 or 8")
local custom = abilities.kind("test_kind", {
  fields = { amount = { type = "number", default = 2 } },
  init = function(a) a.calls = 0 end,
  step = function(a) a.calls = a.calls + a.amount end,
})
local ca = set:grant({ kind = "test_kind", id = "custom", amount = 3 })
T.check(ca.amount == 3 and ca.priority == 0, "a game registers its own kind")
tick(set)
T.check(ca.calls == 3, "and its step runs")
set:revoke("custom")
T.check(not set:has("custom") and set:get("custom") == nil, "revoke takes it away")
T.check(custom ~= nil, "the registered handlers are returned")

---------------------------------------------------------------------------
-- Air jump
---------------------------------------------------------------------------
b = fake()
set = abilities.new(b)
local dj = set:grant({ kind = "air_jump", id = "double_jump" })
T.check(dj.priority == 30 and dj.uses == 1 and dj.max_uses == 1, "air jump: one use, priority 30")
b.ground = false
tick(set, { jump = true })
T.check(b.vy == -260 and intent.consumed_jump and dj.uses == 0, "in the air, a jump sets the velocity")
b.vy = 10
tick(set, { jump = true })
T.check(b.vy == 10 and not intent.consumed_jump, "no use left: the jump is left to the game")
b.ground = true
tick(set)
T.check(dj.uses == 1, "landing refills it")
local b2 = fake()
local s2 = abilities.new(b2)
local j2 = s2:grant({ kind = "air_jump", id = "jump", power = 1.5 })
b2.ground = false
tick(s2, { jump = true })
T.check(b2.vy == -390, "power multiplies the jump speed")
local b3 = fake()
local s3 = abilities.new(b3)
local j3 = s3:grant({ kind = "air_jump", id = "jump" })
j3 = s3:grant({ kind = "air_jump", id = "jump" })
T.check(s3:stacks("jump") == 2 and j3.max_uses == 2 and j3.uses == 2, "a second grant adds a stack")
b3.ground = false
tick(s3, { jump = true })
tick(s3, { jump = true })
tick(s3, { jump = true })
T.check(j3.uses == 0, "two stacks: two air jumps")

---------------------------------------------------------------------------
-- Wall jump: priority over the air jump, lock, slide
---------------------------------------------------------------------------
b = fake()
b.ground, b.wall = false, -1                       -- a wall on the left
set = abilities.new(b)
local wj = set:grant({ kind = "wall_jump", id = "wall_jump" })
local aj = set:grant({ kind = "air_jump", id = "air_jump" })
T.check(wj.priority < aj.priority, "the wall jump runs before the air jump")
tick(set, { jump = true, move_x = -1, jump_speed = 260 })
T.check(b.vx == 180 and b.vy == -260, "kicked away from the left wall and up")
T.check(intent.consumed_jump and aj.uses == 1, "the jump is used and the air jump refilled")
T.check(intent.move_x == 0, "pushing into the wall is ignored during the lock")
tick(set, { move_x = -1 })
T.check(intent.move_x == 0, "still locked")
for _ = 1, 10 do tick(set, { move_x = -1 }) end
T.check(intent.move_x == -1, "the lock runs out")
b.vy = 200
tick(set, { move_x = 1 })                          -- a wall on the right? no: wall is left
tick(set, { move_x = -1 })
T.check(b.vy == 60, "falling into a wall is capped at slide_speed")
b = fake()
b.ground, b.wall = false, 1
set = abilities.new(b)
set:grant({ kind = "wall_jump", id = "w", slide_speed = 0 })
b.vy = 200
tick(set, { move_x = 1 })
T.check(b.vy == 200, "slide_speed 0 disables the cap")

---------------------------------------------------------------------------
-- Dash
---------------------------------------------------------------------------
b = fake()
b.ground = true
set = abilities.new(b)
local dash = set:grant({ kind = "dash", id = "dash" })
tick(set, { dash = true, move_x = 1 })
T.check(dash.active and dash.dir_x == 1 and dash.dir_y == 0, "button dash: right")
T.check(b.vx == 330 and b.vy == 0, "held at the dash speed")
b.vx, b.vy = 0, 50
tick(set)
T.check(dash.active and b.vx == 330 and b.vy == 0, "the velocity is held every step")
local n = 0
while dash.active and n < 30 do tick(set); n = n + 1 end
T.check(n >= 8 and not dash.active, "it lasts about time (" .. n .. " steps)")
tick(set, { dash = true, move_x = 1 })
T.check(not dash.active, "the cooldown holds")
-- air uses
b = fake()
b.ground = false
set = abilities.new(b)
dash = set:grant({ kind = "dash", id = "d", cooldown = 0, time = DT })
tick(set, { dash = true, move_x = 1 })
T.check(dash.active and dash.air_left == 0, "an air dash spends the use")
tick(set)
tick(set, { dash = true, move_x = 1 })
T.check(not dash.active, "no second air dash")
b.ground = true
tick(set)
T.check(dash.air_left == 1, "landing refills it")
-- double tap
b = fake()
b.ground = true
set = abilities.new(b)
dash = set:grant({ kind = "dash", id = "d", trigger = "double_tap", cooldown = 0, time = DT })
tick(set, { move_x = 1 })
T.check(not dash.active, "one tap is not a dash")
tick(set, { move_x = 0 })
tick(set, { move_x = 1 })
T.check(dash.active and dash.dir_x == 1 and dash.dir_y == 0, "two taps of the same side dash")
-- different directions and a slow pair
b = fake()
b.ground = true
set = abilities.new(b)
dash = set:grant({ kind = "dash", id = "d", trigger = "double_tap", cooldown = 0 })
tick(set, { move_x = 1 })
tick(set, { move_x = 0 })
tick(set, { move_x = -1 })
T.check(not dash.active, "taps to different sides do not dash")
tick(set, { move_x = 0 })
for _ = 1, 20 do tick(set, { move_x = 0 }) end
tick(set, { move_x = 1 })
T.check(not dash.active, "taps too far apart do not dash")
-- wall in the dash direction ends it
b = fake()
b.ground, b.wall = true, 1
set = abilities.new(b)
dash = set:grant({ kind = "dash", id = "d", cooldown = 0 })
tick(set, { dash = true, move_x = 1 })
T.check(dash.active, "a dash starts at the wall")
tick(set)
T.check(not dash.active, "a wall in its direction ends it early")

---------------------------------------------------------------------------
-- Hook
---------------------------------------------------------------------------
local function hook_set()
  local body = fake(0, 0)
  local s = abilities.new(body, { solid = function(x) return x >= 40 end })
  local h = s:grant({ kind = "hook", id = "hook" })
  return body, s, h
end
local hook
b, set, hook = hook_set()
T.check(hook.phase == "idle" and hook.priority == 5, "the hook starts idle")
tick(set, { hook = true, facing = 1 })
T.check(hook.phase == "flying" and hook.dir_x > 0 and hook.dir_y < 0, "it flies toward the facing, above")
for _ = 1, 40 do
  tick(set)
  if hook.phase ~= "flying" then break end
end
T.check(hook.phase == "attached" and hook.hx < 40 and hook.length > 0, "it attaches before the wall")
T.check(hook.length > 16, "the rope is longer than min_length")
-- rope: the body beyond the circle is pulled back
b.x, b.y = -100, 0
tick(set)
T.check(b.vx > 0, "a taut rope removes the outward velocity")
-- reel
local len = hook.length
tick(set, { move_y = -1 })
T.near(hook.length, len - 1, "move_y up reels in at reel px/s", 1e-6)
for _ = 1, 100 do tick(set, { move_y = -1 }) end
T.check(hook.length >= 16, "the length stops at min_length")
-- pump
b.x, b.y = hook.hx, hook.hy
b.vx, b.vy = 0, 0
tick(set, { move_x = 1 })
T.near(b.vx, 260 * DT, "move_x pumps the swing", 1e-6)
-- release on jump, with the boost and the air refill
local s_air = abilities.new(b, { solid = function() return false end })
local h_air = s_air:grant({ kind = "hook", id = "h" })
local aj_air = s_air:grant({ kind = "air_jump", id = "j" })
h_air.phase, h_air.hx, h_air.hy, h_air.length = "attached", 0, 0, 16
aj_air.uses = 0
b.vx, b.vy = 10, 20
tick(s_air, { jump = true, jump_speed = 260 })
T.check(h_air.phase == "idle" and intent.consumed_jump, "jump releases the hook")
T.near(b.vx, 10, "keeping the swing velocity", 1e-6)
T.near(b.vy, -110, "plus a small upward kick", 1e-6)
T.check(aj_air.uses == 1, "and refills the air jump")
-- release on hook again
b, set, hook = hook_set()
tick(set, { hook = true })
for _ = 1, 40 do tick(set); if hook.phase ~= "flying" then break end end
T.check(hook.phase == "attached", "attached before the second press")
tick(set, { hook = true })
T.check(hook.phase == "idle" and not intent.consumed_jump, "a second press releases it")
-- a miss comes back
b = fake()
set = abilities.new(b, { solid = function() return false end })
hook = set:grant({ kind = "hook", id = "h" })
tick(set, { hook = true })
for _ = 1, 40 do tick(set); if hook.phase ~= "flying" then break end end
T.check(hook.phase == "idle", "beyond the range it comes back")

---------------------------------------------------------------------------
-- reset, state and set_state
---------------------------------------------------------------------------
b = fake()
set = abilities.new(b, { solid = function() return false end })
local sd = set:grant({ kind = "dash", id = "dash", trigger = "double_tap" })
local sh = set:grant({ kind = "hook", id = "hook" })
sh.phase = "attached"
sd.active = true
set:reset()
T.check(not sd.active and sh.phase == "idle", "reset drops the dash and the hook")
local sj = set:grant({ kind = "air_jump", id = "dj" })
set:grant({ kind = "air_jump", id = "dj" })
local state = set:state()
T.check(#state == 3, "state: one entry per ability")
local copy = abilities.new(fake())
copy:set_state(state)
T.check(copy:has("dash") and copy:has("hook") and copy:stacks("dj") == 2, "set_state restores ids and stacks")
T.check(copy:get("dash").trigger == "double_tap" and copy:get("dj").max_uses == 2,
  "the definitions travel with the state")

---------------------------------------------------------------------------
-- A real soft body on a platformer grid
---------------------------------------------------------------------------
local function room()
  return gridmod.new({
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "#..................#",
    "####################",
  }, { tile_size = 16 })
end
local g = room()
local slime = softbody.new({ x = 80, y = 20, radius = 8 })
for _ = 1, 120 do slime:step(DT, g) end
T.check(slime:on_ground(), "the slime is on the floor")
local sset = abilities.new(slime, { grid = g })
local saj = sset:grant({ kind = "air_jump", id = "dj" })
tick(sset, { jump = true })
T.check(not intent.consumed_jump and saj.uses == 1, "on the ground the air jump leaves the jump alone")
slime:impulse(0, -300)
slime:step(DT, g)
tick(sset, { jump = true })
T.check(intent.consumed_jump and saj.uses == 0, "in the air it uses the jump")

---------------------------------------------------------------------------
-- Nothing allocated per step
---------------------------------------------------------------------------
b = fake(50, 20)
set = abilities.new(b, { solid = function() return false end })
set:grant({ kind = "air_jump", id = "dj" })
set:grant({ kind = "wall_jump", id = "wj" })
set:grant({ kind = "dash", id = "dash", trigger = "double_tap" })
set:grant({ kind = "hook", id = "hook" })
local function move(i)
  intent.jump = i % 7 == 0
  intent.jump_held = i % 7 < 3
  intent.dash = false
  intent.hook = i % 31 == 0
  intent.move_x = i % 40 < 20 and 1 or -1
  intent.move_y = i % 13 == 0 and -1 or 0
  intent.jump_speed, intent.facing = 260, 1
  intent.consumed_jump = false
  b.wall = i % 17 == 0 and (i % 2 == 0 and -1 or 1) or 0
  b.ground = i % 23 == 0
  set:step(DT, intent)
end
for i = 1, 200 do move(i) end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for i = 201, 500 do move(i) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
T.check(grown == 0, "with every kind granted a step allocates nothing (" .. grown .. " KB)")

---------------------------------------------------------------------------
-- Static checks
---------------------------------------------------------------------------
local f = assert(io.open("engine/modules/abilities/init.lua", "rb"))
local src = f:read("*a"):gsub("%-%-[^\n]*", ""); f:close()
T.check(not src:find("%f[%w]goto%f[%W]") and not src:find("ffi") and not src:find("%f[%w_]jit%."),
  "abilities: no goto, FFI or jit")
T.check(not src:find("%f[%w_]love%f[%W]") and not src:find("math%.random") and not src:find("os%.time"),
  "abilities: no love, nothing random, no clock")
T.check(not src:find("require"), "abilities: needs no other module")
T.no_new_globals(globals)
