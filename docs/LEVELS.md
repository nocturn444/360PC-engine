# Levels (LDtk)

Levels are made in [LDtk](https://ldtk.io/) (1.5 or newer). The engine never reads the `.ldtk`
project: `tools/ldtk_convert.py` converts it on the development PC, like the shaders, into one
level file that `engine/level.lua` loads on PC and on the console.

```
levels/world.ldtk  --tools/ldtk_convert.py-->  levels/world.lvl  --engine.level.load-->  rooms
```

The level file is data in the text format of `engine/save.lua` (`Save.serialize` /
`Save.parse`), so nothing on the console runs `load()` on it. The converter sorts the keys: the
same project always gives the same bytes. `tools/package.py` leaves `*.ldtk` and `*.ldtkl` out
of the console folder and ships the converted file.

## The LDtk project

One LDtk level is one **room**. With `engine/modules/procgen` a room is a room template; a game
without procedural levels uses the rooms directly.

| In LDtk | Name | Meaning |
|---|---|---|
| IntGrid layer | `Collision` | The collision tiles. Its grid size is the level file's `tile_size`. Value identifiers: `solid` (also `wall`, `walls`, `ground`, `block`) and `one_way` (also `oneway`, `one-way`, `platform`, `one_way_platform`), in any case. Values without an identifier: 1 is solid, 2 is one-way. Any other value is exported as empty, with a warning (use them for auto-layer rules). |
| Entity | `Exit` | A door of the room, on a border of the level. Fields, both optional: `side` (String or Enum: `left`, `right`, `up`, `down`; also `top`, `bottom`) and `requires` (Array\<String\>: the ability tags needed to use it). Without `side`, the side is the border the entity touches; an exit in a corner needs the field. Other fields are kept under `fields`. |
| Entity | `Item` | The place of the room's ability item (at most one). |
| Entity | anything else | Exported in the room's `entities` list with its fields: enemies, spawn points, triggers. |
| Tiles and AutoLayer layers | any | Drawn. An IntGrid layer with auto-layer rules (the collision layer included) is drawn too. |
| Level field | `type` | String or Enum, written in lower case: `start`, `boss`, or any type of the game's. Default `normal`. |
| Level field | `weight` | Int >= 0, default 1: how often procgen picks the room. |
| Level field | `tags` | Array\<String\>, for the game. |
| Level field | anything else | Kept under the room's `fields`. |

Layer, entity and field names are matched in any case (`Type` and `type` are the same field).
Other names can be given to the converter: `--collision`, `--exit`, `--item`.

**Map cells.** A room's size on the map is counted in cells of `--cell WxH` tiles; without the
option, the cell is the smallest level of the project. Every level has to be a whole number of
cells wide and high (set the project's default level size to one cell, and make large rooms 2,
3... cells). An exit's `offset` is the cell it is in along its side, from 0.

**Tilesets.** PNG files inside the game folder (the console loads PNG only). Their paths are
written relative to `--root`, the game folder (by default the folder of the `.ldtk` file), with
forward slashes. Only the tilesets some layer draws with are listed. Embedded atlases are not
supported.

**External levels.** A project saved with "Save levels to separate files" works: the converter
reads the `.ldtkl` files next to the project.

Not exported: layer and tile opacity, level backgrounds and the world layout (procgen places the
rooms). Layer pixel offsets are applied to tiles and entities.

## Converting

```sh
python base/tools/ldtk_convert.py levels/world.ldtk -o levels/world.lvl --root . --cell 20x12
```

Python 3, standard library only, Windows and Linux. Run it again whenever the project changes
(before `tools/package.py`). Errors name the level: a size that is not a whole number of cells,
an exit that is not on a border or sits in a corner without `side`, two exits on the same side
of one cell, two items, an IntGrid value the layer does not define, a tileset outside the game
folder. Warnings go to stderr; `-q` prints nothing but errors.

## Loading

```lua
local engine = require("engine")
local lvl = assert(engine.level.load("levels/world.lvl"))   -- nil, reason on a bad file
local images = engine.level.load_images(lvl)                 -- once: one Image per tileset

local room = lvl.by_id.Start
local batches = engine.level.batches(room, images)           -- when the room is entered
function play:draw()
  engine.level.draw(batches, 0, 0)                           -- every layer, bottom to top
end
```

| | |
|---|---|
| `level.load(path)` | Reads the file with `love.filesystem.read` and returns the level, or `nil, reason` (missing file, not a level file, another format version, broken data). |
| `level.from_text(text)` | The same from a string. |
| `level.load_images(lvl)` | `{ [i] = Image of lvl.tilesets[i] }` (plus the quad cache `batches` uses). |
| `level.batches(room, images)` | `{ { name, tileset, batch }... }`: one SpriteBatch per tile layer, from the bottom one up, in room pixels. Flipped tiles are added with a negative scale. |
| `level.draw(batches, x, y)` | Draws them in order. To put sprites between two layers, draw `batches[i].batch` yourself. |

The level: `rooms` (in the project's order), `by_id`, `tilesets` (`{ path, tile_size, w, h }`),
`tile_size`, `cell` (`{ w, h }` in tiles), `ldtk_version`.

A room:

| Field | Meaning |
|---|---|
| `id` | The LDtk level identifier. |
| `w`, `h` | Size in map cells. `tiles_w`, `tiles_h`: size in tiles. |
| `type`, `weight`, `tags`, `fields` | The level's custom fields (above). |
| `exits` | `{ side, offset, requires, tx, ty, fields }`, sorted by side (left, right, up, down) then offset. `tx`, `ty`: the tile at the centre of the entity, from 1. |
| `item` | `{ tx, ty, fields }`, or nil. |
| `entities` | `{ name, iid, x, y, w, h, tx, ty, fields }`: `x`, `y` is the top left corner in room pixels (the pivot is already applied), `tx`, `ty` the tile at its centre, `iid` the LDtk instance id (what an EntityRef field points at). |
| `layers` | `{ name, tileset, tiles }` from the bottom one up. `tiles` is a flat array, five numbers a tile: x, y in room pixels, x, y in the tileset image, flip bits (1 horizontal, 2 vertical). |
| `collision` | The flat array of the collision layer, row by row: 0 empty, 1 solid, 2 one-way. |
| `grid` | The collision as a grid object: `grid.width`, `grid.height`, `grid.tile_size`, `grid:kind(tx, ty)` returning `"solid"`, `"one_way"` or nil. It is the grid interface of `engine/modules/platformer`: `platformer.collision.newWorld(room.grid)` works as it is. |

Field values are what LDtk exports: numbers, booleans, strings, arrays, and tables for points
(`{ cx, cy }`), entity references and tiles. A null field is left out (nil).

## With procgen

The rooms are room templates as they are:

```lua
local procgen = require("engine.modules.procgen")
local lvl = assert(engine.level.load("levels/world.lvl"))

-- once, at load time or in a tool: can each room be crossed with this jump?
for _, room in ipairs(lvl.rooms) do
  assert(procgen.reach.check(room, { jump_height_tiles = 3, jump_distance_tiles = 4 }))
end

local map = assert(procgen.generate({
  templates = lvl.rooms, rng = run.streams:get("level"), rooms = 16, abilities = { "dash", "double_jump" },
}))
local room = map.rooms[map.start].template                   -- the loaded room: grid, layers, entities
```

For that the project needs at least one level with `type` = `start`, usually one with `boss`,
and, when there are abilities, levels with an `Item` entity. The order of the levels in the
project is part of a generated map: adding, removing or reordering levels changes what a seed
gives (run `tools/seed_validator.lua` again).
