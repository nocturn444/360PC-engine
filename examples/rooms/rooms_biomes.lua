-- The biomes of a run (procgen.biomes), Blob's standard path, the same every run: floors 1-2
-- forest, 3-4 deep jungle, 5 grotto, 6-7 fungal cave, 8 catacombs, 9 labs, 10 catastrophe.
-- Each biome is fixed to its floor and carries the game's own data:
--   difficulty  1..5: copied to map.difficulty; the enemies' health and bite grow with it
--   mobs        the enemies of the biome: health, damage and colour (boss: the boss and minibosses)
--   colors      walls and ledges
--   music       the track engine.audio plays on its floors (audio:music(biome.music, { fade = 1 }))
--   rooms_add   rooms more (or fewer) than the plan gives the floor
-- Mutations of a biome are entries of rooms_mutations.lua with `biomes = { id }`.
-- Only the names and colours are Blob's for now; the enemy numbers are the old placeholders.
local procgen = require("engine.modules.procgen")

local M = {}

M.list = {
  { id = "forest", name = "FOREST", fixed = "first", span = 2, difficulty = 1, music = "music/forest",
    mobs = { id = "forest_mob", health = 2, damage = 1, color = { 0.80, 0.62, 0.30 } },
    boss = { id = "forest_boss", health = 6, damage = 2, color = { 0.65, 0.40, 0.20 } },
    colors = { wall = { 0.14, 0.24, 0.14 }, ledge = { 0.50, 0.38, 0.22 } },
    glow = { 0.60, 0.84, 0.35 } },
  { id = "deep_jungle", name = "DEEP JUNGLE", fixed = 3, span = 2, difficulty = 2, music = "music/deep_jungle", rooms_add = 1,
    mobs = { id = "deep_jungle_mob", health = 2, damage = 1, color = { 0.95, 0.75, 0.20 } },
    boss = { id = "deep_jungle_boss", health = 7, damage = 2, color = { 0.90, 0.35, 0.30 } },
    colors = { wall = { 0.06, 0.18, 0.12 }, ledge = { 0.30, 0.62, 0.32 } },
    glow = { 0.98, 0.90, 0.52 } },
  { id = "grotto", name = "GROTTO", fixed = 5, span = 1, difficulty = 2, music = "music/grotto",
    mobs = { id = "grotto_mob", health = 3, damage = 1, color = { 0.55, 0.75, 0.90 } },
    boss = { id = "grotto_boss", health = 8, damage = 2, color = { 0.35, 0.50, 0.95 } },
    colors = { wall = { 0.16, 0.20, 0.26 }, ledge = { 0.42, 0.58, 0.68 } },
    glow = { 0.62, 0.88, 0.94 } },
  { id = "fungal_cave", name = "FUNGAL CAVE", fixed = 6, span = 2, difficulty = 3, music = "music/fungal_cave",
    mobs = { id = "fungal_cave_mob", health = 3, damage = 2, color = { 0.40, 0.95, 0.85 } },
    boss = { id = "fungal_cave_boss", health = 9, damage = 3, color = { 0.95, 0.45, 0.80 } },
    colors = { wall = { 0.20, 0.12, 0.26 }, ledge = { 0.70, 0.40, 0.80 } },
    glow = { 0.77, 0.44, 0.82 } },
  { id = "catacombs", name = "CATACOMBS", fixed = 8, span = 1, difficulty = 3, music = "music/catacombs",
    mobs = { id = "catacombs_mob", health = 3, damage = 1, color = { 0.88, 0.84, 0.70 } },
    boss = { id = "catacombs_boss", health = 9, damage = 2, color = { 0.75, 0.70, 0.50 } },
    colors = { wall = { 0.22, 0.20, 0.17 }, ledge = { 0.66, 0.62, 0.52 } },
    glow = { 0.91, 0.76, 0.35 } },
  { id = "labs", name = "LABS", fixed = 9, span = 1, difficulty = 4, music = "music/labs",
    mobs = { id = "labs_mob", health = 4, damage = 2, color = { 0.55, 0.95, 0.40 } },
    boss = { id = "labs_boss", health = 12, damage = 3, color = { 0.30, 0.85, 0.95 } },
    colors = { wall = { 0.18, 0.21, 0.25 }, ledge = { 0.72, 0.80, 0.86 } },
    glow = { 0.35, 0.69, 0.29 } },
  { id = "catastrophe", name = "CATASTROPHE", fixed = "last", span = 1, difficulty = 5, music = "music/catastrophe", rooms_add = -2,
    mobs = { id = "catastrophe_mob", health = 4, damage = 2, color = { 1.00, 0.55, 0.20 } },
    boss = { id = "catastrophe_boss", health = 14, damage = 3, color = { 1.00, 0.25, 0.25 } },
    colors = { wall = { 0.26, 0.08, 0.08 }, ledge = { 0.85, 0.35, 0.15 } },
    glow = { 0.91, 0.38, 0.17 } },
}

function M.new(floors) return procgen.biomes.new(M.list, { floors = floors or 10 }) end

-- The stats of a biome's enemies (combat.stats overrides): its mobs, a little stronger the
-- harder the biome (+1 health every 2 levels of difficulty above 1).
function M.enemy_stats(biome, boss)
  local m = boss and biome.boss or biome.mobs
  local extra = math.floor(((biome.difficulty or 1) - 1) / 2)
  return { max_health = m.health + extra, attack_damage = m.damage,
    invuln_time = boss and 0.4 or 0.25, knockback_resist = boss and 0.5 or 0 }
end

return M
