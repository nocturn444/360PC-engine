-- examples/rooms/rooms_stats.lua: the run stats, the mutation stacks and tags, the combat source
-- mapping, and the shield resource (absorb, overflow, recharge). Uses combat.world for the hits.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_stats_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local S = require("rooms_stats")
local C = require("engine.modules.combat")

local DEFS = {
  { id = "luck_up", stats = { { "luck", "add", 100 } } },
  { id = "speedy", stats = { { "speed", "mul_base", 0.25 } } },
  { id = "jumper", stats = { { "jump", "mul_base", 0.5 } } },
  { id = "sharp", stats = { { "damage", "add", 2 } } },
  { id = "buckler", stats = { { "shield", "add", 3 } } },
  { id = "heart", stats = { { "health", "add", 2 } } },
  { id = "slow", stats = { { "speed", "mul", 0.1 } } },
  { id = "stack_dmg", stacking = "stack", max_stacks = 3, tags = { "fire", "buff" },
    stats = { { "damage", "add", 1 } } },
}
local function fresh() return S.new(DEFS) end
local function body() return { x = 0, y = 0, w = 10, h = 10, facing = 1, vx = 0, vy = 0 } end

-- Base values and caps
local s = fresh()
check(s:get("luck") == 5 and s:get("jump") == 1 and s:get("speed") == 1
  and s:get("damage") == 1 and s:get("shield") == 0 and s:get("health") == 5, "the base stats")
check(S.defs.luck.base == 5 and S.defs.luck.min == 0 and S.defs.luck.max == 10
  and S.defs.health.base == 5 and S.defs.health.min == 1 and S.defs.health.max == 20, "the schema")
check(s:acquire("luck_up") and s:get("luck") == 10, "a stat is capped at its maximum")
check(s:acquire("slow") and s:get("speed") == 0.5, "and raised to its minimum")
s = fresh()
check(s:acquire("buckler") and s:get("shield") == 3 and s:get("shield") <= S.defs.shield.max, "shield capacity")
check(s:acquire("heart") and s:get("health") == 7, "health is the maximum HP")

-- Unique and stack
s = fresh()
check(s:acquire("stack_dmg") and s:stacks("stack_dmg") == 1 and s:get("damage") == 2, "one stack")
check(s:acquire("stack_dmg") and s:stacks("stack_dmg") == 2 and s:get("damage") == 3, "two stacks")
check(s:acquire("stack_dmg") and s:stacks("stack_dmg") == 3 and s:get("damage") == 4, "three stacks")
check(not s:acquire("stack_dmg") and s:stacks("stack_dmg") == 3 and s:get("damage") == 4, "max_stacks 3")
check(s:acquire("sharp") and not s:acquire("sharp") and s:stacks("sharp") == 1
  and s:get("damage") == 6, "unique: the second acquire does nothing")
local tags = s:tags()
check(tags.fire and tags.buff and not tags.curse, "the tags of what was acquired")

-- Stat modifiers: flat vs jump and speed multipliers
s = fresh()
s:acquire("speedy"); s:acquire("jumper"); s:acquire("sharp"); s:acquire("heart")
check(math.abs(s:get("speed") - 1.25) < 1e-9 and math.abs(s:get("jump") - 1.5) < 1e-9,
  "jump and speed are multipliers")
check(s:get("damage") == 3 and s:get("health") == 7, "damage and health add")

-- The combat source: names mapped, constants, created once
s = fresh()
local src = s:combat_source()
check(src == s:combat_source(), "the combat source is created once")
check(src:get("max_health") == 5 and src:get("attack_damage") == 1, "max_health and attack_damage")
check(src:get("defense") == 0 and src:get("knockback_resist") == 0 and src:get("invuln_time") == 1.0,
  "defense 0, no knockback resistance, one second of i-frames")
s:acquire("sharp"); s:acquire("heart")
check(src:get("max_health") == 7 and src:get("attack_damage") == 3, "the mapping follows the stats")

-- Shield: absorb 1:1 before health, the overflow passes
s = fresh()
s:acquire("buckler")
local current, max = s:shield()
check(current == 3 and max == 3, "a new shield capacity fills the resource")
local world = C.world.new()
local f = world:fighter({ body = body(), team = "player", stats = s:combat_source(), mods = s.mods })
local last
world.on_hit = function(hit) last = hit.amount end
check(f.health == 5, "the fighter starts at the health stat")
world:strike(nil, f, { damage = 2 })
current, max = s:shield()
check(current == 1 and max == 3 and f.health == 5 and last == 0, "2 damage against 3 shield: the shield takes it")
f.invuln = 0
world:strike(nil, f, { damage = 5 })
current, max = s:shield()
check(current == 0 and max == 3 and f.health == 1 and last == 4, "1 absorbs, the other 4 reach health")

-- Recharge after 5 + 2.5 * capacity seconds without a hit
s = fresh()
s:acquire("buckler")
s:set_state({ mutations = { buckler = 1 }, shield = { current = 0, timer = 0 } })
check(s:shield() == 0, "empty shield")
for _ = 1, 24 do s:update(0.5) end                -- 12 s < 12.5
check(s:shield() == 0, "no recharge before 5 + 2.5 * 3 s")
s:update(0.5)                                     -- exactly 12.5 s
check(s:shield() == 3, "refilled at 12.5 s")

-- Any hit restarts the timer, even with 0 shield
s = fresh()
s:acquire("buckler")
s:set_state({ mutations = { buckler = 1 }, shield = { current = 0, timer = 0 } })
world = C.world.new()
f = world:fighter({ body = body(), team = "player", stats = s:combat_source(), mods = s.mods })
for _ = 1, 24 do s:update(0.5) end                -- 12 s: past 10 s but not 12.5 of the last hit
world:strike(nil, f, { damage = 1 })
for _ = 1, 24 do s:update(0.5) end                -- 12 s since the hit < 12.5
check(s:shield() == 0, "a hit with an empty shield restarts the timer")
s:update(0.5)
check(s:shield() == 3, "and the refill comes 12.5 s after that hit")

-- Serialize and set_state
local a = fresh()
a:acquire("stack_dmg"); a:acquire("stack_dmg"); a:acquire("buckler")
a:update(0.5)
local data = a:serialize()
local b = fresh()
b:acquire("sharp")
b:set_state(data)
check(b:stacks("stack_dmg") == 2 and b:get("damage") == a:get("damage"), "the mutation stacks come back")
check(b:stacks("sharp") == 0 and b:get("damage") == 3, "set_state replaces what was there")
check(b:shield() == a:shield(), "the shield resource comes back")

-- update allocates nothing
s = fresh()
s:acquire("buckler")
s:set_state({ mutations = { buckler = 1 }, shield = { current = 0, timer = 0 } })
for _ = 1, 10 do s:update(1 / 60) end
collectgarbage(); collectgarbage("stop")
local before = collectgarbage("count")
for _ = 1, 200 do s:update(1 / 60) end
local grown = collectgarbage("count") - before
collectgarbage("restart")
check(grown == 0, "update allocates nothing (" .. grown .. " KB)")

print("OK: " .. checks .. " checks")
