# Props (platforms, vines, crates, spikes, turrets...)

A **prop** is something placed in a room that is not a collision tile and not an enemy: a
platform type, a vine, a breakable crate, spikes, a statue that shoots. Props are modular: a
game defines its prop **types** in one file with `engine/modules/props`
([README](../engine/modules/props/README.md)), the rooms list **placements** of those types, and
the level editors read a generated **catalog** of the types, so a new type needs no change in
the engine or the editors.

```
game types (rooms_props.lua) --tools/props_catalog.lua--> props_catalog.lvl --> level editors
room props (in .lvl or code templates) --props.set--> live props of the room (grid, hooks, queries)
```

## Placements (in a room)

A room's optional `props` list, in the `.lvl` file (`engine/level.lua` checks the shape) and in
code templates alike:

| Field | Meaning |
|---|---|
| `type` | The prop type id (a name the game defined). |
| `tx`, `ty` | The top left tile of the prop, from 1 (tile 1, 1 is the room's top left corner). |
| `w`, `h` | Size in tiles. Optional: the type's default size. Only the sides its `resize` allows may differ. |
| `fields` | Optional `{ key = value }`: only the values that differ from the type's defaults. |

```lua
props = {
  { type = "vine", tx = 4, ty = 2, h = 6 },
  { type = "spikes", tx = 8, ty = 11, w = 3, fields = { send_back = true } },
  { type = "statue", tx = 18, ty = 9, fields = { direction = "left", interval = 1.5 } },
}
```

The collision array of the `.lvl` file stays 0 empty, 1 solid, 2 one-way. A type with collision
`solid` or `one_way` is stamped onto the room grid when the room is entered, so editors store
only the prop, never extra collision values. The order of the list matters: a prop's persistent
state (a broken crate) is kept by its index.

## Types (in the game)

`registry:define(name, def)`. A name is letters, digits and `_`. Every field of `def` is
optional:

| Field | Meaning |
|---|---|
| `category` | Editor grouping (`platform`, `hazard`...). Default `prop`. |
| `size` | `{ w, h }` default size in tiles. Default 1 x 1. |
| `resize` | `none` (default), `x`, `y` or `xy`. |
| `min`, `max` | `{ w, h }` size limits for a resizable type. |
| `collision` | nil, `solid` or `one_way`. |
| `flags` | `{ name = true }`. The engine never reads them; the game decides what `climbable` or `hazard` means. |
| `fields` | Ordered `{ { key, type, default, options, min, max } }`. `type`: `number`, `integer`, `bool`, `string`, `enum` (with `options`, a list of strings). `default` is required; `min` and `max` only for numbers. |
| `editor` | `{ label, glyph, color }`: name shown, 1 or 2 characters drawn on the cell, `{ r, g, b }` from 0 to 1. Defaults: the name, its first letter, grey. |
| `init`, `update`, `hit`, `draw` | Hooks: `init(p, ctx)` on entering the room, `update(p, dt, ctx)`, `hit(p, amount, ctx)` returning true to remove the prop, `draw(p, g)`. |

## The catalog (for editors)

`luajit tools/props_catalog.lua <game folder> <types module> -o <file>` writes the types in the
text format of `engine/save.lua` (the same as `.lvl` files). `--check` compares instead of
writing (a test keeps the committed file up to date). For `examples/rooms`:

```sh
luajit tools/props_catalog.lua examples/rooms rooms_props -o examples/rooms/props_catalog.lvl
```

```lua
{ format = "360pc-props-catalog", version = 1, types = {
  { id = "vine", label = "Vine", glyph = "|", color = { 0.25, 0.65, 0.30 }, category = "climb",
    w = 1, h = 4, resizable = "y", min = nil, max = { w = 1, h = 24 }, collision = nil,
    flags = { "climbable" }, placement = "prop",
    fields = { { key = "speed", type = "number", default = 60, min = 10, max = 200 } } },
  ...
} }
```

`types` is in definition order, `flags` sorted, `fields` in definition order. `placement` is
always `prop` in version 1. An editor shows the types by `category`, places them as the
placements above, lets the user resize along `resizable` within `min` / `max`, and edits
`fields` with the given type and limits, writing only the values that differ from `default`.
