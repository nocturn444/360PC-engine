# The engine layer (`engine/`)

Generic Lua modules on top of the LÖVE 11 subset ([API_SUBSET.md](API_SUBSET.md)). The same code
runs on official LÖVE 11.x on PC and on the console. Nothing in it knows about a game or a genre.
A game needs the `engine/` folder (and `lib/anim8/` for animations) in its own folder.

## A minimal game

```lua
-- main.lua
local engine = require("engine")
local x, px = 20, 20

local play = {}
function play:update(dt)                       -- fixed step: dt is always 1/60 here
  px = x
  x = x + engine.controls:axis("move_x") * 80 * dt
  if engine.controls:pressed("quit") then love.event.quit() end
end
function play:draw(alpha)                      -- every frame, in 320x180 game pixels
  love.graphics.rectangle("fill", px + (x - px) * alpha, 80, 16, 16)
end

engine.run({
  rate = 60,
  pixel = { width = 320, height = 180 },
  input = {
    actions = {
      left  = { keys = { "left" },  buttons = { "dpleft" } },
      right = { keys = { "right" }, buttons = { "dpright" } },
      quit  = { keys = { "escape" }, buttons = { "back" } },
    },
    axes = { move_x = { negative = "left", positive = "right", stick = "leftx" } },
  },
  states = { play = play },
  start = "play",
})
```

A fuller one, with every module: [examples/engine_demo](../examples/engine_demo).

## engine (`engine/init.lua`)

| | |
|---|---|
| `engine.run(config)` | Sets `love.load`, `love.update`, `love.draw`, `love.resize` and the input callbacks. Callbacks the game already defined still run, first. `love.run` is not touched (the console ignores it). |
| `engine.init(config)`, `engine.update(dt)`, `engine.draw()` | The same three steps, to call from the game's own callbacks instead of `run`. |
| `engine.time`, `engine.states`, `engine.controls`, `engine.screen` | The Timestep, the state Machine, the Input (if `config.input`) and the Pixel (if `config.pixel`), once `love.load` ran. |
| `engine.state`, `.timestep`, `.input`, `.camera`, `.pixel`, `.layers`, `.entity`, `.modifiers`, `.rng`, `.anim` | The modules. `engine.anim` loads anim8 on first use. |

Config: `rate` (Hz, 60), `max_steps` (5), `max_frame` (0.25 s), `input`, `pixel`, `states`
(`name = table`), `load` (`function(engine)`, runs in `love.load` before the first state is
entered: create images here), `start` (first state).

A frame: `controls:poll()`; then, for each fixed step the frame time asks for, `controls:step()`,
the top state's `input(controls)` and `update(dt)`; then `screen:start()`, the states'
`draw(alpha)`, `screen:finish()`, and the states' `draw_screen(alpha)` in screen pixels. Other
events (`keypressed`, `gamepadpressed`, `resize`, `quit`...) reach the top state as hooks of the
same name. The console runs at 30 FPS: at 60 Hz a frame there is two steps.

## engine.timestep

`ts = timestep.new({ rate = 60, max_steps = 5, max_frame = 0.25 })`

- `steps, alpha = ts:advance(frame_dt)`: how many fixed steps to run now, and how far (0..1) the
  frame is past the last one, for drawing between the previous and the current positions.
- A frame that asks for more than `max_steps` runs `max_steps` and drops the rest (`ts.dropped`,
  seconds), so a slow frame does not make the next one slower still.
- `ts.dt` (seconds per step), `ts.tick` (steps so far), `ts.time`, `ts:setRate(hz)`, `ts:reset()`.
- The same frame times always give the same steps: logic that only depends on steps is repeatable.

## engine.state

`sm = state.new()`. A state is a table; every hook is optional.

| Hook | When |
|---|---|
| `enter(self, previous, ...)` / `exit(self, next)` | Pushed or switched to / removed. |
| `pause(self, next)` / `resume(self, from, ...)` | Another state pushed on top / top again after a pop. |
| `input(self, input)`, `update(self, dt)` | Each fixed step, top state only. |
| `draw(self, alpha)`, `draw_screen(self, alpha)` | Each frame. A state with `transparent = true` lets the one under it draw first (a pause screen over the game). |

`sm:add(name, state)`, `sm:push(state_or_name, ...)`, `sm:pop(...)` (the arguments go to
`resume`), `sm:switch(state_or_name, ...)` (replaces the top), `sm:reset([state, ...])` (empties
the stack), `sm:top()`, `sm:depth()`, `sm:get(name)`, `sm:emit(hook, ...)` (calls a hook of the
top state), `sm:input(input)`, `sm:update(dt)`, `sm:draw(alpha [, hook])`.

## engine.input

Actions are declared as data; the game never names a key.

```lua
input = Input.new({
  deadzone = 0.25,          -- sticks, for axis actions
  threshold = 0.5,          -- how far an axis must go to count as a button
  joystick = nil,           -- nil: every connected gamepad; n: only the nth (one Input per player)
  actions = {
    jump = { keys = { "space" }, mouse = { 1 }, buttons = { "a" },
             axes = { "triggerright+", { axis = "lefty", dir = -1, threshold = 0.8 } } },
  },
  axes = { move_x = { negative = "left", positive = "right", stick = "leftx", deadzone = 0.3 } },
})
```

- Keys are LÖVE key names, mouse buttons numbers, buttons and axes LÖVE gamepad names
  (`a b x y back start leftshoulder dpup...`, `leftx lefty rightx righty triggerleft triggerright`).
- `input:down(name)`, `input:pressed(name)`, `input:released(name)`: `pressed` and `released` are
  true for exactly one fixed step, however many steps a frame runs; a tap shorter than a step
  still counts as one press.
- `input:axis(name)`: -1..1. A digital direction wins; otherwise the stick, 0 inside the deadzone
  and rescaled from its edge. `invert = true` flips it.
- `input:poll()` once per frame, `input:step()` once per fixed step (`engine.update` does both).
  `input:flush()` after changing state, so what is held does not count as pressed again.
- Rebinding: `input:bind(action, kind, value)`, `input:unbind(action, kind [, value])`,
  `input:define(action, bindings)`, `input:getBindings(action)`, `input:export()` /
  `input:load(data)` (a plain table, to keep in a save), and `input:capture(function(kind, value))`,
  which hands over the next key, mouse button, gamepad button or axis (`"leftx-"`).
- `device, joystick = input:getDevice()`: `"keyboard"` or `"gamepad"`, whichever was used last (to
  show the right button prompts).
- The keyboard and mouse are read with `love.keyboard.isDown` / `love.mouse.isDown`, which answer
  false on the console; the controller with the Joystick gamepad API on both. Nothing is turned
  into keys.

## engine.camera

`cam = camera.new({ width = 320, height = 180, lerp = 10, deadzone_w = 32, deadzone_h = 16, snap = true })`

`cam.x, cam.y` is the world point at the centre of the view.

- `cam:follow(x, y)` and `cam:update(dt)` each step. `lerp = 0` keeps the camera on the target;
  otherwise it closes the distance at that speed per second (the same at any step rate). The
  target moves freely inside the deadzone box.
- `cam:setBounds(x, y, w, h)` / `cam:clearBounds()`: the view stays inside that rectangle (a room);
  a room smaller than the view is centred.
- `cam:transition(x, y, w, h, { mode, duration, on_done })`: new bounds, reached with `"instant"`,
  `"slide"` (the view travels to its place in the new room) or `"fade"` (`cam.fade` goes 0 to 1,
  the view jumps, 1 to 0; draw it with `cam:drawFade(r, g, b)` or your own effect).
  `cam:isTransitioning()`.
- `cam:shake(amplitude, duration)`: pixels, fading out. Its own random generator: the same shake
  on PC and console.
- `cam:attach(alpha)` ... `cam:detach()`: draw in world coordinates in between (`push`,
  `translate`, `scale`). `alpha` interpolates between the last two steps. `snap = true` rounds the
  translation to whole pixels.
- `cam:toWorld(sx, sy)`, `cam:toScreen(wx, wy)`, `cam:getViewport(alpha)` (the world rectangle in
  view, to skip what is outside), `cam:setPosition(x, y)`, `cam.zoom`.

## engine.pixel

`screen = pixel.new({ width = 320, height = 180, mode = "auto", integer = true, background = { 0, 0, 0 }, bars = { 0, 0, 0 } })`

Between `screen:start()` and `screen:finish()` the game draws in game pixels; the result is
shown scaled by the largest whole number that fits, centred, with bars around it (x4 with no bars
for 320x180 on the console's 1280x720). `pixel.new` also sets nearest as the default filter.

| Mode | How | Where |
|---|---|---|
| `"canvas"` | Draws on a canvas of the game's size, then draws the canvas scaled, nearest. True low-resolution pixels, whatever is drawn. | PC. On the console a Canvas always has the screen's size. |
| `"direct"` | Draws on the screen under a translate and a scale; the bars are drawn last. A game pixel is still scale x scale screen pixels for anything drawn at whole coordinates with no rotation or scaling (use the camera's `snap`). | Console and PC. |
| `"auto"` | `"direct"` on the console, `"canvas"` elsewhere. | Default. |

To see on PC exactly what the console shows, use `mode = "direct"`.

`screen:toGame(sx, sy)` (returns x, y and whether the point is inside the game area),
`screen:toScreen(gx, gy)`, `screen:getMouse()`, `screen:resize([w, h])`, `screen.scale`,
`screen.ox`, `screen.oy`, `pixel.fit(gw, gh, sw, sh, integer)`. For a world position under the
mouse: `cam:toWorld(screen:getMouse())`.

## engine.layers

A sprite made of named layers: `set = layers.new({ "body", "outfit", "held", "effect" })`.

**Draw order, back to front:** the layers named in the list given to `new`, in that order; then
any other layer, in the order they were first added. Replacing a layer keeps its place.

- `set:set(name, def)` adds or replaces. `def`: `image`, `quad`, `anim` (anything with
  `update(dt)` and `draw(image, x, y, r, sx, sy, ox, oy)`, such as an anim8 animation), or
  `draw = function(layer, x, y, r, sx, sy, ox, oy)`; `ox`, `oy` (offset in the sprite's own
  pixels: it follows flips and rotation); `tint = { r, g, b, a }`; `visible`.
- `set:remove(name)`, `set:get(name)`, `set:has(name)`, `set:count()`, `set:getOrder()`,
  `set:setVisible`, `set:setOffset`, `set:setTint`, `set:setAnim`, `set:setQuad`.
- `set:update(dt)` advances every layer's animation; `set:draw(x, y, r, sx, sy, ox, oy)` draws the
  visible ones (`sx = -1` to face the other way). Tints multiply the current colour.

It does not know about entities: an entity keeps a set and draws it at its position.

## engine.entity

`world = entity.new()`. An entity is a plain table and its components are its fields
(`e.pos = { x = 1, y = 2 }`: plain data). The world owns three more fields: `e.id` (a number,
counted from 1 and never reused in that world), `e.alive` and `e.tags` (a set:
`e.tags.enemy == true`).

```lua
local world = engine.entity.new()
local moving = world:query("pos", "vel")           -- ask once, keep it
world:addSystem({
  name = "move", order = 10, query = { "pos", "vel" },
  process = function(self, e, dt, world)           -- each fixed step, each live entity
    e.pos.x = e.pos.x + e.vel.x * dt
    if e.pos.x > 500 then world:remove(e) end      -- safe: the list does not move until the flush
  end,
})
world:add({ pos = { x = 0, y = 0 }, vel = { x = 60, y = 0 } }, { "enemy" })
-- in a state: world:update(dt) in update, world:draw(alpha) in draw
```

- `world:add(table [, tags])` returns the table, now an entity. `world:remove(e or id)`,
  `world:get(id)`, `world:count()`, `world:clear()`, `world.entities` / `world.all.n`.
- `world:set(e, name [, data])`, `world:unset(e, name)`, `world:tag(e, tag)`,
  `world:untag(e, tag)`. Use these instead of writing `e.vel = nil`: the lists have to know.
  Changing what is *inside* a component needs no call.
- `q = world:query("a", "b")` or `world:query({ "a", "b", tags = { "enemy" }, without = { "frozen" } })`:
  entities with every component and tag named and none of the components or tags in `without`.
  The same question gives the same object. `q.list[1..q.n]`, `for i, e in q:each() do` (skips the
  dead, allocates nothing), `q:first()`, `q:contains(e)`, `q:count()`.
- **When changes show.** Data changes at once; lists change at `world:flush()`, which
  `world:update` runs before the first system and after each one (and which you may call
  yourself, outside a loop over a list):

  | Call | At once | At the flush |
  |---|---|---|
  | `add` | `e.id`, `e.alive`, `world:get(id)` | joins the lists |
  | `remove` | `e.alive = false`, `world:get(id)` is nil | leaves the lists (`each` and systems skip it meanwhile) |
  | `set` | the component | joins / leaves lists |
  | `unset` | nothing: the component stays | the component goes, and the lists follow |
  | `tag`, `untag` | `e.tags` | joins / leaves lists |

  A list keeps the order in which entities joined it (for entities that do not change, the
  order they were added in), so a run is the same every time.
- Systems: `world:addSystem(sys)`, `world:removeSystem(sys)`, `world:getSystem(name)`. Every
  field is optional:

  | Field | |
  |---|---|
  | `order` | A number, default 0. Systems update lowest first; equal orders run as they were added. `draw_order` is the same for drawing (default: `order`). |
  | `query` | What `world:query` takes. The query is then `sys.entities`. |
  | `update(self, dt, world)` | Once per fixed step. |
  | `process(self, e, dt, world)` | Once per fixed step for each live entity of the query. |
  | `draw(self, alpha, world)`, `draw_entity(self, e, alpha, world)` | Once per frame (`world:draw(alpha)` flushes nothing). |
  | `added(self, e, world)`, `removed(self, e, world)` | An entity joined or left the query, at a flush (to create or free what goes with it). |
  | `enabled` | `false` to skip it. |

- `world.tick` counts the updates; `world.next_id` is the next id (a save keeps both).
- Drawing is the game's: a system with `draw_entity` that draws `e.sprite` (an `engine.layers`
  set, for instance) at `e.pos`.

## engine.modifiers

Modifiers are data. A registry holds the definitions; each entity that can have modifiers keeps
a set (usually as its `mods` component). Nothing in it knows what a stat or an event means.

```lua
local mods = engine.modifiers.new()                 -- the registry
mods:stat("speed", { base = 90, min = 0 })          -- optional: default base, hard limits
mods:define({
  id = "thorns", name = "Thorns", tags = { "mutation" },
  priority = 0,                                     -- higher hears events first
  stacking = "stack", max_stacks = 5,               -- "unique" (default), "stack", "refresh"
  duration = nil,                                   -- seconds; nil: it stays
  stats = { { "armor", "add", 1 }, { "speed", "mul_base", -0.05 } },
  events = {
    on_damaged = function(entity, ctx, modifier)    -- modifier: read-only view of this one
      modifier.state.hits = (modifier.state.hits or 0) + 1
      return ctx.amount - modifier.stacks           -- on_damaged is a chain on ctx.amount
    end,
  },
})
e.mods = mods:attach(e, { speed = 100 })            -- owner, base stats
e.mods:add("thorns")
local speed = e.mods:get("speed")
local dealt = e.mods:emit("on_damaged", { amount = 10, source = other })
world:addSystem(engine.modifiers.system())          -- calls e.mods:update(dt) each step
```

### Stats: the evaluation order

`set:get(stat)` always evaluates in this order, whatever the order the modifiers were acquired in:

| # | Phase | Rule |
|---|---|---|
| 1 | base | `set:setBase(stat, v)` (or the table given to `attach`), else the base declared with `mods:stat`, else 0 |
| 2 | `add` | `base + Σ (value × stacks)` |
| 3 | `mul_base` | `× (1 + Σ (value × stacks))`: percentages add up with each other |
| 4 | `mul` | `× Π (value ^ stacks)`: each one multiplies the result |
| 5 | `set` | replaces the result of 1 to 4. With several: the modifier with the highest `priority`, then the largest value |
| 6 | `min`, `max` | raised to the largest `min`, then lowered to the smallest `max` (so `max` wins a conflict) |
| 7 | declared limits | the `min` and `max` given to `mods:stat`, last |

Within a phase the result does not depend on the order: sums and products are taken in the
set's fixed order (priority, then acquisition), so the floating-point result is the same on every
run and on both platforms.

Worked example, base speed 100, declared `max = 300`, with these modifiers:

| Modifier | Entry | Stacks |
|---|---|---|
| boots | `{ "speed", "add", 20 }` | 2 |
| wind | `{ "speed", "mul_base", 0.5 }` | 1 |
| gale | `{ "speed", "mul_base", 0.25 }` | 1 |
| rage | `{ "speed", "mul", 2 }` | 1 |
| mud | `{ "speed", "max", 400 }` | 1 |

1. base: 100
2. add: 100 + 20 × 2 = 140
3. mul_base: 140 × (1 + 0.5 + 0.25) = 245
4. mul: 245 × 2 = 490
5. set: none, still 490 (a `{ "speed", "set", 10 }` would make it 10 here)
6. min, max: mud's 400 → 400
7. declared limit 300 → **300**

Values are cached per stat: a stat is computed on the first `get` and kept until a modifier is
added or removed, a stack count changes, a timer runs out or a base changes. `set.version` goes up
at each such change (compare it to know when to refresh what depends on the stats);
`set:setBase`, `set:getBase`.

### Stacking and durations

| `stacking` | Adding it again |
|---|---|
| `"unique"` (default) | Nothing: `add` returns false. |
| `"stack"` | Adds stacks, up to `max_stacks`. Stacks multiply `add` and `mul_base` values and raise `mul` values to their power; handlers run once and read `modifier.stacks`. |
| `"refresh"` | One stack; its timer starts again. |

`set:add(id [, stacks [, duration]])`, `set:remove(id [, stacks])`, `set:removeTagged(tag)`,
`set:has(id)`, `set:stacks(id)`, `set:timeLeft(id)`, `set:hasTag(tag)`, `set:count()`, `set:ids()`.

A modifier with a `duration` has one timer for all its stacks; adding a `"stack"` or
`"refresh"` modifier again restarts it. `set:update(dt)`, once per fixed step, runs the timers
and then sends `on_update`: a 0.5 s modifier at 60 Hz is there for exactly 30 steps. When the time
is up the whole modifier goes.

### Events

`set:emit(name, ctx)` calls `handler(entity, ctx, modifier)` on every modifier of the set that
has a handler of that name: **higher `priority` first, then the order they were acquired in**.
`ctx` is the game's table for that event (reuse one to allocate nothing). The game emits the
events: the engine only sends `on_update`, `on_add` and `on_remove` itself.

| Event | Combination | `emit` returns |
|---|---|---|
| `on_jump`, `on_attack`, `on_kill` | none | nil |
| `on_update` | none; `ctx.dt` | nil |
| `on_hit` (the owner hits something) | chain on `ctx.amount`, minimum 0 | the final amount |
| `on_damaged` (the owner is hit) | chain on `ctx.amount`, minimum 0 | the final amount |
| `on_add`, `on_remove` | only the modifier itself hears them; `ctx.reason` is `"new"`, `"stack"`, `"refresh"` / `"remove"`, `"expire"`; `ctx.stacks` | |
| any other name | none, unless declared | |

A game declares its own with `mods:event(name, { combine = ..., field = ..., min = ..., max = ... })`:

| `combine` | |
|---|---|
| `"none"` | Returns are ignored. |
| `"chain"` | `ctx[field]` goes through the handlers in order: a return that is not nil replaces it, and the next handler sees the new value. `emit` returns the last value, kept within `min` and `max`. |
| `"sum"` | The sum of the numbers returned. |
| `"any"` | True if a handler returned a true value. |
| `"all"` | False if a handler returned false. |

Damage example: with `frail` (priority 2, `return ctx.amount * 2`) and `armor` (priority 1,
`return ctx.amount - 3`), `emit("on_damaged", { amount = 10 })` gives 10 × 2 = 20, then 20 − 3 = **17**.

**A modifier never rewrites another.** A handler gets the entity, the event's `ctx` and
`modifier`, a read-only view of its own instance: `id`, `name`, `stacks`, `time` (seconds left),
`duration` and `state`, a table of its own for counters and the like (plain data: it is saved).
Writing to the view is an error, no call returns another modifier's instance or state, and the
set only answers `has`, `stacks`, `timeLeft` and `hasTag` about the others. Modifiers affect each
other only through stats and through `ctx`. A handler may call `set:add` / `set:remove`: it
returns nil and is done when the event is over, so the list never changes under a dispatch.
Nothing here draws random numbers: a handler that needs them takes the game's seeded generator
(`engine.rng`) from `ctx` or the entity.

### Saving

`data = set:serialize()` is a plain table (`base`, and for each modifier `id`, `stacks`, `time`,
`duration`, `seq`, `state`); `set:restore(data)` puts it back without sending `on_add`, keeps the
event order, and returns the list of ids that are not defined any more (skipped), or nil.

## engine.rng

Seeded random numbers that are the same, bit for bit, on PC (LuaJIT with the JIT) and on the
console (LuaJIT interpreter): the same seed gives the same level, loot and run on both.

```lua
local rng = engine.rng
local run = rng.streams("daily 2026-11-15")    -- or a number; one per run
local level, loot = run:get("level"), run:get("loot")

local width = level:int(8, 20)                  -- whole number in [8, 20], every value equally likely
local x = level:float() * 320                   -- [0, 1)
if loot:chance(0.1) then ... end                -- true 1 time in 10
local enemy = level:pick(enemies)               -- an item (and its index)
local drop = loot:weighted(table)               -- by item.weight; or ("field") or (function(item, i))
level:shuffle(rooms)                            -- in place, Fisher-Yates
```

| | |
|---|---|
| `rng.new(seed)` | A generator. `seed` is an integer (taken modulo 2^32) or a string (hashed with FNV-1a, 32 bits). |
| `r:next_u32()` | The next 32 bits, an integer in [0, 2^32). |
| `r:int(lo, hi)`, `r:int(n)` | An integer in [lo, hi] (or [1, n]) without bias: values outside the range are thrown away and drawn again, so it takes one draw or more. Up to 2^32 values. |
| `r:float()` | k / 2^24, in [0, 1). One draw. |
| `r:chance(p)` | `r:float() < p`. Always one draw, also for 0 and 1. |
| `r:pick(list)` | `item, index`; nil, without a draw, for an empty list. |
| `r:weighted(list, weight)` | `item, index`, with a probability proportional to the weight: the field named `weight` (default `"weight"`), the result of `weight(item, index)`, or the item itself in a list of numbers. Whole weights are exact (one `int(1, total)`); weights with fractions use `float() * total`. Weights of 0 are never picked; an error if none is above 0. |
| `r:shuffle(list)` | Shuffles in place and returns the list. |
| `r:state()`, `r:set_state(s)` | The state as a string of 32 hex digits, and back. |
| `r:clone()` | A copy that continues with the same numbers (to look ahead without spending the original). |
| `rng.streams(seed)` | A set of generators by name. `s:get(name)` makes it the first time, from the seed and the name alone, and returns the same one after that. `s.seed` is the number in use. |
| `s:state()`, `s:set_state(data)` | `{ seed = number, streams = { name = state string } }`, a plain table for the save; `set_state` puts it back (generators already handed out stay valid; a stream that is not in the save starts from the seed). |
| `s:reset(seed)` | Starts every stream again, from a new seed if one is given. |
| `rng.seed_to_code(seed)`, `rng.code_to_seed(text)` | The seed as 7 characters to show and type (`"0000C1S"`; Crockford's base 32, no I, L, O or U), and back to the number (or `nil, message`). Typing accepts lower case, spaces and dashes, O as 0, I and L as 1. `rng.seed_number(seed)` is the number a string seed becomes. |

**Algorithm.** xoshiro128** (Blackman and Vigna): 128 bits of state, period 2^128 - 1. The 4
state words come from the seed (and, for a stream, the FNV-1a hash of its name) through the
MurmurHash3 finalizer. Everything is done with the `bit` library on values that fit in 32 bits
signed; the multiplications are done in limbs so no intermediate value reaches 2^31. So nothing
depends on integer overflow, on how a big double becomes 32 bits, on float rounding or on the
JIT, which is where the two LuaJIT builds could differ. `float` is a 24-bit integer times 2^-24,
exact. It is not for cryptography.

**Guarantees.** The same seed and the same calls in the same order give the same results on
every platform and in every later version of the engine: the sequences are pinned by
`tests/console/rng_check.lua` (checked against a C version of the algorithms), which runs on PC
with and without the JIT and on the console. Nothing is allocated per draw.

**Streams.** Use one stream per purpose (`"level"`, `"loot"`, `"fx"`, or any name the game
wants): drawing from one never changes another, and the order in which they are first asked
for does not matter. So adding a particle effect (`fx`) does not change the levels, and the
loot of a room does not depend on how many enemies were rolled before it. Anything that does
not affect the game (particles, screen shake) goes in its own stream, never in a gameplay one.

**What not to do.**

- No `math.random` or `love.math.random` for gameplay: they differ between PC and console
  and are not saved. (For a new run's seed, something like `os.time()` is fine: that is the one
  number that is not reproducible, and it is shown as the seed code.)
- Do not draw gameplay numbers in `draw` or per frame: only in the fixed `update`, so the count
  of draws does not depend on the frame rate.
- Do not draw while iterating with `pairs`: its order is not defined. Use arrays, or sort the keys.
- Weights with fractions and `float() * something` are still IEEE doubles, the same on both
  platforms, but prefer whole weights and `int`: they are exact by construction.
- A string seed is always hashed: `rng.new("0000C1S")` is not `rng.new(rng.code_to_seed("0000C1S"))`.
- Two stream names with the same 32-bit hash would share a sequence (1 in 2^32 per pair).

## engine.anim

anim8 v2.3.1 (`lib/anim8`, unchanged; `anim.anim8` is the library itself), plus animations from
data:

```lua
local grid = engine.anim.grid(image, 16, 16)                    -- frame size; the image gives the rest
local anims = engine.anim.set(grid, {
  walk = { frames = { "1-4", 1 }, duration = 0.1 },             -- columns 1 to 4 of row 1
  die  = { frames = { "1-3", 2 }, duration = 0.1, loop = false },
})
local mine = anims.walk:clone()                                 -- one copy per sprite
mine:update(dt); mine:draw(image, x, y)
```

## What the console does differently

- No keyboard or mouse: bind every action to the controller too.
- No small canvases: `engine.pixel` draws in `"direct"` mode there.
- `love.keypressed`, `love.mousepressed`, `love.resize`, `love.textinput` and `love.focus` are
  never called there. `engine.run` defines them for PC, so `tools/compat_check.lua` lists them.
- No built-in font: set `default_font` in `game.lua` ([GAME_CONFIG.md](GAME_CONFIG.md)).
