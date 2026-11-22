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

## Room templates (what the level loader produces)

Levels are made in LDtk (objective 11): `tools/ldtk_convert.py` converts the project and
`engine.level.load` returns its levels as room templates, grid included
([docs/LEVELS.md](../../../docs/LEVELS.md)). This module only reads plain tables, so templates
written by hand work too:

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
   - one open exit is picked, with a weight from `branching` (default 0.5): an exit whose
     target cell would touch other rooms (filling a gap) gets less weight than one that grows
     outward, so the map spreads into branches instead of a compact block. 0 is the plain
     uniform pick, 1 never fills a gap while another open exit is free;
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

## Special rooms, room types and floors (The Binding of Isaac style)

A run can be made of **floors**: each one a fresh map, bigger and fuller the deeper the player
goes, with **special rooms** (a treasure room, a shop, a miniboss...) hung as dead ends. Room
types are modular data: a new type is one `define` plus templates of that type, and the
generator never names a type.

```lua
local types = procgen.roomtypes.defaults()          -- treasure, shop, miniboss (below)
types:define("secret", { count = { 0, 1 }, min_floor = 3, distance = "far" })   -- a new type

local plan = procgen.floors.new({
  count = 10,                                       -- floors in a run
  templates = lvl.rooms,                            -- templates of every type, special ones too
  types = types,
  rooms = { first = 7, last = 20 },                 -- floor 1 to floor 10, straight in between, +0..1
  abilities = { "key" },                            -- locks per floor (or a function of the floor)
})
local map = plan:generate(n, run.streams:get("floor" .. n))   -- floor n; map.floor, map.progress
```

**Room types** (`roomtypes.lua`). `types:define(name, def)` takes these fields, all optional:

| Field | Meaning |
|---|---|
| `count` | Rooms per floor: a number (1), `{ min, max }` (a draw), or `function(floor, total, rng, run)`. |
| `chance` | 0..1, or `function(floor, total, run)`: whether a floor gets the type at all. |
| `max` | A whole number >= 0: the most rooms of this type on a floor (applied after `count`). |
| `replaces` | A type name: on a floor where this type has a room, the replaced type gets none. A replacer may be defined before its target, but the target must be defined by the time `specials` runs; two types may not replace each other. |
| `min_floor`, `max_floor` | The floors it appears on. A negative `max_floor` counts from the end: -1 is the last floor, -2 the one before it. |
| `distance` | `"any"`, `"far"` (behind the deepest open exits) or `"near"` (close to the start). |
| `min_depth` | The fewest doors between the start and the room. |

Anything else in `def` belongs to the game, such as prices or minimap colours. `types:specials(floor, total, rng, run)`
returns the generator's `specials` list. The optional last argument `run` is the game's own
table (its counters for the run): `chance` and `count` functions receive it, so a chance can
depend on what happened earlier in the run, and calls without it work as before. The order of
the definitions is part of a generated map. Types with `replaces` are evaluated first, then the
rest (each group in definition order), which is also the rng draw order; the output list stays in
definition order. Replacements are applied once, directly to the target type (there is no
separate chain rule).

`roomtypes.defaults()` is a starting set:

| Type | Rule |
|---|---|
| `treasure` | One per floor, at least 2 doors from the start. |
| `shop` | One per floor except the last, at least 2 doors from the start. |
| `miniboss` | From floor 2, with a chance from 25% on floor 2 rising to 85%, far from the start, at least 3 doors away. |

**Special rooms in the generator** (`specials` and `boss_distance` options of `generate`):

- Special rooms are placed after the ordinary rooms, items and locks, and before the boss.
- Each one is a dead end: nothing hangs off it and loops never join it. Give their templates a
  single exit.
- Templates of a special type are never used as ordinary rooms. This holds even on a floor
  where the type has no room, because its count is then 0.
- They count in `rooms`.
- `distance` picks from the open exits by how many doors they are from the start, and falls
  back to any exit when nothing fits that band.
- After loops are added, a map whose special room ended up closer than its `min_depth` is
  thrown away and tried again.
- With `boss_distance = "far"`, the default of `floors`, the boss goes behind one of the
  deepest exits. A map where loops bring it more than one door closer than the deepest ordinary
  room is tried again.
- `map.rooms[i].depth` is the fewest doors from the start. Special rooms have `special = true`.

**Floors** (`floors.lua`). `floors.new(def)` takes these fields:

| Field | Meaning |
|---|---|
| `count` | Floors in a run (10). |
| `templates` | A list, or `function(n, plan)`. A template with `floors = { min, max }` is only used on those floors. |
| `types` | A `roomtypes` set. |
| `rooms` | `{ first, last, jitter }` or `function(n, plan, rng)`. The count never drops below what the floor's special rooms need. |
| `abilities` | An array, or `function(n, plan)`. |
| `loops` | `true` / `false`, or `function(n, plan)`. |
| `branching` | 0 to 1, or `function(n, plan)`: the generator's branching (default 0.5); a biome's `branching` wins. |
| `boss_distance` | `"far"` (the default) or `"any"`. |
| `attempts` | The generator's attempts. |
| `options` | `function(opts, n, plan, rng)`: the game's last word on floor n's options. |

`plan:options(n, rng)` gives the generate options. `plan:generate(n, rng)` gives the map, with
`map.floor`, `map.floors` and `map.progress` (0 on the first floor, 1 on the last) for the
game's difficulty. Both take the floor's `biome` and then the game's `run` table when given
(`plan:generate(n, rng, biome, run)`); the run goes to the room types' `chance` and `count`
functions. `plan:generator(n, rng)` does the same spread over frames.

Use one stream per floor (`"floor1"`, `"floor2"`...), so a floor depends only on the seed and its
number. `seeds.hash({ plan = plan, floor = n }, seed)` hashes one floor for the seed tools.

**Biomes** (`biomes.lua`). The run goes through biomes, each lasting 1 to 3 floors (any span the
game gives). Some are fixed: the first one, the last one, or one that always starts on a given
floor. The others are variable: chosen at random by weight, only once unlocked for good, or only
when the run so far allows it (what the player did). The next biome is chosen when its first
floor is entered, so it can depend on the run.

```lua
local set = procgen.biomes.new({
  { id = "cellar", span = 2, fixed = "first", difficulty = 1, music = "music/cellar" },
  { id = "caves", span = { 1, 3 }, weight = 3, difficulty = 2 },
  { id = "garden", span = 2, unlock = "found_seed" },                    -- after a permanent unlock
  { id = "ruins", span = 1, when = function(run) return run.kills >= 12 end },   -- what was done
  { id = "forge", span = { 1, 2 }, min_floor = 5 },
  { id = "core", span = 1, fixed = "last", difficulty = 5 },
}, { floors = 10, unlocked = profile.unlocks })
local path = set:path()                                          -- one per run
local biome = path:enter(n, run_state, run.streams:get("biomes"))   -- floor n's biome
local map = plan:generate(n, run.streams:get("floor" .. n), biome)  -- map.biome, map.difficulty
```

| Field | Meaning |
|---|---|
| `id` | A unique string. |
| `span` | Floors it lasts: a number (1) or `{ min, max }`. |
| `fixed` | `"first"`, `"last"`, or a floor number where it always starts. |
| `weight` | For the random choice among the variable biomes (1). 0 never comes out. |
| `unlock` | A tag: only once unlocked (`opts.unlocked`, `set:unlock(tag)`). |
| `when` | `function(run, path) -> boolean`: only when the run allows it. `run` is whatever the game passes to `enter`. |
| `after` | An array of biome ids: only right after one of them (branching paths). |
| `min_floor`, `max_floor` | The floors where it may start. |
| `once` | `false` lets a variable biome come back in the same run (by default it comes once). |

- Floors are entered in order. Entering a floor of the current biome again gives the same biome.
- A variable biome and its span are only picked when the floors left before the next fixed biome
  can still be filled. When nothing fits, biomes already used may come back.
- `path:enter(n, run, rng, forced)`: `forced` is a biome id the player chose (from
  `path:candidates(n, run)`, for a menu of doors or portals), used if it is a candidate.
- `path.current` is `{ biome, first, last }`. `path:state()` and `path:set_state(steps)` save and
  load the path with `engine.save`.

What a biome changes in its floors is read by `floors` from the biome table, all optional:
`templates` (its own), `types` (its own room types), `rooms_add` / `rooms_scale` (the room
count), `abilities`, `loops`, `difficulty` (copied to `map.difficulty`), and
`options(opts, n, plan, rng, biome)`. A template with `biomes = { ids }` is only used in those
biomes; one without it is used in all of them. Anything else in the biome (enemies, items,
music, colours) is the game's, reached through `map.biome_def`. Items of a biome are entries
with `biomes` in `engine/modules/items`, and its music is a name for `engine.audio:music`.

## Bulk seed checks and the PC vs 360 test

`procgen.seeds` (`seeds.lua`) turns one seed into one layout hash, the same way everywhere:
`seeds.hash(spec, seed)` returns `hash, attempts` (or `nil, reason`), where `spec` is a table
of the game's: `templates` (or a function returning them), `abilities`, `rooms`, and
optionally `check`, `types`, `loops`, `branching`, `attempts` and `stream` (the `engine.rng` stream the
game generates levels with, default `"level"`: the map is the one
`rng.streams(seed):get("level")` gives; `stream = false` passes the seed straight to
`generate`). `seeds.format` / `seeds.parse` write and read a hash list, and
`seeds.check(list, spec, log)` generates a list's seeds again and logs the ones that differ.

- `tools/seed_validator.lua` runs it over thousands of seeds on PC: failures, attempts
  statistics, hashes, and optionally a hash list file.
- `tests/console/level_hash_check.lua` reads that file on the console and logs mismatches.

The procedure is in [docs/NEW_GAME.md](../../../docs/NEW_GAME.md).

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
