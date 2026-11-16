# The engine layer (`engine/`)

Generic Lua modules on top of the LÖVE 11 subset ([API_SUBSET.md](API_SUBSET.md)). The same code
runs on official LÖVE 11.x on PC and on the console. Nothing in it knows about a game or a genre.
A game needs the `engine/` folder (and `lib/anim8/` for animations, `lib/bump/` for the
platformer module) in its own folder.

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
| `engine.state`, `.timestep`, `.input`, `.camera`, `.pixel`, `.layers`, `.entity`, `.modifiers`, `.rng`, `.save`, `.level`, `.ui`, `.anim`, `.debug` | The modules. `engine.anim` loads anim8 on first use; `engine.debug` is loaded on first use too. |

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

## engine.save

Saves, in two files that never mix: the **run** in progress (what is needed to continue) and
the permanent **progress** (unlocks, stats, settings). Both go through `love.filesystem`: the
identity folder on PC, the game's `save_dir` on the console ([GAME_CONFIG.md](GAME_CONFIG.md)).

```lua
local save = engine.save.new({
  identity = "my_game",                 -- default: love.filesystem.getIdentity()
  run      = { version = 2, migrate = { [1] = function(data) data.floor = data.level; return data end } },
  progress = { version = 1, defaults = { stats = { runs = 0 }, settings = { volume = 0.8 } } },
  log      = print,                     -- where problems are reported (default: print)
})

local progress = save:load_progress()   -- always a table; also in save.progress
progress.stats.runs = progress.stats.runs + 1
save:save_progress()
if save:unlock("hard_mode") then ... end      -- true the first time; saved at once
if save:is_unlocked("hard_mode") then ... end

if save:has_run() then
  local state, why = save:load_run()    -- state, or nil and "none" / "corrupt" / "newer" / "migration"
end
save:save_run(state)                    -- true, or nil and the reason
save:clear_run()                        -- on death or victory
```

| Call | Result |
|---|---|
| `save:save_run(state)` / `save:save_progress([data])` | `true`, or `nil` and the reason. `data` defaults to `save.progress`. |
| `save:load_run()` | The state, or `nil` and `"none"`, `"corrupt"`, `"newer"` or `"migration"`. |
| `save:has_run()` | Whether there is a run this game can load. The file is read and checked once, then remembered. |
| `save:clear_run()` | Removes the run (and its `.bak`). |
| `save:load_progress()` | The progress with `defaults` filled in for whatever is missing (so a new setting needs no migration), and `nil` or why the file was not used. |
| `save:unlock(id)`, `save:is_unlocked(id)` | Over `progress.unlocks[id] = true`. |
| `engine.save.serialize(value)` | The text, or `nil` and the reason. |
| `engine.save.parse(text)` | `true` and the value, or `false` and the reason. |

Options per kind: `version` (a whole number the game raises when the shape of its data changes;
default 1), `file` (`run.sav`, `progress.sav`), `migrate`, and `defaults` for the progress.
`backup` (default: true except on the console) keeps the previous good file as `<file>.bak`.

### What to put in a run save

Plain data only: numbers, strings, booleans and tables of them. The seed and the random
streams, and what each system already knows how to serialize:

```lua
save:save_run({
  rng = streams:state(),                 -- seed + the state of every named stream (engine.rng)
  modifiers = player.mods:serialize(),   -- engine.modifiers
  player = { x = player.x, y = player.y, hp = player.hp },
  enemies = enemy_list,                  -- the game's own plain tables: kind, position, hp...
  floor = 3,
})
-- and back:
streams:set_state(state.rng); player.mods:restore(state.modifiers)
```

Entities are saved as data the game can rebuild them from (a kind and its values), not as the
entity objects: those hold functions and references to each other. A function, a userdata, a
table that contains itself, or a key that is not a number or a string makes `save_run` return
`nil` and a reason that names the place (`root.player.sprite`); nothing is written. A table
referenced twice is written twice. Save at points the game chooses (a new room, a pause), not
every frame: the checksum is computed in Lua, and on the console a write wakes the save thread.

### The file

One header line, then the payload:

```
360PCSAVE 1 my_game run 2 9f3a01c4 187
{["floor"]=3,["rng"]={["seed"]=12345,["streams"]={["level"]="..."},},}
```

magic, engine save format (`engine.save.FORMAT`), the game's identity, the kind (`run` or
`progress`), the game's version of that kind, the FNV-1a sum of the payload (8 hex digits) and
the payload's length in bytes. The payload is the serializer's text: table keys sorted (1..n
first, then numbers, then strings), whole numbers in full, other numbers with 17 significant
digits (they read back as the same double), `nan`, `inf`, `-inf`, strings in double quotes with
`\\`, `\"`, `\n`, `\r`, `\t` and `\ddd` for the other control bytes. The same data always gives the
same bytes, on PC and on the console.

### Versions and migrations

`migrate[n]` takes the data of version `n` and returns it as version `n + 1`. Loading an older
file runs the chain up to the current version; the file is rewritten at the next save.

- A file of a **newer** version of the game, or of a newer engine save format: `"newer"`. The
  file is left alone and this session refuses to write over it or clear it.
- A missing step in the chain, or a migration that raises: `"migration"`, same treatment.
- A file that fails its length, checksum or parse, or belongs to another game or kind:
  `"corrupt"`. It is copied to `<file>.corrupt` and removed; on PC a good `<file>.bak` is put
  back and returned (second value `"backup"`), otherwise there is no run, or the progress is
  the defaults.

### Guarantees

- A save is never run as code: there is no `load`, `loadstring` or `dofile` in `engine/save.lua`.
  The parser only builds numbers, strings, booleans and tables (no metatables, at most 100
  levels deep), so a broken or edited file can at worst be rejected.
- No function here raises after `engine.save.new` (which checks the config): a failing
  `love.filesystem`, a bad state or a bad file comes back as `nil` and a reason, goes to `log`
  and stays in `save.last_error`.
- A write cut in half does not lose the previous save. On PC (LÖVE 11 has no rename) the last
  good file is copied to `.bak` before it is overwritten; with a filesystem that has `rename`,
  the new file is written to `.tmp` and renamed. On the console the runtime keeps two slots
  per file and reads the newest valid one, so `engine.save` writes once and keeps no `.bak`.
- The checksum catches accidents (a cut write, a bad sector, a careless edit), not cheating.

## engine.level

Levels made in LDtk: `tools/ldtk_convert.py` converts the project on the development PC into one
data file, and `engine.level.load(path)` reads it (through `Save.parse`, never `load()`) into
rooms with a collision grid, exits, entities and tile layers; `level.load_images` and
`level.batches` build the SpriteBatches. The rooms are procgen room templates as they are. The
LDtk conventions, the file and the API are in [LEVELS.md](LEVELS.md).

## engine.ui

Menus made for the controller: a screen holds a tree of widgets, one widget has the focus, the
directions move it and accept activates it. On PC the keyboard works the same way and the mouse
too (hovering focuses, a click activates). Everything is drawn with rectangles and text, in game
pixels, so it needs no images. `local ui = engine.ui`.

**Actions.** A screen reads six actions of the `engine.input` it is given: `ui_up`, `ui_down`,
`ui_left`, `ui_right`, `ui_accept`, `ui_back`. `ui.actions` has their default bindings (arrows and
WASD, d-pad and left stick; Enter / Space / A; Escape / Backspace / B). A screen defines the ones
the Input lacks the first time it sees it, so a game does nothing to get the defaults; to change
them, declare actions with those names in the input config, call
`ui.defineActions(input, { ui_accept = { keys = { "z" }, buttons = { "a" } } })`, or point a
screen at other actions with `actions = { accept = "confirm", back = "cancel" }`.

**Screen.** `screen = ui.screen(opts)`:

| Option | Meaning |
|---|---|
| `root` | The widget tree, usually a stack. |
| `width`, `height` | The game's resolution. Default: `engine.screen`'s (`config.pixel`), else the window's. |
| `anchor`, `margin` | Where the root goes: `"center"` (default), `"top"`, `"bottomleft"`... or `{ ax, ay }` in 0..1; `margin` pixels from the edges. |
| `theme` | A table of values that replace the default theme's (below). |
| `transparent`, `dim` | As a state: the state under it is drawn first; `dim` (default: `transparent`) darkens it. |
| `focus` | The widget (or id) focused first. Default: the first one that can be. |
| `on_back(screen)`, `on_focus(screen, widget, previous)` | Callbacks. |
| `repeat_delay`, `repeat_interval` | A held direction repeats after 0.4 s, every 0.1 s; rounded to whole fixed steps. |
| `actions`, `mouse = false`, `pixel` | Action names; ignore the mouse; the `engine.pixel` for mouse coordinates (default `engine.screen`). |

A screen has the hooks of a state (`enter`, `resume`, `input(input)`, `update(dt)`, `draw()`), so
`engine.states:push(screen)` is all it takes; without the state machine, call those three each
step and frame. Also `screen:focus(widget_or_id)`, `screen.focused`, `screen:get(id)`,
`screen:navigate("up" | "down" | "left" | "right")`, `screen:accept()`, `screen:back()`,
`screen:mouse(gx, gy, down)` and `screen:layout()`: call it after adding, removing, showing
(`widget.visible`) or hiding widgets. Nothing is allocated per step or per frame.

**Focus.** A direction goes, in this order, to: the focused widget itself (a slider's left and
right, a list along its items); its explicit neighbour, the fields `up`, `down`, `left`, `right`
(a widget or an id), or `next` (for down and right) and `prev` (for up and left); the nearest
widget in that direction, looking first among the widgets of its own stack, then of the stack
around that one, and so on. A stack with `wrap = true` (or `"vertical"` / `"horizontal"`) sends the
focus round to its other end instead of letting it leave. Widgets with `disabled = true` are
skipped. The mouse only takes the focus when it moves, so it does not fight the controller.

**Widgets.** Every option is a field of the widget and can be changed later; all take `id`,
`width`, `height`, `padding`, `disabled`, `visible`.

| Constructor | Options |
|---|---|
| `ui.label` | `text`, `align`, `color`, `dim`; with `width` it wraps (printf). `label:setText(s)`. |
| `ui.button` | `label`, `on_press(button, screen)`. |
| `ui.toggle` | `label`, `value`, `on_change(toggle, value, screen)`. |
| `ui.slider` | `label`, `min` (0), `max` (1), `step` (0.1), `value`, `track` (its width), `on_change(slider, value)`. Left and right move it one step; `slider:setValue(v)`. |
| `ui.list` | `items` (strings, or tables with `label` or `name`; or `format(item, i)`), `orientation` (`"vertical"` / `"horizontal"`), `rows` (how many are shown: the rest scroll), `selected`, `wrap`, `item_width`, `item_height`, `on_change(list, i, item)`, `on_select(list, i, item, screen)` on accept. `list:select(i)`, `list:setItems(items)`. |
| `ui.vstack`, `ui.hstack`, `ui.stack` | Children (the array part, or `children`) in a column or a row: `padding`, `spacing`, `align` across (`"start"`, `"center"`, `"end"`, `"stretch"`), `justify` along when the stack is given a larger `width` / `height`, `background` (a panel), `wrap`. |
| `ui.card` | A button showing `choice = { name, description, icon, quad }` (the pick screen's). |

**Theme.** `ui.theme` is plain data: `font` (nil: the current font), `padding`, `spacing`,
`border`, and colours `{ r, g, b, a }`: `text`, `text_dim`, `text_focus`, `text_disabled`, `panel`,
`panel_border`, `widget`, `widget_focus`, `focus` (the outline of the focused widget), `accent`,
`track`, `select`, `dim`. Change it in place for the whole game, or give a screen
`theme = { focus = { 1, 0, 0, 1 }, font = my_font }`.

A pause menu, as a transparent state over the game:

```lua
local ui, states = engine.ui, engine.states
local pause = ui.screen({
  transparent = true,                                   -- the game stays on screen, dimmed
  on_back = function() states:pop() end,                -- B / Escape
  root = ui.vstack({ background = true, wrap = true, align = "stretch", spacing = 4,
    ui.label({ text = "PAUSED", align = "center" }),
    ui.button({ label = "Resume", on_press = function() states:pop() end }),
    ui.toggle({ label = "Music", value = settings.music,
      on_change = function(_, on) settings.music = on end }),
    ui.slider({ label = "Volume", value = settings.volume, step = 0.1,
      on_change = function(_, v) settings.volume = v end }),
    ui.button({ label = "Quit", on_press = function() love.event.quit() end }),
  }),
})

function play:input(input)
  if input:pressed("pause") then states:push(pause) end
end
```

**Pick 1 of N.** `ui.pick(opts)` builds a screen with a title and one card per choice, for an
upgrade, a reward, a character. The choices are the game's own tables; the screen only reads
`name`, `description`, `icon` (an Image, with an optional `quad`, or a
`function(x, y, size, card)` that draws it) and `disabled`. Options: `title`, `hint`, `choices`,
`on_choose(index, choice, screen)`, `on_cancel(screen)` (leave it out and the choice cannot be
skipped), `dir` (`"horizontal"` / `"vertical"`), `card_width`, `card_height`, `icon_size`,
`selected`, and the screen's options. `screen.cards` are the card widgets; `screen:choose(i)` picks
from code.

```lua
local function offer_upgrades(three)        -- e.g. three modifier definitions drawn with engine.rng
  states:push(ui.pick({
    title = "Choose an upgrade", hint = "A: take   B: skip",
    choices = three,                        -- { { id = "thorns", name = "Thorns", description = "Attackers take 2 damage" }, ... }
    transparent = true,
    on_choose = function(index, choice)
      player.mods:add(choice.id)
      states:pop()
    end,
    on_cancel = function() states:pop() end,
  }))
end
```

The screen is built when it is pushed, not every frame. `examples/engine_demo` has one (C / Y).

## engine.debug

A debug mode for development builds (`engine/debug.lua`, loaded the first time `engine.debug`
is used). It is generic: everything it shows comes from functions and tables the game hands
over. **Off by default**: it is on only when `game.lua` has `debug = true`
([GAME_CONFIG.md](GAME_CONFIG.md)), when the game passes `enabled = true`, or after
`dbg:setEnabled(true)`. While off, every call below does nothing.

```lua
local dbg = engine.debug.new({
  action = "debug",                                    -- an action of the game's input config
  seed = function() return run.seed end,               -- the run's seed (number or string)
  on_seed = function(seed, code) start_run(seed) end,  -- the player entered a seed
  modifiers = registry,                                -- the game's engine.modifiers registry
  grant = function(id, def) player.mods:add(id) end,
  hitboxes = engine.debug.boxes(combat_world),         -- or any function(emit), see below
})

function play:input(input) dbg:input(input) end        -- opens the menu on the action
function play:draw(alpha)
  camera:attach(alpha)
  -- ... the world ...
  dbg:drawHitboxes()                                   -- in world coordinates
  camera:detach()
  dbg:draw()                                           -- "seed 0000C1S" in a corner
end
```

| | |
|---|---|
| `debug.new(opts)` | `enabled` (default `debug.flag()`), `action` (`"debug"`), `enable_action` (an action that switches the mode on and off even while off), `states` and `input` (default `engine.states`, `engine.controls`), `seed`, `on_seed`, `modifiers`, `grant`, `hitboxes` (a source or an array of them), `show_hitboxes`, `colors`, `rows`. |
| `debug.flag()` | The `debug` flag of `game.lua`: from `l360.game` on the console, from the file on PC. |
| `dbg:input(input)` | Once per fixed step. Opens the menu when the action is pressed. |
| `dbg:open()`, `dbg:close()` | The menu: an `engine.ui` screen pushed over the game with the seed code, "Enter seed" (if `on_seed`), a "Hitboxes" toggle (if there are sources), the modifier list (if `modifiers` and `grant`) and "Close". Back closes it. |
| `dbg:openSeedEntry()` | Seven columns, one per character of the seed code: up and down change the character, left and right move, accept confirms, back cancels. On accept, `on_seed(number, code)` runs and both screens close. `dbg:submitSeed(text)` does the same from code. |
| `dbg:grantModifier(id, def)` | What accept on the list does: calls `grant(id, def)`. `modifiers` is a registry (listed by id, shown by name) or an array of ids or `{ id =, name = }`. |
| `dbg:seedCode()` | The 7-character code of the current seed and its number. |
| `dbg:draw(x, y)` | Prints the seed code, in game pixels. |
| `dbg:addHitboxes(source)`, `dbg:drawHitboxes()` | The overlay, drawn only while `dbg.show_hitboxes` is on. Returns how many rectangles it drew. |

**Hitbox sources.** A source is `function(emit)`. It calls `emit(kind, x, y, w, h)` once per
rectangle (this allocates nothing), or returns an array of `{ x, y, w, h, kind }`, or both.
`kind` picks the colour: `"hit"`, `"hurt"`, `"body"`, `"solid"`, or any key added through
`colors`. `engine.debug.boxes(world, all)` is a ready-made source for a combat world
(`engine/modules/combat`): active hitboxes and enabled hurtboxes (`all`: inactive ones too).
`engine/debug.lua` does not require the combat module; the source only reads the world it is
given.

On the console text needs `default_font` in `game.lua`; the menus then work with the
controller alone (d-pad or stick, A, B).

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

## Genre modules (`engine/modules/`)

Optional, loaded by the game that wants them; nothing above requires one.

- `engine/modules/platformer`: tile collisions with bump.lua (`lib/bump`), one-way platforms, a
  character controller and the reach of its jump. Reference:
  [engine/modules/platformer/README.md](../engine/modules/platformer/README.md).
- `engine/modules/combat`: hitboxes and hurtboxes, damage through stats and modifier events,
  invulnerability frames, knockback, hitstop, and a state machine with enemy behaviours. It needs
  no other module. Reference:
  [engine/modules/combat/README.md](../engine/modules/combat/README.md).
- `engine/modules/procgen`: maps of hand-made rooms joined by their exits, zones locked by
  ability tags (keys always before their locks), validation by breadth-first search, minimap
  data, a layout hash that is the same on PC and console, and generation spread over frames.
  Reference: [engine/modules/procgen/README.md](../engine/modules/procgen/README.md).
- `engine/modules/items`: weighted item pools drawn with the run's `"loot"` stream, filtered by
  room type and the run's tags, with unique items per run and entries that permanent unlocks add.
  Reference: [engine/modules/items/README.md](../engine/modules/items/README.md).

```lua
local platformer = require("engine.modules.platformer")
local grid = platformer.grid.new({ "......", "..==..", "######" }, { tile_size = 16 })
local world = platformer.collision.newWorld(grid)
local body = platformer.controller.new(world, { x = 8, y = 0, w = 10, h = 14 })
function play:update(dt) body:step(engine.controls, dt) end     -- actions left, right, jump, down
```

```lua
local combat = require("engine.modules.combat")
local fight = combat.world.new()
local hero = fight:fighter({ body = body, team = "player", mods = set })   -- stats and events from the set
hero:hurtbox({ w = 10, h = 14 })
local slash = hero:hitbox({ ox = 10, oy = 2, w = 12, h = 8, knockback = 150, hitstop = 3 / 60 })
function play:update(dt)
  if not hero:frozen() then                       -- hitstop: the game skips what is frozen
    body:step(engine.controls, dt)
    if engine.controls:pressed("attack") then slash:activate(6 / 60) end
  end
  fight:step(dt)                                  -- overlaps, damage, i-frames, knockback
end
```

## What the console does differently

- No keyboard or mouse: bind every action to the controller too.
- No small canvases: `engine.pixel` draws in `"direct"` mode there.
- `love.keypressed`, `love.mousepressed`, `love.resize`, `love.textinput` and `love.focus` are
  never called there. `engine.run` defines them for PC, so `tools/compat_check.lua` lists them.
- Saves go to `save_dir` with two slots per file; `engine.save` keeps no `.bak` there.
- No built-in font: set `default_font` in `game.lua` ([GAME_CONFIG.md](GAME_CONFIG.md)).
