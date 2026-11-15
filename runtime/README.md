# runtime/

The console runtime: C on top of [xsdk](https://github.com/xenosworks/xsdk) (pinned commit in
`XSDK_VERSION`), built as a `.xex`. It runs the game's Lua through LuaJIT (interpreter only) and
implements the `l360` table that the Lua layer in `lua/` turns into the LÖVE API.
Build instructions: [../BUILDING.md](../BUILDING.md).

## Status

Copied from Love360 (`nocturn444/love360-xbox360`, commit `e46bc8f`, folders `runtime_xsdk/` and
`runtime/love360_*.lua`) with only path changes, so it builds exactly like Love360 does. It is
**still tied to Balatro**; objective 2 makes it generic. Known Balatro-specific parts:

- `GAME_DIR` is fixed to `game:/balatro/` in `main.c` and `l360_sys.c`.
- Title ID `0x4C560360` and the name "Balatro (Love360)" are fixed in `CMakeLists.txt`.
  Decision: each game will get its own `.xex` with the Title ID and name from its config.
- The boot (`lua/love360_boot.lua`), input mapping and saves are written for Balatro.
- `l360_importar.c` copies saves from Love360's legacy `guardado\` folder.
- `newShader(name)` maps names to fixed programs with hand-written constant tables (objective 3).
- `print`, `printf`, `line`, `circle`, `ellipse` and `points` draw nothing; no SpriteBatch
  (objective 4).

Source comments are still in Spanish; they are translated to English as each file is reworked.

## Modules

- `main.c`: startup, LuaJIT, the log and the text screen, the frame loop and hitch measurement.
- `l360_gfx.c`: `l360.gfx` on xsdk's GPU API (textures, canvases, shaders, batching).
- `l360_sys.c`: controller, files, saves (on their own thread) and exit (Back held 3 s).
- `l360_audio.c`: `l360.audio`, the mixer and IMA ADPCM music on hardware thread 2.
- `l360_importar.c`: legacy save import (to be removed in objective 2).
- `lua/l360_gfx_stub.lua`: the same `l360.gfx` API without drawing (PC tests and GPU fallback).
- `third_party/stb/`: stb_image v2.30 and stb_truetype v1.26.

## Console folder (current, Love360 layout)

```
<folder>\default.xex            runtime/build/love360.xex, renamed
<folder>\balatro\               the game's .lua files and assets
<folder>\balatro\love360\       runtime/lua/*.lua
<folder>\shaders\               compiled shaders (.psu/.vsu)
<folder>\save\                  saves, created on first use
<folder>\default.log            the log
```

Objective 2 changes this so the game's `main.lua` and `conf.lua` sit next to the `.xex`.

## Rules carried over from Love360

- **No thread-local storage.** xsdk builds without TLS; `__thread` would go through emutls.
  `toolchain/build_luajit_xsdk.sh` checks LuaJIT for it.
- **No `mcrxr`.** The Xenon CPU does not have that instruction (LuaJIT is built with `-D PPE`).
- `main.c` must be the first object in the link, or `elf2xex` fails ("section .init overlaps
  the PE headers").
