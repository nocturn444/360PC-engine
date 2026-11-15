# tools/

Build and packaging tools: `compat_check.lua` (objective 5), game
packaging and the generic FTP installer (objective 9).

- `read_game_config.lua`: prints `title_id`, `name`, `identity` and `save_dir` of a game's
  `game.lua` for the build ([../docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)).
- `shaders/build_shaders.py`: builds a game's declared shaders for the console (GLSL to HLSL with
  `shaders/glsl2hlsl.py`, then xost) into `.psu`/`.vsu` and `.meta.lua`
  ([../docs/SHADERS.md](../docs/SHADERS.md)).
- `shaders/xost_windows/`: builds the xost compiler (`xsc.dll`, `glslang.exe`) that
  `build_shaders.py` runs.
