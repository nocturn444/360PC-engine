# engine/modules/props

Modular room props: a registry of prop types (data plus optional hooks) and the live set of one
room. The placement and catalog schema is in [docs/PROPS.md](../../../docs/PROPS.md). Needs no
other module; the overlay grid it returns works with `engine/modules/platformer` and
`engine/modules/softbody` (any code that takes the grid interface).

```lua
local props = require("engine.modules.props")
local types = props.registry()
types:define("crate", { category = "breakable", collision = "solid", flags = { breakable = true },
  fields = { { key = "health", type = "integer", default = 1, min = 1 } },
  init = function(p) p.state.health = p.state.health or p.fields.health end,
  hit = function(p, n) p.state.health = p.state.health - n; return p.state.health <= 0 end })

-- entering a room
local set = props.set(types, room.props, { tile_size = 16, state = room_state.props })
local grid = set:grid(room.grid)        -- collide against this one
-- each frame
set:update(dt, ctx)
local vine = set:first(x, y, w, h, "climbable")
set:draw(love.graphics)
```

| | |
|---|---|
| `props.registry()` | A new registry. |
| `registry:define(name, def)` | Validates and adds a type (fields in docs/PROPS.md); errors name the type and field. |
| `registry:get(name)` | The type's def, or nil. |
| `registry:check(placement)` | nil, or why the placement is wrong. |
| `registry:catalog()` | The editors' catalog as plain data. |
| `props.set(registry, placements, opts)` | The room's live props. `opts`: `tile_size` (16), `x`, `y` (offset of tile 1, 1), `state` (the room's persistent table, one sub-table per placement), `ctx` (for `init`). Raises on a bad placement. |
| `set:grid(base)` | A grid with the props' collision on top of `base`. Call once per room. |
| `set:update(dt, ctx)`, `set:draw(g)` | Run the hooks of live props. |
| `set:hit(p, amount, ctx)` | Calls the `hit` hook; true when it removed the prop. |
| `set:remove(p)` | Removes it for good (`p.state.removed`), and its collision at once. |
| `set:first(x, y, w, h, flag, after)` | The first live prop after index `after` overlapping the box with the flag (nil: any), and its index. |
| `set:tile_flag(tx, ty, flag)` | The first live prop covering the tile with the flag. |
| `set:count()`, `set:at(i)` | The instances, in placement order. |

An instance: `type`, `def`, `index`, `tx`, `ty`, `tw`, `th` (tiles), `x`, `y`, `w`, `h`
(pixels), `fields` (defaults merged with the placement's), `flags`, `state` (persistent),
`removed`. Update, draw, queries and the grid's `kind` allocate nothing.
