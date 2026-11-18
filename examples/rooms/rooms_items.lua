-- The items of the treasure room (engine.modules.items): one sits on the pedestal of each
-- treasure room, drawn from the run's "loot" stream for the floor's biome. Some come anywhere,
-- others only in their biomes (`biomes`). An item's `bonus` is added to the slime's run bonus
-- (rooms_play.lua): max_health and damage add up, move and jump multiply, invuln adds seconds.
local items = require("engine.modules.items")

local M = {}

M.entries = {
  { id = "heart_up", name = "HEART UP", weight = 4, rooms = { "treasure" }, bonus = { max_health = 1 },
    color = { 0.95, 0.30, 0.40 } },
  { id = "spring", name = "SPRING", weight = 3, max = 1, rooms = { "treasure" }, bonus = { jump = 1.15 },
    color = { 0.40, 0.85, 0.95 } },
  { id = "swift", name = "SWIFT", weight = 3, max = 1, rooms = { "treasure" }, bonus = { move = 1.2 },
    color = { 0.95, 0.95, 0.50 } },
  { id = "crystal", name = "CRYSTAL", weight = 5, max = 1, rooms = { "treasure" }, biomes = { "caves" },
    bonus = { invuln = 0.5 }, color = { 0.60, 0.75, 1.00 } },
  { id = "moss", name = "MOSS", weight = 5, max = 1, rooms = { "treasure" }, biomes = { "garden" },
    bonus = { max_health = 2 }, color = { 0.45, 0.85, 0.35 } },
  { id = "ember", name = "EMBER", weight = 5, max = 1, rooms = { "treasure" }, biomes = { "forge", "core" },
    bonus = { damage = 1 }, color = { 1.00, 0.50, 0.20 } },
  { id = "relic", name = "RELIC", weight = 6, max = 1, rooms = { "treasure" }, biomes = { "ruins" },
    bonus = { max_health = 1, damage = 1 }, color = { 0.85, 0.75, 0.40 } },
}

function M.pool(unlocked) return items.pool.new(M.entries, { unlocked = unlocked }) end

-- The run's bonus with nothing taken, and with an item's bonus added.
function M.no_bonus() return { max_health = 0, damage = 0, move = 1, jump = 1, invuln = 0 } end

function M.apply(bonus, entry)
  local b = entry.bonus or {}
  bonus.max_health = bonus.max_health + (b.max_health or 0)
  bonus.damage = bonus.damage + (b.damage or 0)
  bonus.invuln = bonus.invuln + (b.invuln or 0)
  bonus.move = bonus.move * (b.move or 1)
  bonus.jump = bonus.jump * (b.jump or 1)
  return bonus
end

return M
