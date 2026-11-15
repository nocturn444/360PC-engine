# tests/

| Path | What it is |
|---|---|
| `console/number_check.lua` | LuaJIT interpreter number check (from Love360). Run on PC with `luajit -joff tests/console/number_check.lua`; on the console the log has to end with `== numbers: 0 of 36 wrong ==`. |

| `pc/boot_pc.lua` | Runs the console boot (`runtime/lua/boot.lua`) on PC against a game, with a fake `l360` table and the graphics stub. `luajit -joff tests/pc/boot_pc.lua` must end with `OK:`. Needs `python3` (it runs the shader build with `--hlsl-only` for the fixture's metadata). |
| `fixtures/minimal_game/` | The smallest game: `game.lua`, `conf.lua`, `main.lua` and one shader (`shaders/tint.glsl`). Also runs on LÖVE 11.x. |
| `shaders/` | Shader build tests: the GLSL to HLSL translator, its xost rules and the metadata (with a small HLSL interpreter), and the notices file of `tools/shaders/xost_windows`. `python3 -m unittest discover -s tests/shaders` must end with `OK`; needs no Windows or xost. |

Love360's other PC tests (fake xsdk GPU, audio and file system for the C code) are not ported yet.
