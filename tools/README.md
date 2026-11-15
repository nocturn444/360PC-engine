# tools/

Build and packaging tools. Still to come: game packaging and the generic FTP installer
(objective 9).

- `read_game_config.lua`: prints `title_id`, `name`, `identity` and `save_dir` of a game's
  `game.lua` for the build ([../docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)).
- `compat_check.lua` (with `api_subset_data.lua`): required first thing in a game's `main.lua` on
  official LÖVE on PC, it logs once every call the game makes that the console does not have, is
  a stub, or goes beyond a limit, and the callbacks the console never calls; `compat.report()`
  prints the totals ([../docs/API_SUBSET.md](../docs/API_SUBSET.md)).
- `gen_api_subset.lua`: `luajit tools/gen_api_subset.lua` regenerates `docs/API_SUBSET.md` and
  `api_subset_data.lua` from the runtime's code and the hand-written `api_subset_notes.lua`
  (`--check` fails if they are out of date). Run it after changing the API in `runtime/`.
- `shaders/build_shaders.py`: builds a game's declared shaders for the console (GLSL to HLSL with
  `shaders/glsl2hlsl.py`, then xost) into `.psu`/`.vsu` and `.meta.lua`
  ([../docs/SHADERS.md](../docs/SHADERS.md)).
- `shaders/xost_windows/`: builds the xost compiler (`xsc.dll`, `glslang.exe`) that
  `build_shaders.py` runs.
