# game.lua: the per-game config

Every game has a `game.lua` next to its `main.lua`. It is a data-only Lua file that returns one
table. It is read by the console runtime (at boot), by the game itself on PC if it wants to, and
by the build and packaging tools (through `luajit`).

```lua
return {
  name = "My Game",                 -- required
  identity = "my_game",
  title_id = "0x4D470001",
  save_dir = "save",
  aurora = { icon = "aurora/icon.png", cover = "aurora/cover.png" },
  shaders = { tint = "shaders/tint.glsl" },
}
```

| Field | Type | Default | Meaning |
|---|---|---|---|
| `name` | string | required | Name shown by Aurora and default window title. 1 to 64 printable ASCII characters, without `"`, `\` or `;`. |
| `identity` | string | from `name` (`"My Game"` gives `my_game`) | LÖVE-style identity (`love.filesystem.getIdentity`). 1 to 32 letters, digits, `_`, `-`. `t.identity` in `conf.lua` overrides it, as in LÖVE. |
| `title_id` | string | none | Xbox 360 Title ID: 8 hex digits, with or without `0x`. One per game, never changed after release. Required by the build and the packaging; ignored at runtime. |
| `save_dir` | string | `"save"` | Folder for saves, inside the game folder on the console. Flat name: 1 to 32 letters, digits, `_`, `-`; not `l360` or `shaders`. |
| `aurora` | table | `{}` | Aurora assets, as paths inside the game folder: `icon`, `cover`, `background`, `banner`. Placeholders until the packaging objective uses them. |
| `shaders` | table | `{}` | The game's shaders: console name to the GLSL it is built from. Each value is a path, `{ glsl = path }` (one file), or `{ pixel = path, vertex = path }` (one file per stage, either optional). Names: 1 to 24 letters, digits or `_`, starting with a letter, not `l360_`. Used by the shader build and by `love.graphics.newShader` on the console: [SHADERS.md](SHADERS.md). |
| `default_font` | string | none | TTF (path inside the game folder) that `love.graphics.newFont(size)` uses on the console, which has no built-in font. |

Rules:

- The file runs in an empty environment: no globals, no `require`. It can only build and return
  a table. Bytecode is rejected.
- Unknown fields are an error (they are usually typos).
- Paths are relative to the game folder, with `/` separators and no `..`.
- A game without `game.lua` still runs on the console, with the defaults and the name
  `Untitled game`; the build and the packaging require it.

## Reading it

The loader is `runtime/lua/config.lua` (plain Lua 5.1, no dependencies):

```lua
local Config = require("config")              -- or loadstring(...) of the file
local cfg, err = Config.load(source_text)     -- normalized table, or nil and the reason
```

`cfg` always has `name`, `identity`, `save_dir`, `aurora` and `shaders` (each shader normalized
to a table with `glsl`, or `pixel` and/or `vertex`); `title_id` (normalized to
`0x` and 8 upper-case digits) and `default_font` only if the game set them. On the console the
boot leaves it in `l360.game`.

From the shell or CMake:

```sh
luajit tools/read_game_config.lua mygame            # title_id=..., name=..., identity=..., save_dir=...
luajit tools/read_game_config.lua mygame title_id   # 0x4D470001
luajit tools/read_game_config.lua mygame shaders    # name<TAB>pixel file<TAB>vertex file, per shader
```

It exits with status 1 and the reason on stderr if `game.lua` is missing or invalid, or has no
`title_id` (`shaders` does not need one).
