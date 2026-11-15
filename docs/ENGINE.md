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
| `engine.state`, `.timestep`, `.input`, `.camera`, `.pixel`, `.layers`, `.anim` | The modules. `engine.anim` loads anim8 on first use. |

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
