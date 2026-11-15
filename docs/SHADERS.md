# Shaders

A game writes its shaders once, in LÖVE's GLSL. On PC, LÖVE compiles them as always. The console
runs no GLSL: each shader is declared in `game.lua`, translated to HLSL and compiled with xost
(xsdk's shader compiler) **on the developer's PC when the game is built**, and shipped
precompiled. Nothing is compiled on the console or by an installer, and no C changes per game.

## 1. Write the shader (PC)

One file per shader, in LÖVE 11 syntax (`tests/fixtures/minimal_game/shaders/tint.glsl`):

```glsl
extern vec4 tint;
extern number amount;

vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
{
    vec4 pixel = Texel(tex, texture_coords) * color;
    return vec4(mix(pixel.rgb, pixel.rgb * tint.rgb, amount), pixel.a);
}
```

```lua
local tint = love.graphics.newShader("shaders/tint.glsl")
tint:send("tint", { 0.4, 0.7, 1.0, 1.0 })
love.graphics.setShader(tint)
```

A file can have `effect`, `position` (`vec4 position(mat4 transform_projection, vec4
vertex_position)`) or both; with both, put each in `#ifdef PIXEL` / `#ifdef VERTEX`, as LÖVE asks.
The stages can also be two files.

## 2. Declare it in game.lua

```lua
shaders = {
  tint = "shaders/tint.glsl",                                  -- same as { glsl = "shaders/tint.glsl" }
  glow = { pixel = "fx/glow.frag", vertex = "fx/glow.vert" },  -- one file per stage (either can be left out)
},
```

The key is the shader's name on the console (1 to 24 letters, digits or `_`, starting with a
letter; `l360_` is the engine's). The game never uses the name: it calls
`love.graphics.newShader` as on PC, with the path or with the file's text
(`newShader(love.filesystem.read("shaders/tint.glsl"))`), and with two arguments for a
`pixel`/`vertex` pair. On the console the boot finds the declared shader built from those files.
A shader that is not declared, or not built, is logged once as `[missing] shader ...` and draws
with the default shader. Shader code written inside a `.lua` string cannot be declared: move it
to a file.

## 3. Build for the 360

Once: build the compiler, following
[tools/shaders/xost_windows/README.md](../tools/shaders/xost_windows/README.md). It gives a folder
with `xsc.dll`, `glslang.exe` and `_xsc_native.py` (or `libxsc.so` and `glslang` for Linux).

Every time a shader changes, on Windows (64-bit Python 3.9 or later, and LuaJIT on the PATH to
read `game.lua`):

```bat
python tools\shaders\build_shaders.py mygame --tools C:\xost --out build\mygame\shaders
```

Copy the contents of `--out` into the game's `shaders\` folder on the console (the packaging
objective will do it). It holds, for each declared shader, `<name>.psu` and/or `<name>.vsu` and
`<name>.meta.lua`, plus the engine's own `l360_default.psu/.vsu` and `l360_love.psu/.vsu`
(`runtime/shaders/*.hlsl`), which every game needs. Nothing is written unless every shader
compiled. The `.glsl` files only need to be on the console if the game reads them itself.

- `--lua <exe>` names the LuaJIT to use. Without Lua, list the shaders by hand:
  `--shader tint=shaders/tint.glsl --base mygame` (`name=pixel,vertex` for two files).
- `--hlsl-only` (no `--tools`) writes the translated `.hlsl` and the `.meta.lua` instead, on any
  OS: use it to see what the translator makes of a shader, or why it rejects it.

### The metadata

`shaders/<name>.meta.lua` is a data-only Lua file. The runtime reads it at `newShader`; nothing
else describes the shader to the console.

```lua
return {
  version = 1,
  name = "tint",
  ps = "tint.psu",         -- or l360_love.psu if the shader has no effect()
  vs = "l360_love.vsu",    -- or <name>.vsu if the shader has position()
  ps_regs = 2,             -- registers to upload from c8 (pixel) and from c5 (vertex)
  vs_regs = 0,
  uniforms = {
    amount = { type = "float", comps = 1, rows = 1, count = 1, ps = 9 },
    tint = { type = "vec4", comps = 4, rows = 1, count = 1, ps = 8 },
  },
}
```

Per uniform: `comps` floats per register, `rows` registers per element (N for `matN`), `count`
elements (arrays), `ps` / `vs` the first float constant register in each stage that uses it, and
`sampler` the texture slot of an `Image`. A uniform that is declared but not used has no register
and `send` ignores it. Registers: pixel `c6` = `love_ScreenSize`, `c7` = 0, uniforms from `c8`,
`s0` = the texture being drawn, `s1`-`s3` = `Image` uniforms; vertex `c0`-`c3` = projection,
`c4` = `love_ScreenSize`, uniforms from `c5`. xost's literals travel in each file's `L3X1` header.

## `send` on the console

`shader:send(name, value, ...)`, one value per array element: a number or boolean for
`float`/`int`/`bool`; a table of N numbers for `vecN`; for `matN` a table of N rows or of N*N
numbers, row-major (pass `"column"` first for column-major, as in LÖVE); an Image or Canvas for
`Image`. `sendColor` is `send`. A name that is not in the metadata is logged once as
`[missing] shader <name>: uniform <uniform>`; `hasUniform` answers from the metadata.

## Limits

- Uniform types: `float`/`number`, `int`, `bool`, `vec2`-`vec4`, `mat2`-`mat4`, `Image`, and
  arrays of the scalar and vector ones (indexed only). At most 32 pixel and 16 vertex registers
  (a `matN` takes N, an array one per element) and 3 `Image` uniforms, pixel stage only. `int`
  uniforms are floats on the console.
- Not supported (the build stops with the reason): `VaryingTexCoord`, `VaryingColor`,
  `VertexPosition`/`VertexTexCoord`/`VertexColor`, `love_PixelCoord`, `love_Canvases`, `effects`
  (multiple canvases), array/cube/volume images, `#if` on anything but `defined(...)`.
- Matrices: only `matrix * operand` is translated (`vec * mat`, `*=` and products of three
  matrices are not). A uniform's name cannot be reused for a local variable.
- GLSL functions translated: `Texel`/`texture2D`, `mix`, `fract`, `mod`, `inversesqrt`,
  `atan(y, x)`, `dFdx`/`dFdy`, `vecN(x)`. Others must have the same name in HLSL.
- xost: no bitwise operations, loops of at most 255 passes, 64 registers per shader.
  The translator already reduces `sin`/`cos` arguments, guards `atan`, replaces `clamp` with
  non-constant limits and flattens early `return`s (see the rules in
  `tools/shaders/glsl2hlsl.py`); a shader xost still rejects fails the build with its message.
- `screen_coords` is interpolated from the vertices' screen positions (in pixels), not read
  from the rasterizer.
- A shader is translated, not emulated: check its look on the console. The translator and the
  runtime's uniform path are tested on PC (`tests/shaders/`, `tests/pc/boot_pc.lua`); the
  generated shaders have not been run on hardware yet.
