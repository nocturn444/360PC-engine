-- The consumables and bonus keys of the rooms example: small drops that heal or hurt the slime,
-- or that unlock an optional thing. An entry is plain data (engine.modules.items) plus its
-- `kind` and effect. These are examples only: the real content is the game's to design.
--
-- Fields:
--   id, name, weight, kind ("heart" | "virus" | "bomb" | "bonus_key")
--   sources   where it can drop: "mob", "room_clear", "obstacle", "machine", "shop"
--   heal      hearts: health restored
--   amount    virus: stacks (or damage) the game applies; bomb: bombs given
--   color     RGB, for the game to draw
local M = {}

M.entries = {
  {
    id = "heart",
    name = "HEART",
    weight = 10,
    kind = "heart",
    sources = { "mob", "room_clear", "obstacle", "shop" },
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
  {
    id = "bomb",
    name = "BOMB",
    weight = 10,
    kind = "bomb",
    sources = { "mob", "room_clear", "obstacle", "shop" },
    amount = 1,
    tags = { "bomb" },
    color = { 0.35, 0.35, 0.40 },
    example = true,
  },
}

-- Optional keys, kept apart from the consumables: one opens the super treasure room. The run
-- wallet holds them as the "bonus_key" currency; this is not the per-floor `key` ability.
M.bonus_keys = {
  {
    id = "bonus_key",
    name = "KEY+",
    weight = 1,
    kind = "bonus_key",
    sources = { "mob" },
    amount = 1,
    tags = { "key" },
    color = { 0.65, 0.95, 0.95 },
    example = true,
  },
}

return M
