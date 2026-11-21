-- The biomes of a run (procgen.biomes): the cellar always opens the run and the core always
-- ends it; in between the caves, the garden and the forge come at random (the forge only from
-- floor 5), and the ruins only when the slime has fought its way there (12 kills or more).
-- Each biome lasts 1 to 3 floors and carries the game's own data:
--   difficulty  1..5: copied to map.difficulty; the enemies' health and bite grow with it
--   mobs        the enemies of the biome: health, damage and colour (boss: the boss and minibosses)
--   colors      walls and ledges
--   music       the track engine.audio plays on its floors (audio:music(biome.music, { fade = 1 }))
--   rooms_add   rooms more (or fewer) than the plan gives the floor
-- Mutations of a biome are entries of rooms_mutations.lua with `biomes = { id }`.
local procgen = require("engine.modules.procgen")

local M = {}

M.list = {
  { id = "cellar", name = "CELLAR", fixed = "first", span = 2, difficulty = 1, music = "music/cellar",
    mobs = { id = "cellar_mob", health = 2, damage = 1, color = { 0.85, 0.55, 0.25 } },
    boss = { id = "cellar_boss", health = 6, damage = 2, color = { 0.85, 0.30, 0.55 } },
    colors = { wall = { 0.20, 0.22, 0.30 }, ledge = { 0.45, 0.48, 0.58 } } },
  { id = "caves", name = "CAVES", span = { 1, 3 }, weight = 3, difficulty = 2, music = "music/caves", rooms_add = 1,
    mobs = { id = "caves_mob", health = 2, damage = 1, color = { 0.55, 0.70, 0.90 } },
    boss = { id = "caves_boss", health = 7, damage = 2, color = { 0.35, 0.45, 0.95 } },
    colors = { wall = { 0.16, 0.20, 0.26 }, ledge = { 0.40, 0.55, 0.65 } } },
  { id = "garden", name = "GARDEN", span = 2, weight = 2, difficulty = 2, music = "music/garden",
    mobs = { id = "garden_mob", health = 3, damage = 1, color = { 0.50, 0.80, 0.35 } },
    boss = { id = "garden_boss", health = 8, damage = 2, color = { 0.30, 0.65, 0.25 } },
    colors = { wall = { 0.16, 0.26, 0.18 }, ledge = { 0.45, 0.65, 0.40 } } },
  { id = "forge", name = "FORGE", span = { 1, 2 }, weight = 2, min_floor = 5, difficulty = 3, music = "music/forge",
    mobs = { id = "forge_mob", health = 3, damage = 2, color = { 0.95, 0.45, 0.20 } },
    boss = { id = "forge_boss", health = 9, damage = 3, color = { 0.90, 0.25, 0.15 } },
    colors = { wall = { 0.30, 0.18, 0.14 }, ledge = { 0.75, 0.45, 0.25 } } },
  { id = "ruins", name = "RUINS", span = 1, weight = 4, difficulty = 3, music = "music/ruins",
    when = function(run) return run and (run.kills or 0) >= 12 end,
    mobs = { id = "ruins_mob", health = 3, damage = 1, color = { 0.80, 0.75, 0.55 } },
    boss = { id = "ruins_boss", health = 9, damage = 2, color = { 0.70, 0.60, 0.30 } },
    colors = { wall = { 0.28, 0.26, 0.22 }, ledge = { 0.62, 0.58, 0.45 } } },
  { id = "core", name = "CORE", fixed = "last", span = 1, difficulty = 5, music = "music/core", rooms_add = -2,
    mobs = { id = "core_mob", health = 4, damage = 2, color = { 0.85, 0.35, 0.85 } },
    boss = { id = "core_boss", health = 14, damage = 3, color = { 1.00, 0.30, 0.60 } },
    colors = { wall = { 0.22, 0.12, 0.26 }, ledge = { 0.60, 0.35, 0.70 } } },
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
