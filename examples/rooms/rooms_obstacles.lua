-- Breakable props of the rooms example. A crate is plain data plus a small persistent state
-- (health and a broken flag) that the room keeps in its rooms_state, so a broken crate stays
-- broken when the slime comes back. Its `virus` data says what a break can drop; the room rolls
-- that with the run's rng stream. No love at load: only draw() touches love.graphics.
local type, floor, tostring = type, math.floor, tostring

local M = {}

M.defs = {
  crate = {
    w = 12, h = 12, health = 1,
    color = { 0.70, 0.50, 0.28 },
    virus = { chance = 0.35, amount = 1 },
  },
}

local function def_of(kind)
  local def = M.defs[kind]
  if not def then error("obstacles: unknown kind " .. tostring(kind), 4) end
  return def
end

-- obstacles.new(kind, x, y, state) -> an obstacle at x, y (top-left). `state` is the room's
-- persistent table for this prop; the flag (`broken`) and health live there. Nil makes a fresh
-- one. Unknown kinds raise.
function M.new(kind, x, y, state)
  local def = def_of(kind)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("obstacles: new needs numeric x and y", 3)
  end
  if state == nil then state = {} end
  if type(state) ~= "table" then error("obstacles: state is a table", 3) end
  if state.health == nil then state.health = def.health end
  if state.broken then state.health = 0 end
  return { kind = kind, def = def, x = x, y = y, w = def.w, h = def.h, state = state }
end

-- obstacles.hit(obstacle, amount) -> true if it is broken after the hit. Cracks health down
-- and sets the persistent broken flag at zero. Hitting an already broken prop changes nothing.
function M.hit(obstacle, amount)
  if amount == nil then amount = 1 end
  if type(amount) ~= "number" or amount < 0 or amount ~= floor(amount) then
    error("obstacles: hit needs a whole amount >= 0", 2)
  end
  if M.is_broken(obstacle) then return true end
  obstacle.state.health = obstacle.state.health - amount
  if obstacle.state.health <= 0 then
    obstacle.state.health = 0
    obstacle.state.broken = true
  end
  return obstacle.state.broken == true
end

function M.is_broken(obstacle)
  return obstacle.state.broken == true or (obstacle.state.health or 0) <= 0
end

-- obstacles.overlaps(obstacle, x, y, w, h) -> AABB with a box at x, y (top-left), w by h.
-- A broken prop does not block or hurt anything.
function M.overlaps(obstacle, x, y, w, h)
  if M.is_broken(obstacle) then return false end
  return x < obstacle.x + obstacle.w and x + w > obstacle.x
    and y < obstacle.y + obstacle.h and y + h > obstacle.y
end

-- obstacles.draw(obstacle, g): optional; g is love.graphics (the only love here).
function M.draw(obstacle, g)
  if M.is_broken(obstacle) then return end
  local c = obstacle.def.color
  g.setColor(c[1], c[2], c[3], 1)
  g.rectangle("fill", obstacle.x, obstacle.y, obstacle.w, obstacle.h)
  g.setColor(0, 0, 0, 0.25)
  g.rectangle("line", obstacle.x, obstacle.y, obstacle.w, obstacle.h)
end

return M
