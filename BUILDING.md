# Building 360PC-Engine

This page covers the console runtime (`.xex`). On PC, games run on the official LÖVE 11.x and
need no build step. Packaging, shaders and the installer get their own sections as their
objectives land (see [docs/ROADMAP.md](docs/ROADMAP.md)).

## Layout

| Path | What it is |
|---|---|
| `runtime/` | Console runtime in C on xsdk; builds the `.xex`. See [runtime/README.md](runtime/README.md). |
| `runtime/lua/` | The LÖVE layer in Lua that runs on the console. |
| `toolchain/` | Script and patch to build LuaJIT for xsdk. |
| `tests/console/` | Checks that run on the console (and on PC). |
| `tests/pc/`, `tests/fixtures/` | PC checks of the Lua layer and the games they use. |
| `tools/` | Build and packaging tools (`read_game_config.lua`). |

## Requirements

- Linux (or WSL) with `cmake` (3.25 or newer), `ninja`, `git`, and `gcc` with 32-bit support
  (`gcc-multilib`): LuaJIT's `buildvm` runs as a 32-bit host program.
- [xsdk](https://github.com/xenosworks/xsdk) checked out at the commit in
  `runtime/XSDK_VERSION` (`2c4599b31066efcf67be099673287fbec786ef14`) and built with `make`, as
  its `docs/GETTING_STARTED.md` explains.
- xsdk's GCC toolchain (`tools/toolchain/build.sh` in xsdk), by default in `~/xsdk-gcc`.

## 1. LuaJIT for xsdk

```sh
XSDK_TOOLCHAIN=~/xsdk-gcc bash toolchain/build_luajit_xsdk.sh
```

This clones LuaJIT 2.1 into `third_party/luajit_xsdk/`, checks out the pinned commit
`a4c064539ea931274d407e1249b4bb575424a0f4`, applies `toolchain/luajit_xsdk.patch` and builds
`third_party/luajit_xsdk/src/libluajit.a` (interpreter only, no JIT, no FFI).

The patch is needed because titles run in 32-bit mode with 64-bit registers: without it, integer
math gives wrong results on the console. The script ends with four checks that must pass (360
frame layout present, patch present, no `__emutls`, no `mcrxr`); it stops if any fails.

Changing the LuaJIT commit needs its own pull request that remakes the patch and passes
`tests/console/xsdk_numeros.lua` on the console.

## 2. The `.xex`

```sh
cmake -S runtime -B runtime/build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<xsdk>/cmake/xsdk.cmake -DXSDK_TOOLCHAIN=~/xsdk-gcc \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DGAME_TITLE_ID="$(luajit tools/read_game_config.lua <game folder> title_id)" \
  -DGAME_NAME="$(luajit tools/read_game_config.lua <game folder> name)"
cmake --build runtime/build
```

The same source builds one `.xex` per game: the Title ID and the name Aurora shows come from the
game's `game.lua` ([docs/GAME_CONFIG.md](docs/GAME_CONFIG.md)). Without both options the build
uses a development Title ID (`0xFFFF0360`) and warns; do not distribute that.

The output is `runtime/build/game.xex`; on the console it goes as `default.xex` in the game's
folder, next to its `main.lua` (layout in [runtime/README.md](runtime/README.md)). Add
`-DL360_PUBLICADO=ON` for a release build with a short log (errors, missing features, summaries
and hitches).

## 3. Checks

- The boot, on PC: `luajit -joff tests/pc/boot_pc.lua` runs `runtime/lua/boot.lua` against
  `tests/fixtures/minimal_game` with a fake `l360` table and must end with a line starting with `OK:`.
- LuaJIT numbers, on PC: `luajit -joff tests/console/xsdk_numeros.lua` must end with
  `== numeros: 0 de 36 mal ==`.
- LuaJIT numbers, on the console: copy `tests/console/xsdk_numeros.lua` to
  `<folder>\l360\xsdk_numeros.lua`; `main.c` runs it before the game and the log must
  end with the same line.
