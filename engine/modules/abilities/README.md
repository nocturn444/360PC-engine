# engine/modules/abilities

Movement abilities as data: air jump, wall jump, dash and grappling hook, for any body through a
small adapter. A genre module: nothing in `engine/` requires it, it needs no other module and it
knows nothing about a game. A game grants the abilities its run has and hands the set one intent
table per fixed step.

```lua
local abilities = require("engine.modules.abilities")

local set = abilities.new(slime, { grid = grid })      -- or { solid = function(x, y) ... end }
set:grant({ kind = "air_jump", id = "double_jump" })
set:grant({ kind = "dash", id = "dash", trigger = "double_tap" })

local intent = { move_x = 0, move_y = 0, jump = false, jump_held = false, dash = false,
  hook = false, jump_speed = 260, facing = 1, consumed_jump = false }

function play:update(dt)                                -- the fixed step, before body:step
  intent.move_x = controls:axis("move_x")
  intent.jump = controls:pressed("jump")
  intent.jump_held = controls:down("jump")
  intent.hook = controls:pressed("hook")
  intent.facing = player_facing                        -- 1 or -1: the dash and hook aim
  set:step(dt, intent)
  body:step(dt, grid)
end
```

## The body

`abilities.new(body, opts)` takes anything with these methods:

| Method | |
|---|---|
| `body:on_ground()` | true while standing on something |
| `body:wall_side()` | `-1` (a wall on the left), `1` (on the right) or `0` |
| `body:center()` | the centre, `x, y` |
| `body:velocity()` | mean velocity, `vx, vy` (px/s) |
| `body:set_velocity(vx, vy)` | sets it; `nil` keeps that axis |
| `body:impulse(vx, vy)` | adds a change of velocity for the next step |

`engine.modules.softbody`'s `Body` has all six, so a slime is its own adapter. A platformer
controller can be wrapped in a table with these methods.

`opts.solid(x, y)` answers true for a solid world pixel (the hook needs it) or `opts.grid` gives
anything with `tile_size` and `kind(tx, ty)` (a `platformer.grid`); only `"solid"` tiles stop
the hook. Both are optional: without them the hook flies to its range and comes back.

## The set

| | |
|---|---|
| `set:grant(def)` | Gives an ability. Granting the same `id` again adds one stack and refills what stacks give. Returns the live ability. |
| `set:revoke(id)` | Takes it away (all stacks). |
| `set:has(id)`, `set:get(id)`, `set:stacks(id)` | Whether it is granted; the live ability (read its fields); how many stacks. |
| `set:step(dt, intent)` | Once per fixed step, before `body:step`. |
| `set:reset()` | Drops transient state (a room change): the hook is released, the dash stopped, the air uses refilled. |
| `set:state()`, `set:set_state(state)` | The granted abilities and stacks as plain data for a run save. The definition travels with each entry. |

`intent` is one table the game owns and refills every step (never a new one per frame):

| Field | |
|---|---|
| `move_x`, `move_y` | `-1..1`, the left stick or keys; `move_y < 0` is up (the hook goes straight up). |
| `jump` | jump pressed this step; `jump_held` is the button down. |
| `dash`, `hook` | pressed this step. |
| `jump_speed` | the game's current jump impulse, with its stats applied. |
| `facing` | `1` or `-1`, the direction to dash (or aim the hook) when nothing is held. |
| `consumed_jump` | written by the set: true when an ability used the jump press. |

Do the game's own ground jump first. The set only looks at `intent.jump` when the body is not on
the ground (or is hooked). Kinds run in `priority` order (lower first); the first that uses the
jump sets `intent.consumed_jump` and the rest ignore it.

## Definitions

Common fields: `id` (non-empty string, unique), `kind` (a registered name) and `priority`
(number; the kind's default when omitted). An unknown field or a wrong type is an error that
names it.

| Kind | Fields (default) | Behaviour |
|---|---|---|
| `air_jump` | `count` (1, per stack), `power` (1.0) | Jump in the air: the vertical velocity is set to `-jump_speed * power` (not added). Uses refill on landing, on a wall jump and when the hook releases. priority 30 |
| `wall_jump` | `kick_x` (180), `power` (1.0), `slide_speed` (60), `lock` (0.15) | In the air touching a wall: the jump sets `(-side * kick_x, -jump_speed * power)` and refills the air jump. For `lock` s the `move_x` into the wall is zeroed so the kick is not cancelled. Pushing into a wall while falling caps the vertical speed at `slide_speed` (0 disables). priority 10 |
| `dash` | `speed` (330), `time` (0.14), `cooldown` (0.45), `air_uses` (1, per stack), `dirs` (8; or 4), `trigger` (`"button"` or `"double_tap"`), `tap_window` (0.25), `tap_threshold` (0.5) | For `time` s the velocity is held at `dir * speed` every step (gravity cancelled). `trigger = "button"` uses `intent.dash`, aimed by `move_x, move_y` snapped to `dirs` directions (nothing held: `intent.facing`). `trigger = "double_tap"` detects two taps of `move_x` the same way within `tap_window` s (a tap is `|move_x|` crossing `tap_threshold` from below, so a stick or keys work the same) and dashes horizontally that way. It ends early on a wall in its direction; `air_uses` refills on landing. Reads `active`, `dir_x`, `dir_y` for a trail or i-frames. priority 20 |
| `hook` | `range` (112), `speed` (420), `angle` (55), `reel` (60), `min_length` (16), `pump` (260), `release_boost` (1.0), `one_way` (false) | `intent.hook` fires a point toward the facing `angle` degrees above horizontal (or straight up while `move_y < 0`). It flies in 2 px steps until it meets a solid pixel (attach; with `one_way = true` a one-way tile of `opts.grid` holds it too, or `opts.solid(x, y, true)` is asked) or passes `range` (miss). Attached, a rope constraint removes the outward velocity and moves the body back onto the circle; `move_y` reels in/out, `move_x` pumps. It releases on `intent.hook` again, on the jump (keeping the swing times `release_boost` plus `-jump_speed * 0.5` upwards, and refilling the air jump) or on `set:reset()`. Reads `phase` (`"idle"`, `"flying"`, `"attached"`), `hx`, `hy`, `length` for the rope. priority 5 |

The live ability is a plain table: the definition's fields plus its state (for example
`dash.active`, `dash.dir_x`, `dash.dir_y`, `hook.phase`, `air_jump.uses`). Read it; the set owns
the writes.

## A game's own kind

Registration is the same call the built-ins use:

```lua
abilities.kind("blink", {
  fields = { distance = { type = "number", default = 32 } },
  priority = 40,
  init = function(a) a.uses = 1 end,             -- optional
  restack = function(a) end,                     -- optional: a new stack
  reset = function(a) a.uses = 1 end,            -- optional: set:reset()
  step = function(a, set, dt, intent)            -- required
    if intent.dash and a.uses > 0 then
      set.body:impulse(a.distance * 10, 0)
      a.uses = a.uses - 1
    end
  end,
})
```

`fields` uses `{ type = "number" | "boolean" | "string", default = ..., values = { ... } }`.
`abilities.kind` validates them and calls `init` once per grant (after the fields are set).

## On the console

Plain Lua 5.1: no FFI, no `goto`, nothing from `love`, no `math.random`, no clock. A step reads
numbers and booleans, calls the body's six methods and allocates nothing. The hook's raycast is a
few `solid` lookups per step; nothing is kept in tables per frame.

Tests: `tests/engine/abilities_test.lua` (registered in `tests/engine/run.lua`), including a real
soft body on a `platformer.grid` and a no-allocation run with every kind granted.
