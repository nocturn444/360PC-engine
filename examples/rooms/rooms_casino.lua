-- Casino machines of the rooms example: a genetic lottery that can give or take a mutation,
-- and a slot machine that costs virus. Each machine keeps its persistent state in a table given
-- by the room (the same pattern as rooms_machines.lua): `used` for the lottery, `spins` for the
-- slots. Logic is data only; only draw() touches love.graphics.
local type, floor, tostring = type, math.floor, tostring

local content = require("rooms_content")

local M = {}

M.defs = {
  lottery = {
    uses = 1, color = { 0.92, 0.76, 0.28 }, label = "LOTTO",
  },
  slots = {
    color = { 0.66, 0.42, 0.86 }, label = "SLOTS",
  },
}

-- Editable data: the price of a spin and the weighted prizes. A prize is { kind, amount };
-- "nothing" carries amount 0. `bonus_key` is a string the caller turns into its pickup.
M.tuning = {
  slot_price = 3,
  slot_prizes = {
    { kind = "nothing", amount = 0, weight = 50 },
    { kind = "virus", amount = 6, weight = 20 },
    { kind = "heart", amount = 1, weight = 15 },
    { kind = "bonus_key", amount = 1, weight = 10 },
    { kind = "virus", amount = 15, weight = 5 },
  },
}

local function is_count(n)
  return type(n) == "number" and n >= 0 and n == floor(n)
end

local function def_of(kind)
  local def = M.defs[kind]
  if not def then error("casino: unknown kind " .. tostring(kind), 4) end
  return def
end

local function check_state(state, field, caller)
  if type(state) ~= "table" then error("casino: state is a table", caller) end
  if state[field] == nil then state[field] = 0 end
  if not is_count(state[field]) then
    error("casino: state." .. field .. " is a whole number >= 0", caller)
  end
end

-- casino.new(kind, x, y, state) -> a machine at x, y (top-left). `state` is the room's
-- persistent table for this machine; nil makes a fresh one.
function M.new(kind, x, y, state)
  local def = def_of(kind)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("casino: new needs numeric x and y", 3)
  end
  if state == nil then state = {} end
  if type(state) ~= "table" then error("casino: state is a table", 3) end
  if kind == "lottery" then check_state(state, "used", 3)
  else check_state(state, "spins", 3) end
  return { kind = kind, def = def, x = x, y = y, state = state }
end

-- casino.used_up(machine) -> true only for a spent lottery (the slots are unlimited).
function M.used_up(machine)
  if machine.kind ~= "lottery" then return false end
  local state = machine.state
  return state ~= nil and (state.used or 0) >= 1
end

-- casino.gain_chance(luck) -> the chance the lottery gives a mutation: 0.5 at luck 5,
-- clamped to 0.1..0.9.
function M.gain_chance(luck)
  local p = 0.5 * content.luck_multiplier(luck)
  if p < 0.1 then return 0.1 end
  if p > 0.9 then return 0.9 end
  return p
end

-- casino.lottery(state, rng, luck, owned_mutations) -> "gain", "lose", "nothing", or
-- false, "used up". It marks the machine used. On "lose" it also returns the owned mutation
-- (one element of the list, picked with rng) that the caller removes; with no owned mutations
-- the result is "nothing". On "gain" the caller draws from its mutation pool.
function M.lottery(state, rng, luck, owned_mutations)
  check_state(state, "used", 3)
  if rng == nil or type(rng.chance) ~= "function" then
    error("casino: lottery needs an rng", 3)
  end
  if state.used >= 1 then return false, "used up" end
  state.used = state.used + 1
  if rng:chance(M.gain_chance(luck)) then return "gain" end
  local n = owned_mutations and #owned_mutations or 0
  if n == 0 then return "nothing" end
  local i = rng:int(1, n)
  return "lose", owned_mutations[i]
end

-- casino.spin(state, rng, wallet) -> a prize { kind, amount }, or false, reason. It spends
-- casino.tuning.slot_price virus from the wallet and counts the spin. Reasons: "not enough".
function M.spin(state, rng, wallet)
  check_state(state, "spins", 3)
  if rng == nil or type(rng.weighted) ~= "function" then
    error("casino: spin needs an rng", 3)
  end
  local price = M.tuning.slot_price
  if wallet == nil or not wallet:can("virus", price) then return false, "not enough" end
  if not wallet:spend("virus", price) then return false, "not enough" end
  state.spins = state.spins + 1
  local prize = rng:weighted(M.tuning.slot_prizes, "weight")
  return { kind = prize.kind, amount = prize.amount }
end

-- casino.draw(machine, g, near): optional; g is love.graphics (the only love here). `near`
-- shows the label, for a prompt. A spent lottery is dimmed.
function M.draw(machine, g, near)
  local def = machine.def or def_of(machine.kind)
  local c = def.color
  if M.used_up(machine) then
    g.setColor(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4, 1)
  else
    g.setColor(c[1], c[2], c[3], 1)
  end
  g.rectangle("fill", machine.x, machine.y, 12, 12)
  g.setColor(0, 0, 0, 0.3)
  g.rectangle("line", machine.x, machine.y, 12, 12)
  if near then g.print(def.label, machine.x, machine.y - 12) end
end

return M
