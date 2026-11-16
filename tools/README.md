# tools/

Build, packaging and validation tools. The whole path from a new game to the console is in
[../docs/NEW_GAME.md](../docs/NEW_GAME.md).

- `read_game_config.lua`: prints `title_id`, `name`, `identity` and `save_dir` of a game's
  `game.lua` for the build ([../docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)).
- `check_libs.lua`: the rules of `lib/` (objective 16). Each library needs a license file, a row in `lib/README.md` with its version and commit, and an entry in `THIRD_PARTY_NOTICES.md` with the full commit. Its Lua must use no FFI, `goto` or `jit.*`, and no `love.*` function outside the console subset; stubs only get a warning. Run `luajit tools/check_libs.lua` from the repository root.
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
- `package.py`: assembles a game's console folder from the game folder, the built `.xex` and
  the compiled shaders: the game's files without development files, the `engine/` core and the
  modules and `lib/` libraries the game uses, `l360/` (the runtime's Lua), `shaders/`, and a
  `package_manifest.txt`. It reads and validates `game.lua` (through `read_game_config.lua`,
  or a small built-in parser when there is no LuaJIT), has `--dry-run` and `--zip`. Python 3,
  standard library only, Windows and Linux.
  `python tools/package.py <game> --xex runtime/build/game.xex --shaders <built shaders>`.
- `install_ftp.py`: uploads a packaged folder to the console over FTP (Aurora), by default to
  `Hdd1:/Games/<folder name>/`. Host, port, user, password and target come from arguments or
  `X360_FTP_*` variables. Uploads only changed files (size, and CRC-32 against the manifest of
  the last install), never deletes anything, never touches saves or the log; `--dry-run`,
  `--force`. `python tools/install_ftp.py dist/<identity> --host <console IP>`.
- `ldtk_convert.py`: converts an LDtk project (`.ldtk`, with its `.ldtkl` files when levels are
  saved separately) into the level file `engine/level.lua` reads: rooms with collisions, exits,
  items, entities and tile layers, as sorted data in the text format of `engine/save.lua`.
  Python 3, standard library only, Windows and Linux.
  `python tools/ldtk_convert.py levels/world.ldtk -o levels/world.lvl --root <game> [--cell WxH]`
  ([../docs/LEVELS.md](../docs/LEVELS.md)).
- `seed_validator.lua`: bulk seed validation for games with procedural levels
  (`engine/modules/procgen`). `luajit tools/seed_validator.lua <game> <spec module> --count N
  [--out level_hashes.txt]` generates N seeds from the spec the game provides and reports
  failures, attempts statistics and hashes; `--out` writes the hash list that
  `tests/console/level_hash_check.lua` compares on the console.
