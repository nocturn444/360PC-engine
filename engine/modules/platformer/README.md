# engine/modules/platformer

Genre module (objective 12): tile collisions with [bump.lua](../../../lib/bump) v3.1.7, one-way
platforms, a character controller, and the reach of its jump for level generation. Nothing in
`engine/` requires it; it knows nothing about a game or about a level file format (the LDtk
loader, `engine/level.lua`, hands over a grid as below: [docs/LEVELS.md](../../../docs/LEVELS.md)).

A game needs `engine/modules/platformer/` and `lib/bump/` in its folder.
Tests: `tests/engine/platformer_test.lua`.

```lua
local engine = require("engine")
local platformer = require("engine.modules.platformer")

local grid = platformer.grid.new({
  "#..........#",
  "#...===....#",       -- # solid, = one-way, anything else empty
  "#..........#",
  "############",
}, { tile_size = 16 })
local world = platformer.collision.newWorld(grid)          -- a bump world with the tiles in it
local body = platformer.controller.new(world, { x = 24, y = 0, w = 10, h = 14 })

function play:update(dt)                                    -- the fixed step
  body:step(engine.controls, dt)                            -- actions "left", "right", "jump", "down"
end
function play:draw(alpha)
  local x = body.px + (body.x - body.px) * alpha
  local y = body.py + (body.y - body.py) * alpha
  love.graphics.rectangle("fill", x, y, body.w, body.h)
end
```

| File | What it is |
|---|---|
| `init.lua` | `require("engine.modules.platformer")`: `{ grid, collision, params, controller }`. |
| `grid.lua` | The grid interface and a helper that builds a grid from rows. |
| `collision.lua` | The grid as merged rectangles in a bump world; the one-way filter. `collision.bump` is the library. |
| `params.lua` | The movement parameters and their defaults; `reach`, `jump_distance`. |
| `controller.lua` | The character controller. |

Units: pixels and seconds. `y` grows downwards; a body's `x, y` is its top left corner.

## The grid

The module asks a grid for four things only, so any level loader can provide one:

| | |
|---|---|
| `grid.width`, `grid.height` | Size in tiles. |
| `grid.tile_size` | Size of a square tile, in pixels. |
| `grid:kind(tx, ty)` | `"solid"`, `"one_way"` or `nil`. `tx` is 1..width, `ty` is 1..height; tile (1, 1) is the top left one. |

`platformer.grid.new(rows, opts)` builds one by hand (tests, handmade rooms). `rows` go from top
to bottom; each is a string or an array; short rows are padded with empty tiles. `opts`:
`tile_size` (16), `legend` (`{ [character or value] = kind }`). The default legend:
`"#"`, `1`, `"solid"` are solid; `"="`, `2`, `"one_way"` are one-way; anything else is empty.
It also has `grid:set(tx, ty, kind)` and `grid:toTile(x, y)`.

## Collisions

| | |
|---|---|
| `collision.newWorld(grid, opts)` | A new bump world with the grid's tiles. Returns the world and the list of rectangles. `opts`: `cell_size` (bump's, default 4 tiles), `x`, `y` (where the grid's top left corner is). |
| `collision.add(world, grid, ox, oy)` | Adds a grid to an existing bump world; returns the list. |
| `collision.remove(world, list)` | Takes those rectangles out. |
| `collision.rects(grid, ox, oy)` | The list without a world: `{ x, y, w, h, kind }` in pixels. |
| `collision.filter(item, other)` | The bump filter the controller moves with. |
| `collision.bump` | bump.lua itself (`bump.newWorld`, `world:queryRect`...). |

A horizontal run of tiles of one kind is one rectangle. Solid runs over the same columns in
consecutive rows are joined as well, so a wall or a filled block is one rectangle. One-way runs
are never joined vertically: the top of each is a surface.

Every rectangle has a `kind` field. The filter looks at nothing else, so a game can add its own
items with `kind = "solid"` or `kind = "one_way"` (a moving platform, a crate) and bodies treat
them like tiles. Items without a `kind` (other bodies, pickups) are ignored unless the body has
a `filter(body, other)` of its own, which returns a bump response name (`"cross"` to be told
without being stopped, `"slide"` to be blocked) or nil.

### One-way platforms

A `"one_way"` rectangle blocks a body only if the body starts the step with its bottom at or
above the platform's top. So a body passes through it from below and from the sides, and lands
on it from above. Pressing jump while holding down, standing on one-way platforms only, drops
through: the platforms are ignored for that step, the body falls, and no jump starts on the way
down (coyote time is cleared). Down + jump on solid ground is a normal jump.

## The controller

`controller.new(world, opts)` adds a body to the bump world and returns it. `opts`:

| | |
|---|---|
| `x`, `y`, `w`, `h` | The body's rectangle. |
| `params` | A table from `params.new` (default: the defaults). |
| `stats` | Instead of `params`: anything with `:get(name)` that answers every parameter name (see Modifiers). |
| `actions` | Action names for `engine.input`: `left`, `right`, `jump`, `down` (the defaults are those same words); optionally `move_x`, an axis action used instead of `left` and `right`. |
| `filter` | `function(body, other)` for items without a `kind`. |

`body:step(input, dt)` runs one fixed step: call it once per `update(dt)` of the state (after
`input:step()`, which `engine.run` already does). `input` is an `engine.input`, or anything
with `down`, `pressed` and `axis`; `nil` means nothing is held (a body that only falls).
`body:teleport(x, y)` moves it without colliding and stops it; `body:remove()` takes it out of
the world.

A step: read the actions; update the coyote and buffer timers; accelerate towards
`direction * max_speed` (or decelerate towards 0); start a jump or a drop; cut the jump; add
gravity (capped at `max_fall_speed`); `world:move` with the filter; read the collisions.

Fields to read: `x`, `y`, `px`, `py` (the position before the step, to interpolate with
`alpha`), `vx`, `vy` (positive is down), `facing` (1 / -1), `on_ground`, `ground` (the item
stood on), `on_one_way`, `wall` (-1 / 0 / 1: a wall on that side stopped it this step),
`ceiling`, `jumping`, and `jumped`, `landed`, `dropped` (true for the step it happened in: play
a sound, emit a modifier event). `collisions` and `collision_count` are bump's list for the
step.

### Parameters

`params.defaults`; `params.new(overrides)` returns a copy with the given values (unknown names
are an error).

| Name | Default | |
|---|---|---|
| `gravity` | 900 | px/s^2, downwards. |
| `max_fall_speed` | 360 | px/s. |
| `max_speed` | 90 | px/s, running. |
| `ground_accel` | 900 | px/s^2 towards `max_speed` while a direction is held, on the ground. |
| `ground_decel` | 1200 | px/s^2 towards 0 with no direction held, on the ground. |
| `air_accel` | 600 | The same, in the air. |
| `air_decel` | 300 | |
| `jump_velocity` | 310 | px/s upwards when the jump starts. |
| `jump_cut` | 0.4 | Variable jump height: with the button up while still rising, the upward speed is multiplied by this, once. 1 turns it off. |
| `coyote_time` | 0.1 | Seconds after walking off a ledge during which a jump still starts. |
| `jump_buffer` | 0.1 | Seconds a jump press is remembered before landing. A buffered press whose button is already up gives the cut (short) jump. |

With the defaults and 16-pixel tiles a full jump rises 3.18 tiles and travels 3.84 tiles.

### Modifiers

The controller reads every parameter, every step, through `body.stats:get(name)`. With `params`
that reads the plain table (which can change while the game runs). An `engine.modifiers` set
has the same `get`, and a params table is exactly the `base` table `attach` takes, so:

```lua
local mods = engine.modifiers.new()
mods:define({ id = "spring", stats = { { "jump_velocity", "mul_base", 0.25 } } })
mods:define({ id = "feather", stats = { { "gravity", "mul", 0.5 } }, duration = 5 })

local set = mods:attach(player, platformer.params.new({ max_speed = 100 }))
local body = platformer.controller.new(world, { x = 24, y = 0, w = 10, h = 14, stats = set })
set:add("spring")                    -- the next jump is 25% faster; nothing else to do
```

The controller does not know about modifiers; the set caches each stat until something changes.
A set that was not given a base for a parameter answers 0 for it: always attach with
`params.new(...)`.

## Reach (for level generation)

Pure functions of the parameters: no randomness, no clock. They step a jump exactly as the
controller does (same order, same fixed `dt`), so the numbers are what the character really
does, not the continuous formula.

`params.reach(p, opts)`; `opts`: `tile_size` (16), `dt` (1/60). `p` is a plain table. Returns:

| | |
|---|---|
| `jump_height`, `jump_height_tiles` | How far the feet rise in a full jump (pixels; tiles, not rounded). |
| `jump_distance`, `jump_distance_tiles` | How far a full jump at `max_speed` travels before landing at the height it left from. |
| `air_time` | Seconds that jump lasts. |
| `coyote_distance` | `max_speed * coyote_time`: extra run past a ledge before jumping. |
| `tile_size`, `dt` | What it was computed with. |

`params.jump_distance(p, rise, opts)` is the distance to a surface `rise` pixels above the
take-off surface (negative: below), then the time in the air; `nil` if the jump does not get
that high. `params.resolve(stats)` reads every parameter from a stat source into a plain table:
`params.reach(params.resolve(set))` is the reach of a character with its modifiers.

Distances are travel of the body's position. A body of width `w` can stand with only its edge on
a ledge, so the widest gap it crosses is `jump_distance + w` (plus `coyote_distance`).

## On the console

bump.lua is plain Lua 5.1: no FFI, no `goto`, nothing from `love`. The controller creates no
tables per step, but bump does: `world:move` builds the collision list and one table per
collision on every call, so a body standing on the floor costs a few small tables a step.
