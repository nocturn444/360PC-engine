# engine/modules/softbody

A soft body: points on a ring, joined by springs and kept inflated by a pressure term, that
falls, rolls, squashes and bounces against a tile grid. Made for a slime-like hero whose pixels
are rasterized every frame (`engine.pixelgrid`), but generic: a blob, a ball, jelly, a bag.

A genre module: nothing in `engine/` requires it, it needs no other module and knows nothing
about a game. It reads a grid through the same four fields as `engine/modules/platformer`
(`width`, `height`, `tile_size`, `kind(tx, ty)`), so a `platformer.grid` or a level from
`engine.level` works as is. Example: [examples/slime](../../../examples/slime/README.md).

```lua
local softbody = require("engine.modules.softbody")
local slime = softbody.new({ x = 60, y = 40, radius = 9, points = 18 })

function play:update(dt)                       -- once per fixed step
  slime:push(engine.controls:axis("move_x") * 600, 0)
  if engine.controls:pressed("jump") and slime:on_ground() then slime:impulse(0, -260) end
  slime:step(dt, grid)                          -- grid optional; gx, gy: where tile (1, 1) starts
end

function play:draw(alpha)
  local cx, cy = slime:center()
  local ox, oy = math.floor(cx) - 20, math.floor(cy) - 20
  pixels:clear()
  pixels:polygon(slime:outline(points, ox, oy, 1, alpha), 1)   -- pixels: a 40 x 40 pixelgrid
  pixels:outline(2)
  pixels:draw(ox, oy)
end
```

## Options (`softbody.new(opts)`)

`x`, `y` place the centre. Every other key has a default in `softbody.defaults`:

| Key | Default | What it does |
|---|---|---|
| `radius` | 8 | Rest radius of the ring, in pixels. |
| `width`, `height` | 0 | Rest width and height for a long (or tall) body, such as a slug; 0 means `2 * radius`. The points lie on an ellipse and each spring keeps its own length. |
| `shape` | 0 | 0..1: how hard the body pulls back to its rest shape around its centre, without turning. 0: springs and pressure only (it can roll and tumble); 0.1 to 0.3 keeps a long body lying down. |
| `points` | 16 | Points on the ring, 6 or more. More points, a rounder and softer outline. |
| `stiffness` | 0.9 | 0..1: how hard the springs between neighbours keep their length. |
| `pressure` | 0.8 | 0..1: how hard the body keeps its area. Low values sag and wobble. |
| `inflate` | 1 | Target area as a fraction of the rest area. The springs follow (square root), so the body shrinks or swells evenly. Change it at any time: 0.7 while crouching, more than 1 to puff up. |
| `damping` | 0.998 | Velocity kept per step. |
| `gravity` | 600 | Pixels / s^2, down. |
| `friction` | 0.35 | 0..1: velocity along a surface lost per step while touching it. |
| `iterations` | 6 | Relaxation passes per step (springs, pressure, collisions). |
| `max_speed` | 600 | Pixels / s per point. Keep `max_speed / rate` under half a tile so nothing crosses a tile in one step. |

Every option is a field of the body and can change between steps (`slime.gravity = 0`).

## Methods

| Method | What it does |
|---|---|
| `body:step(dt, grid, gx, gy)` | One fixed step. Without a grid the body only falls. |
| `body:push(ax, ay)` | An acceleration for the next step only, in pixels / s^2 (call it every step to keep pushing). |
| `body:impulse(vx, vy)` | A change of velocity for every point at the next step, in pixels / s (a jump). |
| `body:set_velocity(vx, vy)` | Sets the mean velocity, keeping the wobble; nil keeps that axis. |
| `softbody.box(body)` | A rectangle that follows the body for modules that think in boxes: `x, y, w, h, facing`. `box:sync()` after each step; `box:knock(hit)` turns a combat hit's knockback into the body's velocity (call it from the fighter's `on_hurt`). `examples/rooms` makes the slime a combat fighter with it. |
| `body:move_to(x, y)` | Moves the centre there, keeping the velocity (a door, a respawn). |
| `body:on_ground()`, `:on_wall()`, `:on_ceiling()` | Whether a point touched that kind of surface in the last step. `floor_count`, `wall_count`, `ceiling_count` give how many. |
| `body:center()` | The mean of the points. |
| `body:velocity()` | Mean velocity over the last step, pixels / s. |
| `body:bounds()` | `x0, y0, x1, y1` around the points. |
| `body:area()` | The area inside the ring; `body.rest_area` is the area at rest. |
| `body:outline(out, ox, oy, scale, alpha)` | The points as `{ x1, y1, x2, y2, ... }`, as `(point - (ox, oy)) / scale`, between the last two steps by `alpha`. Writes into `out` (made when nil) and returns it: pass the same table every frame. |

The points themselves are `body.x[i]`, `body.y[i]` (1..`body.n`), clockwise on screen, and
`body.contact[i]` is `false`, `"floor"`, `"wall"` or `"ceiling"` after a step: a game can, for
example, leave a trail where points touch the floor.

## How it collides

Each point is pushed out of a solid tile through the face it came in by (the one its position at
the start of the step was outside of), or else through the nearest face that is open. A face is
open when the tile past it is not solid and is inside the grid, so the edge of the grid works as
a wall. A one-way tile only holds points that were above its top at the start of the step. After
the relaxation passes, a point touching a floor or ceiling loses its vertical velocity and
`friction` of its horizontal one (walls: the other way round).

Points are points: the body is as thick as its ring, and a gap narrower than the space between
two points can let part of it through, which a slime should do anyway.

## Console

Plain arithmetic: no randomness, no clock, no `love`, no FFI, no `pairs`. The same inputs give
the same points on PC and on the console, and a step allocates nothing. Cost: `iterations * points`
spring and pressure updates, plus a few grid lookups per point per pass. With the defaults a step
takes about 0.03 ms on a desktop PC under the LuaJIT interpreter (`luajit -joff`); the console's
CPU is several times slower, which is still far below a frame. Not measured on the console yet.
