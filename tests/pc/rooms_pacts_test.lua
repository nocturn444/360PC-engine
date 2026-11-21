-- examples/rooms/rooms_pacts.lua: the pact room's larvae, the permanent -1 health and the
-- per-larva state. Usage, from the repository root:
-- luajit -joff tests/pc/rooms_pacts_test.lua   (must end with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path
local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local P = require("rooms_pacts")
local S = require("rooms_stats")

local function fresh() return S.new({}) end

-- Accept lowers the max health by one and marks the larva
local stats = fresh()
local larva = P.new(0, 0, {})
check(stats:get("health") == 5, "the base health")
local ok, reason = P.can_accept(larva, stats)
check(ok == true and reason == nil, "a fresh pact can be accepted")
check(P.accept(larva, stats) == true, "accept returns true")
check(stats:get("health") == 4, "a pact costs one heart slot")
check(larva.state.used == true, "the larva is used")

-- Cannot accept twice
ok, reason = P.can_accept(larva, stats)
check(not ok and reason == "used", "a used larva refuses with used")
check(P.accept(larva, stats) == false, "accepting twice does nothing")
check(stats:get("health") == 4, "the second accept does not cost again")

-- Two larvae are independent, each with its own heart slot
stats = fresh()
local a = P.new(0, 0, {})
local b = P.new(16, 0, {})
check(P.accept(a, stats) and stats:get("health") == 4, "the first larva takes one slot")
check(P.accept(b, stats) and stats:get("health") == 3, "the second larva takes another")
check(P.tuning.larvae == 2 and P.tuning.cost == 1, "the tuning numbers")

-- Refuses at the health minimum: a pact never takes the last slot
stats = fresh()
check(stats:add_permanent("health", -4, "test:weak"), "bring the health to its minimum")
check(stats:get("health") == 1, "health is at the minimum")
local weak = P.new(0, 0, {})
ok, reason = P.can_accept(weak, stats)
check(not ok and reason == "too weak", "a pact refuses at the minimum")
check(P.accept(weak, stats) == false and stats:get("health") == 1, "accept refuses too")
check(weak.state.used == false, "a refused pact does not mark the larva used")

-- The used state persists through a new larva built with the same state
stats = fresh()
local state = {}
local first = P.new(4, 8, state)
check(P.accept(first, stats) == true and first.state.used == true, "the first larva takes it")
local again = P.new(4, 8, state)
check(again.state.used == true, "the used state comes back")
ok, reason = P.can_accept(again, stats)
check(not ok and reason == "used", "the rebuilt larva is still used")

-- A permanent pact survives serialize/set_state
local saved = stats:serialize()
local restored = fresh()
restored:set_state(saved)
check(restored:get("health") == stats:get("health"), "the pact's heart slot is saved")

-- Draw: a label when near and fresh, none once used
local function fake_g()
  local g = { calls = 0, text = nil }
  function g.setColor() g.calls = g.calls + 1 end
  function g.rectangle() g.calls = g.calls + 1 end
  function g.print(text) g.text = text; g.calls = g.calls + 1 end
  return g
end
local g = fake_g()
P.draw(P.new(0, 0, {}), g, true)
check(g.text == "PACT -1 HP" and g.calls > 0, "a fresh larva shows its pact when near")
g = fake_g()
P.draw(P.new(0, 0, { used = true }), g, true)
check(g.text == nil and g.calls > 0, "a used larva is drawn without the label")

print("OK: " .. checks .. " checks")
