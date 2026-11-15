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
[../docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)). Since objective 3 shaders are generic too: each game
declares its own in `game.lua`, and they are compiled on PC and registered at run time from
their metadata ([../docs/SHADERS.md](../docs/SHADERS.md)). Still to do:

- There is no built-in font: `newFont(size)` needs `default_font` in `game.lua`; without it text
  is measured roughly and not drawn.
- `love.thread` threads run as coroutines on the main thread, one turn per frame.
- `love.filesystem.getDirectoryItems` does not list saves written in earlier runs.

Source comments are still partly in Spanish; they are translated to English as each file is reworked.

## Modules

- `main.c`: startup, LuaJIT, the log and the text screen, the frame loop and hitch measurement.
- `l360_gfx.c`: `l360.gfx` on xsdk's GPU API (textures, canvases, the shader registry, batching).
- `l360_particles.c`: the ParticleSystem simulation (adapted from LÖVE 11.5, zlib licence), with no
  Lua or GPU in it; `l360_gfx.c` has its Lua methods and draws it.
- `shaders/`: the engine's own HLSL shaders (default and LÖVE-default stages), compiled with
  every game's shaders by `tools/shaders/build_shaders.py`.
- `l360_sys.c`: controller, files, saves (on their own thread) and exit (Back held 3 s).
- `l360_audio.c`: `l360.audio`, the mixer and IMA ADPCM music on hardware thread 2.
- `lua/boot.lua`: the LÖVE API in Lua and the boot (game.lua, conf.lua, main.lua, frame loop).
- `lua/config.lua`: the `game.lua` loader; `lua/input.lua`: pad to `love.joystick`;
  `lua/save.lua`: saves with two slots per file.
- `lua/l360_gfx_stub.lua`: the same `l360.gfx` API without drawing (PC tests and GPU fallback).
- `third_party/stb/`: stb_image v2.30 and stb_truetype v1.26.

## Controller

The controller reaches the game exactly as an Xbox controller does in official LÖVE 11 on PC, so
the same code runs on both. Nothing is turned into keys: `love.keyboard.isDown` is always false
and `love.keypressed` never fires.

- `love.joystick.getJoysticks` / `getJoystickCount`: one Joystick per connected port (up to 4), in
  connection order. `getName` is `"Xbox 360 Controller"`, `isGamepad` is true.
- Gamepad API: `getGamepadAxis` (`leftx lefty rightx righty` from -1 to 1 with down positive,
  `triggerleft triggerright` from 0 to 1; no deadzone, that is the game's job as in LÖVE) and
  `isGamepadDown` (`a b x y back guide start leftstick rightstick leftshoulder rightshoulder dpup
  dpdown dpleft dpright`).
- Raw API in SDL's XInput order: axes 1-6 = leftx, lefty, rightx, righty, left trigger, right
  trigger (raw triggers rest at -1); buttons 1-11 = a, b, x, y, leftshoulder, rightshoulder, back,
  start, leftstick, rightstick, guide; the d-pad is hat 1 (`getHat`).
- `setVibration(left, right, duration)` (0 to 1, seconds), `getVibration`, `isVibrationSupported`.
- Callbacks, fired once per frame before `love.update`: `joystickadded` / `joystickremoved` (the
  controllers already connected at startup are added after `love.load`), `gamepadpressed` /
  `gamepadreleased`, `gamepadaxis`, `joystickpressed` / `joystickreleased`, `joystickaxis`,
  `joystickhat`.
- Back held 3 s still leaves the game (handled in C); a short press is a normal `back`. `guide`
  is reported only if XAM delivers the Guide button to the title.

## Implemented love.graphics functions

Drawing is done in `l360_gfx.c`; `lua/boot.lua` adds what needs no GPU. Everything is transformed
on the CPU and batched: consecutive draws that share texture, filter, shader and blend mode become one GPU
draw. `l360.gfxstats()` has the totals: `draws` (GPU draw calls), `submits` (draws, shapes and
texts that reached the vertex buffer), `verts`, `skipped` (asked and not drawn), `dropped`
(vertex buffer full: 120000 vertices, 20000 quads, per frame) and `particles` (live particles of the
ParticleSystems drawn, before those off screen are left out). They only go up: take the difference
between two frames.

| Functions | Limits |
|---|---|
| `draw(image or canvas, [quad], x, y, r, sx, sy, ox, oy, kx, ky)`, `newImage`, `newQuad`, `newCanvas`, `setCanvas` | PNG only. Canvases have the screen's size. No Mesh or Video. |
| `newSpriteBatch(image, maxsprites, usage)`; `add`, `set`, `clear`, `getCount`, `getBufferSize`, `setColor`, `getColor`, `setTexture`, `getTexture`, `flush`; `draw(batch, ...)` | Vertices are computed on `add`/`set`; a draw copies them once and is one GPU draw. The buffer grows when full. Sprites wholly off screen are left out, unless a game shader is active. `usage` is ignored. No `addLayer`, `attachAttribute` or `setDrawRange`. |
| `newParticleSystem(texture, buffersize)`; `emit`, `update`, `start`, `stop`, `pause`, `reset`, `isActive`, `isPaused`, `isStopped`, `getCount`, `clone`, `draw(system, ...)`; set and get `BufferSize`, `Texture`, `EmissionRate`, `EmitterLifetime`, `ParticleLifetime`, `Position` (and `moveTo`), `Speed`, `Direction`, `Spread`, `LinearAcceleration`, `RadialAcceleration`, `TangentialAcceleration`, `LinearDamping`, `Sizes`, `SizeVariation`, `Colors`, `Rotation`, `Spin`, `SpinVariation`, `RelativeRotation`, `Quads`, `Offset`, `EmissionArea`, `InsertMode` | LÖVE 11's simulation, with its arguments, defaults and units. The particles are a pool of `buffersize` allocated once (`setBufferSize` allocates a new, empty one): `emit`, `update` and `draw` allocate nothing. A draw is one GPU draw, with the current colour, transform, shader and blend mode; particles wholly off screen are left out, unless a game shader is active. At most 8 sizes, 8 colours and 64 quads; a Quad's viewport is read at `setQuads`. Random numbers come from a xorshift32 in each system, seeded in creation order: not `love.math`'s generator, so `love.math.setRandomSeed` does not reach it and the particles are not the same ones as on PC. No `setAreaSpread` (deprecated in LÖVE 11). |
| `setBlendMode(mode, alphamode)`, `getBlendMode` | `"alpha"` and `"add"`, with `"alphamultiply"` (default) or `"premultiplied"`, with LÖVE 11's factors. The other modes (`subtract`, `multiply`, `lighten`, `darken`, `screen`, `replace`, `none`) are drawn as `"alpha"` and logged once as `[missing]`; `getBlendMode` answers the mode in use. Changing the mode starts a new GPU draw. |
| `print(text, [font], x, y, r, sx, sy, ox, oy, kx, ky)`, `printf(text, [font], x, y, limit, align, r, sx, ...)`, `newFont`, `setFont`, `getFont`, `setNewFont`, `newText`; Font `getWidth`, `getHeight`, `getWrap`, `getAscent`, `getDescent`, `getBaseline`, `getLineHeight`, `setLineHeight` | TTF only, glyphs 32-255 (Latin-1) from one atlas rasterized at 64 px; other characters take room and draw nothing. No kerning, no tabs. Aligns `left`, `center`, `right`, `justify`; wraps at spaces and `\n`. Coloured text tables work. At most 4095 bytes, 256 lines and 32 colour runs per call. Text objects are one line. |
| `rectangle`, `polygon`, `line`, `circle`, `ellipse`, `points`, `setLineWidth`, `getLineWidth`, `setPointSize`, `getPointSize` | `"fill"` and `"line"`. Outlines and lines have miter joins (cut short on very sharp corners), no smoothing, no line styles. At most 510 points per line, 128 per polygon, 510 segments per circle. No rounded rectangles, no `arc`. Filled polygons must be convex. Shapes ignore the game's shader. |
| `setColor`, `getColor`, `setBackgroundColor`, `clear`, `push`, `pop`, `origin`, `translate`, `scale`, `rotate`, `shear`, `setDefaultFilter`, `getDimensions`, `getWidth`, `getHeight`, `getStats` | `clear` only sets the colour of the next frame. `push` takes no argument. |
| `newShader`, `setShader`, Shader `send`, `sendColor`, `hasUniform` | [../docs/SHADERS.md](../docs/SHADERS.md). |
| `setScissor`, `setStencilTest`, `setColorMask`, `setLineStyle`, `reset` | Accepted, do nothing (`reset` does not restore the blend mode). |

`love.timer`: `getTime` (high resolution), `getDelta`, `getFPS` and `getAverageDelta` (over the
last second, as in LÖVE), `step`, `sleep` (only yields inside a `love.thread`). The loop runs at
30 FPS and `dt` is capped at 0.1 s.

## Console folder

```
<folder>\default.xex            runtime/build/game.xex, renamed
<folder>\game.lua               the game's config (docs/GAME_CONFIG.md)
<folder>\conf.lua, main.lua     the game, with its other .lua files and assets
<folder>\l360\                  runtime/lua/*.lua (reserved name)
<folder>\shaders\               output of tools/shaders/build_shaders.py: the engine's and the
                                game's .psu/.vsu and <name>.meta.lua (reserved name)
<folder>\save\                  saves (save_dir in game.lua), created on first use
<folder>\default.log            the log
```

## Rules carried over from Love360

- **No thread-local storage.** xsdk builds without TLS; `__thread` would go through emutls.
  `toolchain/build_luajit_xsdk.sh` checks LuaJIT for it.
- **No `mcrxr`.** The Xenon CPU does not have that instruction (LuaJIT is built with `-D PPE`).
- `main.c` must be the first object in the link, or `elf2xex` fails ("section .init overlaps
  the PE headers").
