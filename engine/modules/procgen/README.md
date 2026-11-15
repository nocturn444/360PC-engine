# engine/modules/procgen

Genre module (objective 14): maps made of hand-made rooms joined procedurally, metroidvania
style. It does the following:

- places rooms on a grid of map cells by matching their exits;
- splits the map into zones locked by ability tags, with each key placed before its lock;
- checks that the map can be solved with a breadth-first search;
- gives minimap data and a stable layout hash;
- can spread the work over frames.

Nothing in `engine/` requires it, and it needs no other genre module. The only
platformer-flavoured part, `reach.lua`, reads a tile grid through the platformer grid interface
and takes the jump's reach as plain numbers.

A game needs `engine/modules/procgen/` in its folder. Its tests are
`tests/engine/procgen_test.lua`, and `tests/console/procgen_check.lua` is the check to run on
hardware.

```lua
local procgen = require("engine.modules.procgen")

local map, err = procgen.generate({
  templates = rooms,                       -- room templates (below)
  rng = run.streams:get("level"),          -- engine.rng: the same seed gives the same map
  rooms = 16,                              -- start and boss included
  abilities = { "dash", "double_jump" },   -- the order the player finds them in
})

-- Or a little per frame, behind a loading screen; the map is the same as with generate:
local gen = procgen.generator.new(opts)
function loading:update(dt)
  if gen:step(8) then start_run(gen.map or error(gen.error)) end
end
```

## Room templates (what the level loader must produce)

The level file format is objective 11, and Tiled vs LDtk is still open. This module only reads
plain tables, and whichever loader is chosen has to produce them:

| Field | Meaning |
|---|---|
| `id` | Unique string. |
| `w`, `h` | Size in map cells (one cell is one screen of the minimap). Default 1, 1. |
| `type` | `"start"`, `"boss"`, `"normal"` (the default) or any type of the game's, such as `"shop"`. |
| `weight` | A whole number >= 0, default 1: how often the template is picked. 0 turns it off. |
| `exits` | An array of `{ side, offset, requires, tx, ty }`. `side` is `"left"`, `"right"`, `"up"` or `"down"`. `offset` is which cell along that side, counted from 0 (rows for left/right, columns for up/down). `requires` is the ability tags needed to use the exit. `tx`, `ty` are the exit's tile in `grid`, used only by `reach`. |
| `item` | `true` (or a table of the game's): this room holds an ability item. Item rooms are only used for items. |
| `grid` | Optional platformer grid (`width`, `height`, `grid:kind(tx, ty)`), used only by `reach`. |

Anything else in the table belongs to the game and is left alone. `procgen.templates.new(list)`
checks the list and fills in the defaults in place. Keep the order of the list stable, because it
is part of the result.

## The map

`generate` returns `map`, or `nil, reason`.

- **`map.rooms[i]`**:
  - `index`, `id`, `template`, `x`, `y` (top left cell), `w`, `h`, `type`;
  - `zone` (0 is before any lock);
  - `grants`, the ability whose item is in the room, or nil;
  - `doors`, one entry per exit: a door index, or `false`;
  - `closed`, the exits with no door, which the game walls up.
- **`map.doors[i]`**:
  - `a`, `b` (rooms) and `ea`, `eb` (exits);
  - `requires`, the sorted tags needed (empty means a free door);
  - `lock`, the zone tag on a door into a zone;
  - `loop`, true for a door added between neighbours.
- **Other fields:** `map.start`, `map.boss` (nil without boss templates), `map.abilities`,
  `map.attempts`.
- **`procgen.hash(map)`**: a 32-bit number covering rooms, positions, zones, items and doors. It is
  the same on PC and console for the same seed. Use it for the PC vs 360 level test and for bulk
  seed checks.
- **`procgen.map.minimap(map)`**: `{ x, y, w, h, cells }`. Each cell is `false` or
  `{ room, type, zone, explored = false, item, left/right/up/down = { door, requires } }`. It does no
  drawing.
- **`procgen.map.room_at(map, x, y)`**: the room at a map cell.

## How a map is made

1. A `start` template goes at cell 0, 0.
2. The rooms that are not start, boss or item rooms are split evenly over `#abilities + 1` zones.
   Each zone grows from its own open exits:
   - one open exit is picked at random;
   - then a template whose exit fits and whose cells are free (by weight; with `opts.types`, a
     type by weight first).
3. The first room of zone k hangs off an earlier zone through a door that needs `abilities[k]`.
4. Before that door exists, the item of `abilities[k]` goes in zone k-1. It goes in an item
   template if there are any, otherwise in the newest room of that zone.
5. A `boss` template closes the last zone as a dead end.
6. Loops (`loops = true`, the default): facing exits of neighbouring rooms of the same zone are
   joined. Rooms of different zones are never joined, so no lock can be walked around.
7. `graph.validate` plays the map from the start: every room must be reached, every ability found,
   and no item may sit behind a door that needs it. Then `opts.check(map)`, the game's own rule,
   runs if there is one.
   - A map that fails is thrown away, and the next try goes on with the same rng, up to
     `attempts` (default 50).
   - Exits with their own `requires` (a high ledge that needs double jump) are covered by this
     check.

Every choice is an `engine.rng` draw over arrays in a fixed order, never over `pairs()`. One
operation is one room placed or tried. `gen:step(n)` pauses after n operations, so the budget
never changes the result.

## Reach inside a room

`procgen.reach.check(template, reach)` returns true, or false and the first pair of exits that
do not connect. `reach` is `{ jump_height_tiles, jump_distance_tiles }`, for example
`platformer.params.reach(params, { tile_size = 16 })`. `procgen.reach.from(template, reach, e)`
returns the set of exits reached from exit e.

The generator treats every room as connected inside. Run `reach.check` over the templates once,
with the reach of each set of abilities (at load time, or in a tool), and do one of these:

- drop the templates that fail;
- give their exits the `requires` they need.

The approximation is simple on purpose:

- **Body:** one tile, with no headroom or arc shape.
- **Standing tiles:** a tile can be stood on when it is empty and has a solid or one-way tile
  under it.
- **Jumps:** a jump goes up to `floor(height)` rows up and `floor(distance)` columns across. A fall
  goes down with `|dx| <= floor(distance) + rows fallen`. Tiles in between are ignored.
- **Exits:** a body coming in at an exit falls straight down. On the way out, an exit tile counts
  as something to aim at, even when it is in the air.

It can say yes to a room a real run cannot cross, so give it a slightly smaller reach (for
example 90%) to be safe.
