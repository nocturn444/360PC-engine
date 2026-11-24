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
| `pixel.lua` | Low-resolution drawing scaled by a whole number, with bars; `"direct"` mode by default on PC and console. |
| `pixelgrid.lua` | A small grid of colour indices that shapes (rectangles, circles, any polygon) are rasterized into every frame, drawn as pixel-aligned cells in one SpriteBatch draw call. |
| `layers.lua` | Sprites made of named layers drawn in a fixed order. |
| `entity.lua` | Entities made of components, cached queries, tags and ordered systems. |
| `modifiers.lua` | Modifiers as data: stats evaluated in a fixed order, events, stacking, timers, save state. |
| `rng.lua` | Seeded random numbers, identical on PC and console: xoshiro128**, named streams, save state, seed codes. |
| `save.lua` | Saves: the run in progress and the permanent progress, versioned files with a checksum, migrations, a serializer and a parser that never runs code. |
| `level.lua` | Levels: reads the file `tools/ldtk_convert.py` writes from an LDtk project into rooms (collision grid, exits, items, entities, tile layers as SpriteBatches), ready for `modules/procgen` (objective 11). Reference: [docs/LEVELS.md](../docs/LEVELS.md). |
| `ui.lua` | Controller-first menus: focus and spatial navigation, widgets, stacks, themes as data, a pick-1-of-N screen. |
| `text.lua` | A tiny built-in pixel font drawn with rectangles, for overlays on the console without a TTF. |
| `cutscene.lua` | A data-driven cutscene player: wait, fade, show, hide, move, pan, shake, typed text and dialogue, sound, music and call steps; drawn with `engine.text`, loaded on first use. |
| `audio.lua` | Sound effects and music as data: voices per effect, pitch / volume variation, crossfades, volume buses, pause. |
| `tune.lua` | Live tuning of numbers with an overlay, saved to and loaded from the save folder (development builds). |
| `anim.lua` | Animations with anim8 (`lib/anim8`). |
| `debug.lua` | Debug mode for development builds, off by default: seed code display and entry, a list that grants modifiers, a hitbox overlay fed by the game or a combat world (objective 17). |
| `modules/` | Optional, genre-specific modules: [`modules/README.md`](modules/README.md). `platformer/` (objective 12), `combat/` (objective 13), `procgen/` (objective 14) and `items/` (objective 15). |

Plain Lua 5.1: no FFI, no `goto`, only the LÖVE functions in
[docs/API_SUBSET.md](../docs/API_SUBSET.md); nothing is allocated per frame or per step. A game
needs `engine/` (and `lib/anim8/` for animations, `lib/bump/` for `modules/platformer`) in its
folder. Tests:
`luajit -joff tests/engine/run.lua`.
