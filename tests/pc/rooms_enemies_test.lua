-- examples/rooms: the enemy types as data. Every type builds its brain and stats from
-- rooms_enemy_types.lua and runs 600 steps in a test room; a shooter in sight fires; a hopper
-- leaves the ground; a flyer stays off the ground and inside the room; the type picked for a
-- spot is deterministic for a seed; and eight mixed enemies (two sprayers firing) step for 600
-- steps under the interpreter, printing the milliseconds per step.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_enemies_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end

local platformer = require("engine.modules.platformer")
local combat = require("engine.modules.combat")
local enemies = require("rooms_enemies")
local types = require("rooms_enemy_types")

-- A 30 x 12 room: empty, with a solid floor along the bottom.
local rows = {}
for y = 1, 11 do rows[y] = string.rep(".", 30) end
rows[12] = string.rep("#", 30)
local grid = platformer.grid.new(rows, { tile_size = 16 })
local ROOM_W, ROOM_H = 30 * 16, 12 * 16
local FLOOR = 11 * 16

-- The fight only reads these methods of the slime (a soft body in the game).
local function fake_slime(x, y)
  local s = { x = x, y = y, w = 18, h = 18 }
  function s:bounds() return self.x, self.y, self.x + self.w, self.y + self.h end
  function s:center() return self.x + self.w / 2, self.y + self.h / 2 end
  function s:velocity() return 0, 0 end
  function s:set_velocity() end
  return s
end

local function make(slime, spots, seed)
  return enemies.new(slime, grid, spots, {
    enemy_stats = combat.stats.new({ max_health = 5, attack_damage = 1, invuln_time = 0.25 }),
    slime_stats = combat.stats.new({ max_health = 10000, attack_damage = 1, invuln_time = 1 }),
    seed = seed or 1,
  })
end

-- 1. The registry: the eight types of the plan, in the pick order, each with a brain and a look
local expected = { "walker", "hopper", "charger", "shooter", "sniper", "sprayer", "bat", "drone" }
check(#types.order == #expected, "the registry lists eight types")
for i = 1, #expected do
  local id = expected[i]
  check(types.order[i] == id, "registry order " .. i .. ": " .. id)
  local spec = types.types[id]
  check(spec and spec.brain and spec.look and spec.look.shape == id, id .. ": a brain and a look")
  check(spec.move == "fly" or spec.move == "walk", id .. ": a movement kind")
end

-- 2. Every type builds and runs 600 steps without errors, in a room with the slime ahead
for i = 1, #types.order do
  local id = types.order[i]
  local slime = fake_slime(6 * 16, FLOOR - 18)
  local f = make(slime, { { x = 16 * 16, y = FLOOR, type = id } })
  local ok, err = pcall(function()
    for _ = 1, 600 do f:step(1 / 60) end
  end)
  check(ok, id .. ": 600 steps without errors (" .. tostring(err) .. ")")
  local e = f.enemies[1]
  check(e and not e.fighter.dead, id .. ": still alive after 600 steps")
  check(e.machine and e.machine.state, id .. ": runs its brain")
end

-- 3. A shooter with the target in sight fires
local slime = fake_slime(6 * 16, FLOOR - 18)
local f = make(slime, { { x = 16 * 16, y = FLOOR, type = "shooter" } })
local fired, shots = false, 0
for _ = 1, 600 do
  f:step(1 / 60)
  local n = f.enemy_arsenal:count()
  if n > 0 then fired = true end
  if n > shots then shots = n end
end
check(fired and f.enemies[1].attacks.spit.uses > 0,
  "a shooter with the target in sight fires (" .. f.enemies[1].attacks.spit.uses .. " times)")
check(shots <= 32, "the enemy shots stay inside the arsenal's cap (" .. shots .. ")")

-- 4. A hopper leaves the ground
slime = fake_slime(6 * 16, FLOOR - 18)
f = make(slime, { { x = 16 * 16, y = FLOOR, type = "hopper" } })
local air, jumped = false, false
for _ = 1, 600 do
  f:step(1 / 60)
  local body = f.enemies[1].body
  if not body.on_ground then air = true end
  if body.jumped then jumped = true end
end
check(air and jumped, "a hopper leaves the ground")

-- 5. A flyer never touches the ground and stays in the room (the slime is mid-air here)
slime = fake_slime(6 * 16, 5 * 16)
f = make(slime, { { x = 16 * 16, y = 5 * 16, type = "drone" } })
local touched_ground, outside = false, false
for _ = 1, 600 do
  f:step(1 / 60)
  local b = f.enemies[1].body
  if b.floor then touched_ground = true end
  if b.x < 0 or b.y < 0 or b.x + b.w > ROOM_W or b.y + b.h > ROOM_H then outside = true end
end
check(not touched_ground, "a flyer never touches the ground")
check(not outside, "a flyer stays inside the room")

-- 6. The type chosen for a spot is deterministic for a seed, and only names known types
local pool = { walker = 4, hopper = 1 }
for seed = 1, 20 do
  for index = 1, 8 do
    local a = enemies.pick_type(pool, seed, index)
    local b = enemies.pick_type(pool, seed, index)
    check(a == b and types.types[a] ~= nil,
      "seed " .. seed .. " spot " .. index .. ": " .. a)
  end
end
check(enemies.pick_type(nil, 1, 1) == "walker", "no pool: walker")
check(enemies.pick_type({}, 1, 1) == "walker", "empty pool: walker")

-- 7. Performance: eight mixed enemies (two sprayers) for 600 steps, print the ms per step
slime = fake_slime(14 * 16, FLOOR - 18)
local spots = {
  { x = 3 * 16, y = FLOOR, type = "walker" },
  { x = 5 * 16, y = FLOOR, type = "hopper" },
  { x = 7 * 16, y = FLOOR, type = "charger" },
  { x = 9 * 16, y = FLOOR, type = "shooter" },
  { x = 11 * 16, y = FLOOR, type = "sniper" },
  { x = 18 * 16, y = FLOOR, type = "sprayer" },
  { x = 20 * 16, y = FLOOR, type = "sprayer" },
  { x = 22 * 16, y = FLOOR, type = "drone" },
}
f = make(slime, spots, 7)
for _ = 1, 30 do f:step(1 / 60) end          -- warm the pools and the paths
local started = os.clock()
for _ = 1, 600 do f:step(1 / 60) end
local elapsed = os.clock() - started
local ms = elapsed * 1000 / 600
print(string.format("8 mixed enemies, 600 steps: %.3f ms per step", ms))
check(f:alive() == 8, "the eight mixed enemies survive the run")
check(f.enemy_arsenal:count() <= 32, "the shots stay capped")

print(string.format("OK: %d checks; the enemy types build, run, fire, hop and fly", checks))
