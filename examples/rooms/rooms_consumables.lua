-- The consumables of the rooms example: small drops that heal or hurt the slime when picked up.
-- A consumable is plain data (engine.modules.items entries) plus its `kind` and effect. These
-- are examples only: the real consumables are the game's to design.
--
-- Fields:
--   id, name, weight, kind ("heart" | "virus")
--   sources   where it can drop: "mob", "room_clear", "obstacle", "machine"
--   heal      hearts: health restored
--   amount    virus: stacks (or damage) the game applies
--   color     RGB, for the game to draw
local M = {}

M.entries = {
  {
    id = "heart",
    name = "HEART",
    weight = 10,
    kind = "heart",
    sources = { "mob", "room_clear", "obstacle" },
    heal = 1,
    tags = { "heal" },
    color = { 0.95, 0.30, 0.40 },
    example = true,
  },
  {
    id = "virus",
    name = "VIRUS",
    weight = 8,
    kind = "virus",
    sources = { "obstacle", "machine", "room_clear" },
    amount = 1,
    tags = { "hazard" },
    color = { 0.55, 0.85, 0.30 },
    example = true,
  },
}

return M
