# engine/modules/rooms

Playing a map from `engine/modules/procgen` one room at a time: which room the player is in,
where a body arrives when it comes through a door, when it leaves by an exit and where that
door leads, which doors its abilities open, what has been explored (for the minimap and the
run's save), and a short transition to cover the change of room.

A genre module: nothing in `engine/` requires it. It reads procgen maps and knows nothing about
a game. Loading the room's tiles, entities and collisions (`engine.level`, `platformer`) and
drawing are the game's.

```lua
local rooms = require("engine.modules.rooms")
local nav = rooms.nav.new(map, { cell_w = 320, cell_h = 192, tile_size = 16 })
local fade = rooms.transition.new({ kind = "fade", time = 0.3 })

local x, y = nav:enter(map.start)               -- the start room: build its world, put the body at x, y
camera:setBounds(nav:bounds())

function play:update(dt)
  fade:update(dt)
  if fade:busy() then return end
  local exit, door, side = nav:leaving(body_cx, body_cy)        -- the body's centre, room pixels
  if door and nav:can_pass(door, run.abilities) then
    fade:start(function()
      local nx, ny = nav:go(door)
      build_room(nav.room); place_body(nx, ny); camera:setBounds(nav:bounds())
    end, side)
  end
end

function play:draw(alpha)
  -- the room, then a cover over the screen
  love.graphics.setColor(0, 0, 0, fade:cover(alpha)); love.graphics.rectangle("fill", 0, 0, 320, 180)
end
```

## Room pixels

A room's top left corner is 0, 0; it is `w * cell_w` by `h * cell_h` pixels (`w`, `h` in map
cells). An exit is its stretch of the room's edge: the left exit at offset 1 of a room two cells
high is `x = 0`, `cell_h <= y < 2 * cell_h`.

## rooms.nav

`rooms.nav.new(map, opts)`: `cell_w`, `cell_h` (pixels per map cell, required), `tile_size`
(for exits and spawns given in tiles), `inset` (how far inside the edge a body arrives when its
exit gives no tile; default 1.5 tiles, or 24), `on_enter(nav, index, exit)`.

| Call | What it does |
|---|---|
| `nav:enter(index, exit)` | Makes room `index` the current one (`nav.index`, `nav.room`), through its exit `exit` or none, marks it explored, counts the visit (`nav.visits[index]`). Returns where the body goes. |
| `nav:leaving(x, y)` | When the point is past an edge of the current room: the exit there (nil if that stretch has none), its door (false if the exit leads nowhere: the game walls it up) and the side. Nil while inside. |
| `nav:can_pass(door, have)` | True, or false and the first tag missing. `have`: an array of tags or a set. |
| `nav:through(door)` | The room on the other side and the exit it arrives by. |
| `nav:go(door)` | `through` then `enter`: returns x, y, the new index and the exit. |
| `nav:arrival(index, exit)` | Where a body arrives by that exit: the exit's `tx`, `ty` tile (centre) when the template has one, else the middle of its stretch of edge, `inset` inside. |
| `nav:spawn(index)` | Where a body starts without a door: the template's `spawn = { tx, ty }`, else the centre. |
| `nav:size(index)`, `nav:bounds()` | The room in pixels; `bounds` is `0, 0, w, h` of the current one, for `camera:setBounds`. |
| `nav:is_explored(index)` | Whether the room was entered. |
| `nav:minimap()` | `procgen.map.minimap(map)`, made once, with each cell's `explored` kept up to date. |
| `nav:state()`, `nav:set_state(s)` | `{ room, entered_by, explored }` for the run's save (engine.save), and back: `set_state` enters the saved room and returns the body's position; unknown rooms are ignored. |

## rooms.transition

Two halves: the first covers the screen, a callback swaps the room in the middle, the second
uncovers it. Only numbers; the game draws.

| Call | What it does |
|---|---|
| `rooms.transition.new({ kind, time })` | `"fade"` (default) or `"slide"`; `time` is the whole transition in seconds (default 0.3). |
| `t:start(on_swap, dir)` | Starts one (ignored while one runs: returns false). `dir`: where the player goes, for a slide. |
| `t:update(dt)` | In the fixed step; runs `on_swap` once at the middle. |
| `t:busy()` | While it runs (the game usually freezes the room). |
| `t:cover(alpha)` | 0..1: the alpha of a rectangle over the screen for a fade. |
| `t:offset(alpha, w, h)` | Whole pixels to shift the room by for a slide: the old room leaves, the new one comes in. |

## Console

No `love`, no randomness, no clock, no FFI, no `pairs`. `leaving` and `can_pass` allocate
nothing; `enter` allocates nothing either once the minimap and the exit lookups exist.
