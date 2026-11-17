-- 360PC-Engine game config (docs/GAME_CONFIG.md). Data only.
-- The test's own settings (seed, enemy and particle counts, benchmark mode) are in
-- perf_settings.lua: game.lua only takes the fields the base knows.
return {
  name = "Perf Platformer",
  identity = "perf_platformer",
  title_id = "0x4D470018",
  save_dir = "save",
}
