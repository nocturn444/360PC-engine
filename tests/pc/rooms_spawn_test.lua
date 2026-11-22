-- examples/rooms/rooms_spawn: the spawn state of the special rooms (growth, reset, caps), the
-- per-floor update, the chance functions (casino, super treasure, trap with luck, obstacle,
-- pact) and the roomtype definitions. Pure logic, no love.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_spawn_test.lua   (ends with OK:)
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function near(a, b, what, eps)
  checks = checks + 1
  if math.abs(a - b) > (eps or 1e-9) then
    print(string.format("FAILED: %s (got %s, expected %s)", what, tostring(a), tostring(b)))
    os.exit(1)
  end
end
local function run_of(state, luck) return { spawn = state, luck = luck } end

local S = require("rooms_spawn")

-- A new run starts at the documented values
local st = S.new_state()
near(st.casino, 0.00, "new casino")
near(st.trap, 0.05, "new trap")
near(st.obstacle, 0.05, "new obstacle")
check(st.treasure_skipped == false, "new treasure_skipped")

-- Casino: a shop that existed but was not entered grows it by 0.05
st = S.new_state()
S.end_floor(st, { shop_existed = true, shop_entered = false })
near(st.casino, 0.05, "casino after one skipped shop")
S.end_floor(st, { shop_existed = true })
near(st.casino, 0.10, "casino after two skipped shops")
st = S.new_state()
S.end_floor(st, { shop_existed = true, shop_entered = true })
near(st.casino, 0.00, "an entered shop adds nothing")
S.end_floor(st, {})
near(st.casino, 0.00, "no shop adds nothing")

-- Casino caps at 0.95 and resets to 0 when the casino appeared
st = S.new_state()
for _ = 1, 100 do S.end_floor(st, { shop_existed = true }) end
near(st.casino, 0.95, "casino cap")
st.casino = 0.50
S.end_floor(st, { casino_appeared = true, shop_existed = true })
near(st.casino, 0.00, "an appeared casino resets it")

-- Trap: grows by 0.10, caps at 0.95, resets to 0.05 after any trap
st = S.new_state()
S.end_floor(st, {})
near(st.trap, 0.15, "trap after one floor")
S.end_floor(st, { trap_count = 0 })
near(st.trap, 0.25, "trap_count 0 grows it")
for _ = 1, 100 do S.end_floor(st, {}) end
near(st.trap, 0.95, "trap cap")
S.end_floor(st, { trap_count = 1 })
near(st.trap, 0.05, "a trap resets it")
S.end_floor(st, { trap_count = 3 })
near(st.trap, 0.05, "several traps reset it too")

-- Obstacle: additive 0.30 when undamaged, caps at 0.95, resets to 0.05 when damaged
st = S.new_state()
S.end_floor(st, {})
near(st.obstacle, 0.35, "obstacle after one floor")
S.end_floor(st, { damaged = false })
near(st.obstacle, 0.65, "obstacle after two floors")
S.end_floor(st, {})
near(st.obstacle, 0.95, "obstacle cap")
S.end_floor(st, {})
near(st.obstacle, 0.95, "obstacle stays capped")
S.end_floor(st, { damaged = true })
near(st.obstacle, 0.05, "damage resets the obstacle chance")

-- Treasure skipped: only when it existed and was not entered
st = S.new_state()
S.end_floor(st, {})
check(st.treasure_skipped == false, "no treasure is not skipped")
S.end_floor(st, { treasure_existed = true, treasure_entered = false })
check(st.treasure_skipped == true, "a missed treasure is skipped")
S.end_floor(st, { treasure_existed = true, treasure_entered = true })
check(st.treasure_skipped == false, "an entered treasure is not skipped")
st.treasure_skipped = true
S.end_floor(st, { treasure_existed = false })
check(st.treasure_skipped == false, "a floor without treasure clears the flag")
S.end_floor(st, { treasure_existed = true })
check(st.treasure_skipped == true, "treasure_existed alone counts as skipped")

-- Casino chance is the state value
st = S.new_state()
st.casino = 0.40
near(S.casino_chance(4, 10, run_of(st, 5)), 0.40, "casino chance follows the state")

-- Super treasure: 0.33 only after a skipped treasure
st = S.new_state()
near(S.super_treasure_chance(4, 10, run_of(st, 5)), 0.00, "no super treasure normally")
st.treasure_skipped = true
near(S.super_treasure_chance(4, 10, run_of(st, 5)), 0.33, "super treasure after a skip")

-- Trap chance: state.trap times the luck factor, luck 5 is x1, less luck is more traps
st = S.new_state()
near(S.trap_chance(4, 10, run_of(st, 0)), 0.075, "trap chance at luck 0 (x1.5)")
near(S.trap_chance(4, 10, run_of(st, 5)), 0.050, "trap chance at luck 5 (x1)")
near(S.trap_chance(4, 10, run_of(st, 10)), 0.025, "trap chance at luck 10 (x0.5)")
near(S.trap_chance(4, 10, run_of(st, -100)), 0.075, "luck factor caps at 1.5")
st.trap = 0.10
near(S.trap_chance(4, 10, run_of(st, -100)), 0.150, "luck factor max with a bigger state")
near(S.trap_chance(4, 10, run_of(st, 100)), 0.050, "luck factor bottoms at 0.5")
st.trap = 0.95
near(S.trap_chance(4, 10, run_of(st, 0)), 0.95, "trap chance clamps at 0.95")
st.trap = 0
near(S.trap_chance(4, 10, run_of(st, 0)), 0.00, "no trap chance at zero state")

-- Obstacle chance is the state value
st = S.new_state()
st.obstacle = 0.40
near(S.obstacle_chance(4, 10, run_of(st, 5)), 0.40, "obstacle chance follows the state")

-- Pact: 0.15 from floor 3
st = S.new_state()
near(S.pact_chance(1, 10, run_of(st, 5)), 0.00, "no pact on floor 1")
near(S.pact_chance(2, 10, run_of(st, 5)), 0.00, "no pact on floor 2")
near(S.pact_chance(3, 10, run_of(st, 5)), 0.15, "pact from floor 3")
near(S.pact_chance(10, 10, run_of(st, 5)), 0.15, "pact on the last floor")

-- The definitions, in order, with their fields and chance functions
check(#S.defs == 5, "five defs")
local order = { "casino", "super_treasure", "pact", "trap", "obstacle" }
local by = {}
for i, entry in ipairs(S.defs) do
  check(entry.name == order[i], "def order: " .. order[i])
  check(type(entry.def) == "table" and type(entry.def.chance) == "function",
    "def chance is a function: " .. order[i])
  by[entry.name] = entry.def
end
check(by.casino.count == 1 and by.casino.replaces == "shop" and by.casino.max_floor == -2
  and by.casino.min_depth == 2, "casino def")
check(by.super_treasure.count == 1 and by.super_treasure.replaces == "treasure"
  and by.super_treasure.min_depth == 2, "super treasure def")
check(by.pact.count == 1 and by.pact.min_floor == 3 and by.pact.min_depth == 2, "pact def")
check(type(by.trap.count) == "table" and by.trap.count[1] == 1 and by.trap.count[2] == 2
  and by.trap.max == 2 and by.trap.distance == "far", "trap def")
check(by.obstacle.count == 1 and by.obstacle.min_depth == 2, "obstacle def")

-- The defs' chance functions are the public rules with the run argument
st = S.new_state()
st.casino = 0.35
st.trap = 0.20
st.obstacle = 0.30
near(by.casino.chance(5, 10, run_of(st, 5)), S.casino_chance(5, 10, run_of(st, 5)),
  "casino def chance")
near(by.super_treasure.chance(5, 10, run_of(st, 5)), 0,
  "super treasure def chance without a skip")
st.treasure_skipped = true
near(by.super_treasure.chance(5, 10, run_of(st, 5)), 0.33,
  "super treasure def chance after a skip")
near(by.trap.chance(5, 10, run_of(st, 0)), S.trap_chance(5, 10, run_of(st, 0)),
  "trap def chance uses luck")
near(by.obstacle.chance(5, 10, run_of(st, 5)), S.obstacle_chance(5, 10, run_of(st, 5)),
  "obstacle def chance")
near(by.pact.chance(2, 10, run_of(st, 5)), 0, "pact def chance before floor 3")
near(by.pact.chance(3, 10, run_of(st, 5)), 0.15, "pact def chance from floor 3")

print("OK: " .. checks .. " checks")
