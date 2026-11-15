# engine/

Generic engine layer in Lua (objective 6). Nothing here may depend on a specific game or genre.
Reference and usage example: [docs/ENGINE.md](../docs/ENGINE.md).

| File | What it is |
|---|---|
| `init.lua` | Entry point: `require("engine")`, `engine.run(config)`; the frame loop that ties the rest together. |
| `state.lua` | Stack of game states with enter/exit/pause/resume/input/update/draw hooks. |
| `timestep.lua` | Fixed timestep at a configurable rate, with a cap on steps per frame and the interpolation alpha. |
| `input.lua` | Actions bound, as data, to keys, mouse buttons, gamepad buttons and gamepad axes. |
| `camera.lua` | Camera: follow, room bounds, room transitions, shake, world/screen conversion. |
| `pixel.lua` | Low-resolution drawing scaled by a whole number, with bars. |
| `layers.lua` | Sprites made of named layers drawn in a fixed order. |
| `entity.lua` | Entities made of components, cached queries, tags and ordered systems. |
| `modifiers.lua` | Modifiers as data: stats evaluated in a fixed order, events, stacking, timers, save state. |
| `anim.lua` | Animations with anim8 (`lib/anim8`). |
| `modules/` | Optional, genre-specific modules (objective 7). |

Plain Lua 5.1: no FFI, no `goto`, only the LÖVE functions in
[docs/API_SUBSET.md](../docs/API_SUBSET.md); nothing is allocated per frame or per step. A game
needs `engine/` (and `lib/anim8/` for animations) in its folder. Tests:
`luajit -joff tests/engine/run.lua`.

Not here yet: saves (`engine/save.lua`, with the game tools).
