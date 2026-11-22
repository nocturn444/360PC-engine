-- The pact room's mutualist larvae. Each larva offers one pact: the slime gives up one heart
-- slot (a permanent -1 to the health stat in rooms_stats) and gets one mutation. The caller
-- gives the mutation and clamps the current health to the new maximum.
-- No love at load: only draw() touches love.graphics.
local stats_defs = require("rooms_stats")

local M = {}

M.tuning = { larvae = 2, cost = 1 }

-- pacts.new(x, y, state, source) -> a larva at x, y (top-left). `state` is the room's persistent
-- table for this larva; `used` says its pact is taken. Nil makes a fresh one. `source` is the
-- permanent modifier's unique key in the run (e.g. "pact:<floor>:<room>:<i>"): two larvae at the
-- same x, y on different floors must not share it.
function M.new(x, y, state, source)
  if type(x) ~= "number" or type(y) ~= "number" then
    error("pacts: new needs numeric x and y", 2)
  end
  if state == nil then state = {} end
  if type(state) ~= "table" then error("pacts: state is a table", 2) end
  if state.used == nil then state.used = false end
  if type(state.used) ~= "boolean" then error("pacts: state.used is a boolean", 2) end
  if type(source) ~= "string" or source == "" then
    error("pacts: source is a non-empty string", 2)
  end
  return { x = x, y = y, state = state, source = source }
end

-- pacts.can_accept(larva, stats) -> allowed, reason. Reasons: "used" and "too weak" (one heart
-- slot is the minimum, so a pact never takes the last one).
function M.can_accept(larva, stats)
  if larva.state.used then return false, "used" end
  if stats:get("health") <= stats_defs.defs.health.min then return false, "too weak" end
  return true, nil
end

-- pacts.accept(larva, stats) -> true, or false and the reason. It takes the pact's heart slot
-- permanently and marks the larva used; the caller gives the mutation.
function M.accept(larva, stats)
  local allowed, reason = M.can_accept(larva, stats)
  if not allowed then return false, reason end
  if not stats:add_permanent("health", -M.tuning.cost, larva.source) then
    return false, "used"
  end
  larva.state.used = true
  return true
end

local PALE = { 0.93, 0.90, 0.76 }
local DARK = { 0.62, 0.58, 0.48 }

-- pacts.draw(larva, g, near): optional; g is love.graphics (the only love here). A small pale
-- grub from rectangles, dimmed and without its label once used.
function M.draw(larva, g, near)
  local used = larva.state.used
  local f = used and 0.45 or 1
  local a = used and 0.45 or 1
  g.setColor(PALE[1] * f, PALE[2] * f, PALE[3] * f, a)
  g.rectangle("fill", larva.x + 2, larva.y + 4, 8, 5)
  g.rectangle("fill", larva.x + 8, larva.y + 3, 4, 6)
  g.setColor(DARK[1] * f, DARK[2] * f, DARK[3] * f, a)
  g.rectangle("fill", larva.x + 4, larva.y + 4, 1, 1)
  g.rectangle("fill", larva.x + 6, larva.y + 4, 1, 1)
  if near and not used then
    g.setColor(1, 1, 1, 1)
    g.print("PACT -1 HP", larva.x, larva.y - 12)
  end
end

return M
