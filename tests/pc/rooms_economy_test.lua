-- examples/rooms: the economy data of a run. Pickups (heart, virus) are plain data with a small
-- overlap test; crates are breakable props with a persistent broken flag; machines take a
-- wallet currency, keep their own use count and say why a buy is refused.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_economy_test.lua  (ends with "OK:")
package.path = "./?.lua;./?/init.lua;./tests/engine/?.lua;./examples/rooms/?.lua;" .. package.path

local checks = 0
local function check(cond, what)
  checks = checks + 1
  if not cond then print("FAILED: " .. what); os.exit(1) end
end
local function refuses(f, what, pattern)
  local ok, err = pcall(f)
  check(not ok and tostring(err):find(pattern, 1, true), what .. " (" .. tostring(err) .. ")")
end

local wallet = require("engine.modules.wallet")
local pickups = require("rooms_pickups")
local props = require("engine.modules.props")
local prop_types = require("rooms_props").types
local machines = require("rooms_machines")

-- Pickups: constructors, defaults and the small AABB
local h = pickups.heart(40, 60)
check(h.kind == "heart" and h.x == 40 and h.y == 60 and h.amount == 1, "heart defaults to amount 1")
local v = pickups.virus(10, 20, 3)
check(v.kind == "virus" and v.amount == 3, "virus keeps its amount")
check(pickups.heart(0, 0, 0).amount == 0, "an amount of zero is allowed")
refuses(function() pickups.heart("x", 0) end, "a non-numeric x", "numeric x and y")
refuses(function() pickups.virus(0, 0, 1.5) end, "a fractional amount", "whole amount >= 0")
refuses(function() pickups.virus(0, 0, -1) end, "a negative amount", "whole amount >= 0")
check(pickups.overlaps(h, 40, 60) and pickups.overlaps(h, 44, 64), "overlap: centre and edge")
check(not pickups.overlaps(h, 45, 60) and not pickups.overlaps(h, 40, 65), "overlap: just outside")
local hc, vc = pickups.color(h), pickups.color(v)
check(hc ~= vc and hc[1] > hc[2] and vc[2] > vc[1], "colours: heart red, virus green")
check(pickups.label(h) == "HEART" and pickups.label(v) == "VIRUS", "labels")

-- Crates: the prop type and its fields, a hit, the broken state and persistence
local def = prop_types:get("crate")
check(def and def.collision == "solid" and def.size.w == 1 and def.size.h == 1
  and def.field_by_key.health.default == 1 and def.field_by_key.virus_chance.default == 0.35
  and def.field_by_key.virus.default == 1, "the crate definition")
local state = {}
local set = props.set(prop_types, { { type = "crate", tx = 1, ty = 1 } }, { state = state })
local crate = set:at(1)
check(crate.x == 0 and crate.y == 0 and crate.w == 16 and crate.state.health == 1 and not crate.removed,
  "a fresh crate")
check(set:first(1, 1, 2, 2, "breakable") == crate and set:first(40, 40, 2, 2, "breakable") == nil,
  "the overlap query")
check(not set:hit(crate, 0) and not crate.removed, "a zero hit does not break it")
check(set:hit(crate, 1) and crate.removed, "a hit breaks it")
check(state[1].removed == true and state[1].health == 0, "the room's state remembers it")
check(not set:hit(crate, 5) and crate.removed, "hitting a broken crate changes nothing")
local again = props.set(prop_types, { { type = "crate", tx = 1, ty = 1 } }, { state = state })
check(again:at(1).removed, "the room rebuilds it broken")
local other = props.set(prop_types, { { type = "crate", tx = 1, ty = 1 } })
check(other:at(1).state ~= crate.state, "each crate gets its own state")

-- Machines: accepts money, price, uses, per-machine state and the reasons
local heal_def = machines.defs.healer
check(heal_def.accepts_money == true and heal_def.currency == "virus" and heal_def.price == 5
  and heal_def.uses == 1 and heal_def.effect == "heal_full", "the healer definition")
refuses(function() machines.new("shop", 0, 0) end, "an unknown kind", "unknown kind")
local w = wallet.new({ virus = 0 })
local mstate = {}
local healer = machines.new("healer", 0, 0, mstate)
check(mstate.used == 0 and machines.available(healer) and machines.uses_left(healer) == 1,
  "a fresh healer")
local ok, reason = machines.can_buy(healer, w)
check(not ok and reason == "not enough", "no money: not enough")
local bought, why = machines.buy(healer, w)
check(bought == false and why == "not enough" and mstate.used == 0, "a refused buy spends nothing")
w:add("virus", 4)
check(not machines.can_buy(healer, w), "one short: still not enough")
w:add("virus", 1)
check(machines.can_buy(healer, w), "exactly the price is enough")
local effect = machines.buy(healer, w)
check(effect == "heal_full" and w:get("virus") == 0 and mstate.used == 1, "buy spends and counts a use")
check(not machines.available(healer) and machines.uses_left(healer) == 0, "used up")
w:add("virus", 100)
local ok2, reason2 = machines.can_buy(healer, w)
check(not ok2 and reason2 == "used up", "a spent machine says used up even with money")
check(machines.buy(healer, w) == false and w:get("virus") == 100, "and a second buy is refused")
-- per-machine state: another healer is untouched
local other_state = {}
local other = machines.new("healer", 30, 0, other_state)
check(other_state.used == 0 and machines.available(other) and machines.uses_left(other) == 1,
  "a second machine has its own state")
check(machines.buy(other, w) == "heal_full" and other_state.used == 1 and mstate.used == 1,
  "using one does not use the other")
-- a machine that does not take money
machines.defs.not_a_shop = { accepts_money = false, currency = "virus", price = 1, uses = 1,
  effect = "nothing", color = { 1, 1, 1 }, label = "USE" }
local plain = machines.new("not_a_shop", 0, 0, {})
local ok3, reason3 = machines.can_buy(plain, w)
check(not ok3 and reason3 == "not accepts_money", "a free/use machine is not a shop")
check(machines.buy(plain, w) == false, "and cannot be bought from")
machines.defs.not_a_shop = nil

print(string.format("OK: %d checks; rooms economy", checks))
