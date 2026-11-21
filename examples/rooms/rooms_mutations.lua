-- The run mutations of the rooms example. A mutation is plain data: it changes a stat with an
-- `op` ("mul_base" adds to a multiplier base, for example), can change the slime's look or its
-- body shape, and can be weighted by the tags the run already built (synergy/anti). These two
-- are examples only: the real mutations are the game's to design.
--
-- Fields:
--   id, name, weight, rarity ("common" | "rare" | "epic")
--   sources   where it can drop: "treasure", "boss", "shop"
--   rooms/biomes/floors/mobs/requires   optional filters (items handles rooms/biomes/requires)
--   unique    true: one per run (max = 1)
--   max_stacks   a stackable mutation: max = max_stacks
--   tags      what the mutation gives, for later synergy rules
--   synergy/anti   tags that raise/lower its weight (rooms_content.weigh)
--   stats     array of { stat, op, value }
--   look      visual fragment for the game to draw
--   body      optional physical rest shape ({ width = 24 } or { radius = 11 })
--   color     RGB
local M = {}

M.entries = {
  {
    id = "example_spring_heel",
    name = "SPRING HEEL",
    weight = 4,
    rarity = "rare",
    sources = { "treasure", "boss", "shop" },
    unique = true,
    tags = { "jump" },
    synergy = { "jump" },
    anti = { "heavy" },
    stats = { { "jump", "mul_base", 0.2 } },
    look = {
      body_color = { 0.62, 0.95, 1.00 },
      limb_color = { 0.40, 0.85, 0.95 },
      shape = { sx = 1.06, sy = 0.96 },
      limbs = {
        { anchor = 0.20, side = 1, length = 5, width = 1, color = 5, kind = "antenna" },
        { anchor = 0.80, side = -1, length = 5, width = 1, color = 5, kind = "antenna" },
      },
    },
    color = { 0.40, 0.85, 0.95 },
    example = true,
  },
  {
    id = "example_carapace",
    name = "CARAPACE",
    weight = 3,
    rarity = "rare",
    sources = { "treasure", "boss" },
    unique = true,
    tags = { "shield" },
    synergy = { "shield" },
    anti = { "glass" },
    stats = { { "shield", "add", 2 } },
    look = {
      outline_color = { 0.35, 0.55, 0.40 },
      shape = { sx = 1.04, sy = 0.98 },
      limbs = {
        { anchor = 0.50, side = 1, length = 4, width = 2, color = 5, kind = "shell" },
      },
    },
    color = { 0.55, 0.80, 0.65 },
    example = true,
  },
  {
    id = "example_legs",
    name = "LEGS",
    weight = 3,
    rarity = "common",
    sources = { "treasure" },
    unique = true,
    tags = { "speed" },
    synergy = { "speed" },
    anti = { "heavy" },
    stats = { { "speed", "mul_base", 0.15 } },
    look = {
      body_color = { 0.88, 0.70, 0.35 },
      limbs = {
        { anchor = 0.10, side = 1, length = 6, width = 2, color = 5, kind = "leg" },
        { anchor = 0.35, side = 1, length = 6, width = 2, color = 5, kind = "leg" },
        { anchor = 0.65, side = -1, length = 6, width = 2, color = 5, kind = "leg" },
        { anchor = 0.90, side = -1, length = 6, width = 2, color = 5, kind = "leg" },
      },
    },
    body = { width = 24, height = 20 },
    color = { 0.95, 0.75, 0.35 },
    example = true,
  },
}

return M
