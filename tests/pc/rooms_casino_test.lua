-- examples/rooms casino machines: the genetic lottery (single use, gain rate by luck, lose
-- with and without mutations) and the slot machine (price, refusal when broke, prize weights),
-- with deterministic rng streams and the optional draw.
-- Usage, from the repository root: luajit -joff tests/pc/rooms_casino_test.lua   (ends with "OK:")
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

local Rng = require("engine.rng")
local wallet = require("engine.modules.wallet")
local casino = require("rooms_casino")

-- Definitions, tuning and constructors
check(casino.defs.lottery and casino.defs.lottery.uses == 1
  and casino.defs.lottery.label == "LOTTO", "the lottery definition")
check(casino.defs.slots and casino.defs.slots.label == "SLOTS", "the slots definition")
check(casino.tuning.slot_price == 3, "a spin costs 3 virus")
local prizes = casino.tuning.slot_prizes
check(#prizes == 5, "five slot prizes")
local total = 0
for i = 1, #prizes do
  local p = prizes[i]
  check(type(p.kind) == "string" and type(p.amount) == "number"
    and type(p.weight) == "number" and p.weight > 0, "prize " .. i .. " is well formed")
  total = total + p.weight
end
check(total == 100, "the prize weights add up to 100")
check(prizes[1].kind == "nothing" and prizes[1].amount == 0 and prizes[1].weight == 50,
  "nothing: 50")
check(prizes[2].kind == "virus" and prizes[2].amount == 6 and prizes[2].weight == 20,
  "6 virus: 20")
check(prizes[3].kind == "heart" and prizes[3].amount == 1 and prizes[3].weight == 15,
  "1 heart: 15")
check(prizes[4].kind == "bonus_key" and prizes[4].amount == 1 and prizes[4].weight == 10,
  "1 bonus key: 10")
check(prizes[5].kind == "virus" and prizes[5].amount == 15 and prizes[5].weight == 5,
  "15 virus: 5")

refuses(function() casino.new("roulette", 0, 0) end, "an unknown kind", "unknown kind")
refuses(function() casino.new("lottery", "x", 0) end, "a non-numeric x", "numeric x and y")
refuses(function() casino.new("lottery", 0, 0, { used = 1.5 }) end,
  "a fractional used count", "whole number >= 0")
local lstate, sstate = {}, {}
local lotto = casino.new("lottery", 10, 20, lstate)
local slots = casino.new("slots", 30, 40, sstate)
check(lstate.used == 0 and sstate.spins == 0, "fresh machines start at zero")
check(lotto.x == 10 and lotto.y == 20 and slots.x == 30 and slots.y == 40, "machine positions")
check(not casino.used_up(lotto) and not casino.used_up(slots), "fresh machines are available")
check(casino.new("lottery", 0, 0).state ~= casino.new("lottery", 0, 0).state,
  "each machine gets its own state")

-- The lottery's chance per luck: 0.25 at luck 0, 0.5 at 5, 0.75 at 10
check(math.abs(casino.gain_chance(0) - 0.25) < 1e-9, "luck 0: 25%")
check(math.abs(casino.gain_chance(5) - 0.5) < 1e-9, "luck 5: 50%")
check(math.abs(casino.gain_chance(10) - 0.75) < 1e-9, "luck 10: 75%")
check(math.abs(casino.gain_chance(-20) - 0.1) < 1e-9, "the chance is clamped at 10%")
check(math.abs(casino.gain_chance(20) - 0.9) < 1e-9, "the chance is clamped at 90%")
check(math.abs(casino.gain_chance() - 0.5) < 1e-9, "no luck is neutral luck 5")

-- Single use, and the used-up state is persistent
local first_state = {}
local first = casino.lottery(first_state, Rng.new(1), 5, nil)
check(first == "gain" or first == "nothing", "the first lottery draw is gain or nothing")
check(first_state.used == 1, "the lottery is marked used")
local again, why = casino.lottery(first_state, Rng.new(2), 5, nil)
check(again == false and why == "used up", "a second use is refused")
check(first_state.used == 1, "a refused use does not mark it again")
check(casino.used_up(casino.new("lottery", 0, 0, first_state)), "a rebuilt machine reads used up")
check(not casino.used_up(slots) and sstate.spins == 0, "using the lottery does not touch the slots")

-- Gain rate close to the chance over many seeds, for luck 0, 5 and 10
local TRIALS = 4000
for _, luck in ipairs({ 0, 5, 10 }) do
  local wins = 0
  for seed = 1, TRIALS do
    if casino.lottery({}, Rng.new(seed), luck, nil) == "gain" then wins = wins + 1 end
  end
  local rate = wins / TRIALS
  check(math.abs(rate - casino.gain_chance(luck)) < 0.04,
    string.format("luck %d: gain rate %.3f close to %.3f", luck, rate, casino.gain_chance(luck)))
end

-- On a loss with no owned mutations the result is "nothing"
local loss_seed
for seed = 1, 100 do
  local state = {}
  local result = casino.lottery(state, Rng.new(seed), 5, nil)
  if result ~= "gain" then
    check(result == "nothing", "a loss with no mutations is nothing")
    loss_seed = seed
    break
  end
end
check(loss_seed ~= nil, "a losing seed is found")
local empty_state = {}
check(casino.lottery(empty_state, Rng.new(loss_seed), 5, {}) == "nothing",
  "an empty mutation list is nothing too")

-- On a loss with mutations, the returned one is from the list; the same seed repeats it
local owned = { { id = "a" }, { id = "b" }, { id = "c" } }
local removed_seed
for seed = 1, 200 do
  local result, removed = casino.lottery({}, Rng.new(seed), 5, owned)
  if result == "lose" then
    removed_seed = seed
    local found = false
    for i = 1, #owned do
      if removed == owned[i] then found = true end
    end
    check(found, "the lost mutation is one of the owned ones")
    break
  end
end
check(removed_seed ~= nil, "a losing seed with mutations is found")
local _, removed_a = casino.lottery({}, Rng.new(removed_seed), 5, owned)
local _, removed_b = casino.lottery({}, Rng.new(removed_seed), 5, owned)
check(removed_a == removed_b and removed_a ~= nil, "the same seed removes the same mutation")
check(casino.lottery({}, Rng.new(1), 5, nil) == casino.lottery({}, Rng.new(1), 5, nil),
  "the lottery is deterministic for the same rng seed")

-- Slots: a spin spends the price and counts, and a broke wallet is refused without a spin
local w = wallet.new({ virus = casino.tuning.slot_price - 1 })
local spin_state = {}
local no_prize, no_reason = casino.spin(spin_state, Rng.new(9), w)
check(no_prize == false and no_reason == "not enough", "one short: not enough")
check(w:get("virus") == 2 and spin_state.spins == 0, "a refused spin spends nothing")
w:add("virus", 1)
local prize = casino.spin(spin_state, Rng.new(9), w)
check(type(prize) == "table" and type(prize.kind) == "string" and type(prize.amount) == "number",
  "a paid spin gives a prize")
check(w:get("virus") == 0 and spin_state.spins == 1, "a spin spends 3 and counts")
local broke, broke_reason = casino.spin(spin_state, Rng.new(10), w)
check(broke == false and broke_reason == "not enough" and spin_state.spins == 1,
  "broke: refused, no extra spin")
w:add("virus", 30)
for i = 1, 10 do
  check(casino.spin(spin_state, Rng.new(100 + i), w) ~= false, "a rich wallet keeps spinning")
end
check(w:get("virus") == 0 and spin_state.spins == 11, "ten spins spend 30 and count")

-- Prize distribution roughly matches the weights
local N = 5000
local dist = {}
local rich = wallet.new({ virus = casino.tuning.slot_price * N })
local dist_state = {}
local r = Rng.new("slot distribution")
for i = 1, N do
  local p = casino.spin(dist_state, r, rich)
  local key = p.kind .. ":" .. p.amount
  dist[key] = (dist[key] or 0) + 1
end
check(rich:get("virus") == 0 and dist_state.spins == N, "every trial spun and paid")
local expected = {
  ["nothing:0"] = 0.50,
  ["virus:6"] = 0.20,
  ["heart:1"] = 0.15,
  ["bonus_key:1"] = 0.10,
  ["virus:15"] = 0.05,
}
for key, want in pairs(expected) do
  local got = (dist[key] or 0) / N
  check(math.abs(got - want) < 0.03,
    string.format("%s: %.3f close to %.2f", key, got, want))
end

-- Deterministic prizes for the same rng seed
local function slot_sequence(seed)
  local sw = wallet.new({ virus = casino.tuning.slot_price * 20 })
  local st = {}
  local sr = Rng.new(seed)
  local out = {}
  for i = 1, 20 do
    local p = casino.spin(st, sr, sw)
    out[i] = p and (p.kind .. ":" .. p.amount) or "nil"
  end
  return table.concat(out, ","), st.spins
end
local seq_a, spins_a = slot_sequence(42)
local seq_b, spins_b = slot_sequence(42)
check(seq_a == seq_b and spins_a == 20 and spins_b == 20, "same seed, same prizes and spins")
check(seq_a ~= slot_sequence(43), "a different seed spins differently")

-- Draw: the labels when near, and no love at load
local printed = 0
local text
local g = {
  setColor = function() end,
  rectangle = function() end,
  print = function(value) text = value; printed = printed + 1 end,
}
casino.draw(lotto, g, false)
check(printed == 0, "no label when not near")
casino.draw(lotto, g, true)
check(printed == 1 and text == "LOTTO", "the lottery label")
casino.draw(slots, g, true)
check(printed == 2 and text == "SLOTS", "the slots label")

print(string.format("OK: %d checks; the rooms casino machines work", checks))
