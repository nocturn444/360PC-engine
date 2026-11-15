# runtime/

The console runtime: C on top of [xsdk](https://github.com/xenosworks/xsdk) (pinned commit in
`XSDK_VERSION`), built as a `.xex`. It runs the game's Lua through LuaJIT (interpreter only) and
implements the `l360` table that the Lua layer in `lua/` turns into the LÖVE API.
Build instructions: [../BUILDING.md](../BUILDING.md).

## Status

Started as a copy of Love360 (`nocturn444/love360-xbox360`, commit `e46bc8f`). Since objective 2
it is generic: the `.xex` runs the LÖVE game in its own folder (`game.lua`, `conf.lua`,
`main.lua`), and the Title ID and name are given per game at build time
(`-DGAME_TITLE_ID`, `-DGAME_NAME`; see [../BUILDING.md](../BUILDING.md) and
[../docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)). Still to do:

- `newShader(name)` maps names to fixed programs with hand-written constant tables, made for
  Balatro's shaders (objective 3).
- `print`, `printf`, `line`, `circle`, `ellipse` and `points` draw nothing; no SpriteBatch
  (objective 4). There is no built-in font: `newFont(size)` needs `default_font` in `game.lua`.
- No keyboard/pad action mapping yet (objective 4); the pad reaches the game as a LÖVE gamepad.
- `love.thread` threads run as coroutines on the main thread, one turn per frame.
- `love.filesystem.getDirectoryItems` does not list saves written in earlier runs.

Source comments are still partly in Spanish; they are translated to English as each file is reworked.

## Modules

- `main.c`: startup, LuaJIT, the log and the text screen, the frame loop and hitch measurement.
- `l360_gfx.c`: `l360.gfx` on xsdk's GPU API (textures, canvases, shaders, batching).
- `l360_sys.c`: controller, files, saves (on their own thread) and exit (Back held 3 s).
- `l360_audio.c`: `l360.audio`, the mixer and IMA ADPCM music on hardware thread 2.
- `lua/boot.lua`: the LÖVE API in Lua and the boot (game.lua, conf.lua, main.lua, frame loop).
- `lua/config.lua`: the `game.lua` loader; `lua/input.lua`: pad to `love.joystick`;
  `lua/save.lua`: saves with two slots per file.
- `lua/l360_gfx_stub.lua`: the same `l360.gfx` API without drawing (PC tests and GPU fallback).
- `third_party/stb/`: stb_image v2.30 and stb_truetype v1.26.

## Console folder

```
<folder>\default.xex            runtime/build/game.xex, renamed
<folder>\game.lua               the game's config (docs/GAME_CONFIG.md)
<folder>\conf.lua, main.lua     the game, with its other .lua files and assets
<folder>\l360\                  runtime/lua/*.lua (reserved name)
<folder>\shaders\               compiled shaders (.psu/.vsu) (reserved name)
<folder>\save\                  saves (save_dir in game.lua), created on first use
<folder>\default.log            the log
```

## Rules carried over from Love360

- **No thread-local storage.** xsdk builds without TLS; `__thread` would go through emutls.
  `toolchain/build_luajit_xsdk.sh` checks LuaJIT for it.
- **No `mcrxr`.** The Xenon CPU does not have that instruction (LuaJIT is built with `-D PPE`).
- `main.c` must be the first object in the link, or `elf2xex` fails ("section .init overlaps
  the PE headers").
