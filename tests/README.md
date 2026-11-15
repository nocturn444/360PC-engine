# tests/

| Path | What it is |
|---|---|
| `console/xsdk_numeros.lua` | LuaJIT interpreter number check (from Love360). Run on PC with `luajit -joff tests/console/xsdk_numeros.lua`; on the console the log has to end with `== numeros: 0 de 36 mal ==`. |

| `pc/boot_pc.lua` | Runs the console boot (`runtime/lua/boot.lua`) on PC against a game, with a fake `l360` table and the graphics stub. `luajit -joff tests/pc/boot_pc.lua` must end with `OK:`. |
| `fixtures/minimal_game/` | The smallest game: `game.lua`, `conf.lua`, `main.lua`. Also runs on LÖVE 11.x. |

Love360's other PC tests (fake xsdk GPU, audio and file system for the C code) are not ported yet.
