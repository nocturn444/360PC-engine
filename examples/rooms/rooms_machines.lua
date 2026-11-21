-- Machines of the rooms example: a prop the slime buys from with a currency of the wallet
-- (engine.modules.wallet). The healer is a test machine; shop stock comes later. Each machine
-- has its own persistent state ({ used = 0 }) in the room's rooms_state, so using one never
-- affects another. No love at load: only draw() touches love.graphics.
local type, floor, tostring = type, math.floor, tostring

local M = {}

M.defs = {
  healer = {
    accepts_money = true, currency = "virus", price = 5, uses = 1,
    effect = "heal_full", color = { 0.35, 0.80, 0.55 }, label = "HEAL",
  },
}

local function def_of(kind)
  local def = M.defs[kind]
  if not def then error("machines: unknown kind " .. tostring(kind), 4) end
  return def
end

-- machines.new(kind, x, y, state) -> a machine at x, y (top-left). `state` is the room's
-- persistent table for this machine; `used` counts the buys. Nil makes a fresh one.
function M.new(kind, x, y, state)
  local def = def_of(kind)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("machines: new needs numeric x and y", 3)
  end
  if state == nil then state = {} end
  if type(state) ~= "table" then error("machines: state is a table", 3) end
  if state.used == nil then state.used = 0 end
  if type(state.used) ~= "number" or state.used < 0 or state.used ~= floor(state.used) then
    error("machines: state.used is a whole number >= 0", 3)
  end
  return { kind = kind, def = def, x = x, y = y, state = state }
end

function M.uses_left(machine)
  local left = machine.def.uses - machine.state.used
  if left < 0 then return 0 end
  return left
end

function M.available(machine)
  return M.uses_left(machine) > 0
end

-- machines.can_buy(machine, wallet) -> allowed, reason. Reasons, in the order checked:
-- "not accepts_money", "used up", "not enough".
function M.can_buy(machine, wallet)
  local def = machine.def
  if not def.accepts_money then return false, "not accepts_money" end
  if not M.available(machine) then return false, "used up" end
  if wallet == nil or not wallet:can(def.currency, def.price) then return false, "not enough" end
  return true, nil
end

-- machines.buy(machine, wallet) -> the def's effect string when it works, or false, reason.
-- It spends the price and counts the use only on success.
function M.buy(machine, wallet)
  local allowed, reason = M.can_buy(machine, wallet)
  if not allowed then return false, reason end
  local def = machine.def
  if not wallet:spend(def.currency, def.price) then return false, "not enough" end
  machine.state.used = machine.state.used + 1
  return def.effect
end

-- machines.draw(machine, g, near): optional; g is love.graphics (the only love here). `near`
-- shows the label, for a shop prompt.
function M.draw(machine, g, near)
  local def, c = machine.def, machine.def.color
  if M.available(machine) then
    g.setColor(c[1], c[2], c[3], 1)
  else
    g.setColor(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4, 1)
  end
  g.rectangle("fill", machine.x, machine.y, 12, 12)
  g.setColor(0, 0, 0, 0.3)
  g.rectangle("line", machine.x, machine.y, 12, 12)
  if near and def.label then g.print(def.label, machine.x, machine.y - 12) end
end

return M
