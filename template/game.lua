-- 360PC-Engine game config (docs/GAME_CONFIG.md in the base). Data only.
-- Change every value: the Title ID identifies the game on the console and must be unique.
return {
  name = "New Game",
  identity = "new_game",
  title_id = "0x4D47F001",
  save_dir = "save",
  -- debug = true,            -- development builds only: turns engine.debug on
  -- default_font = "assets/font.ttf",   -- needed to draw text on the console
}
