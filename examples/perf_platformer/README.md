# examples/perf_platformer/

The performance test of 360PC-Engine (objective 18): a small game that loads the engine the way
a real one would, with the load set from the controller, an overlay with the frame's timings and
an automatic benchmark that writes a results table. It runs on official LÖVE 11.x and on the
console.

What a frame does:

- **Level.** A procgen map (`engine/modules/procgen`) of 12 rooms picked from 8 hand-made
  templates. The templates are rows of tile strings in `perf/rooms.lua`, the form
  `platformer.grid` takes; they stay in code because the level file format (objective 11) is not
  decided. The map is at least 4 screens wide (6 x 4 rooms of 20 x 12 tiles with the default
  seed). Each room is one static SpriteBatch of about 250 sprites; only the rooms in view are
  drawn.
- **Player and N enemies**, N = 0, 50, 100 or 200. Each is a platformer controller body in one
  bump world (`engine/modules/platformer`) and a fighter with a hurtbox and a hitbox in one
  combat world (`engine/modules/combat`). Every enemy runs a patrol / chase / attack state
  machine (`combat.behaviours`). Enemies are spread over the whole level, in places drawn from
  the seed, and come back 1.5 s after they die, so the load stays the same. All actors in view go
  in one SpriteBatch that is rebuilt every frame (two frames of animation each).
- **Particles**, 500, 1000 or 2000: one `ParticleSystem` whose buffer is that count, emitting
  over the whole view faster than the particles die, so the number alive is the number asked
  for. Drawn with additive blending.
- **Overlay.** FPS, frame ms and the worst frame since the last refresh; update ms and draw ms,
  measured with `love.timer.getTime` around the engine's whole update (every fixed step the
  frame ran) and whole draw; draw calls (`love.graphics.getStats().drawcalls`, read before and
  after the draw); enemies (and how many are in view), live particles and the count asked for;
  the level's seed code. The values are smoothed and refreshed four times a second. The text is
  a 3x5 pixel font inside `tiles.png`, drawn as one SpriteBatch: the console has no built-in font
  and this example ships no TTF, so `love.graphics.print` would show nothing there.

No external art: `tiles.png` (128x32) is written by `tools/make_tiles.py`. The console has no
`love.image.newImageData`, so the image cannot be made at run time.

| File | What it is |
|---|---|
| `game.lua`, `conf.lua` | The game config and LÖVE's window settings. |
| `perf_settings.lua` | The test's settings: seed, rooms, the enemy and particle counts, the benchmark. |
| `main.lua` | `engine.run`, the actions, and the timing around the engine's update and draw. |
| `perf/rooms.lua` | The room templates. |
| `perf/level.lua` | The map, the tile grid, the bump world, the room batches, the standing spots. |
| `perf/actors.lua` | The player, the enemies and their state machine; the benchmark's autopilot. |
| `perf/play.lua` | The state: update, draw, the particles, the overlay's lines. |
| `perf/meter.lua`, `perf/bench.lua` | The smoothed timings; the benchmark and its results file. |
| `perf/atlas.lua`, `perf/text.lua` | The quads of `tiles.png`; text as a SpriteBatch. |

## Controls

| | Keyboard | Controller |
|---|---|---|
| Move, drop through a platform | arrows or A / D, down or S | d-pad or left stick |
| Jump | Space, up or W | A |
| Attack | X or J | X |
| Next enemy count (0, 50, 100, 200) | E | RB |
| Next particle count (500, 1000, 2000) | P | LB |
| Start or stop the benchmark | B | Start |
| Show or hide the overlay | O | Y |
| Quit | Escape | hold Back for 3 s (console) |

## Run it on PC

From the repository root, with official LÖVE 11.x:

```sh
love examples/perf_platformer
```

`main.lua` finds the base (`engine/` and `lib/`) two folders up, in this repository. A copy of
this folder elsewhere needs `engine/` and `lib/` next to `main.lua`, or the repository as
`base/`, like any game ([template/README.md](../../template/README.md)).

Without a GPU, from the repository root:

```sh
luajit -joff tests/pc/boot_pc.lua examples/perf_platformer       # the console's boot, 90 frames
luajit -joff tests/pc/perf_platformer_test.lua                   # the test: settings, benchmark, results file
```

## Run it on the console

As any game ([docs/NEW_GAME.md](../../docs/NEW_GAME.md)): build the `.xex` with this game's
Title ID (`0x4D470018`), build the shaders (the game declares none, the engine's own four files
are still needed), then package and install:

```sh
python tools/package.py examples/perf_platformer --xex runtime/build/game.xex --shaders build/perf_platformer/shaders --zip
python tools/install_ftp.py dist/perf_platformer --host <console IP>
```

The packaging adds `engine/` (with the platformer, combat and procgen modules), `lib/bump` and
the runtime's Lua. Launch it from Aurora.

## The benchmark

Start (or B) runs every pair of enemy and particle counts, 12 with the default lists: 2 s of
warm-up, then 10 s measured. While it runs, an autopilot plays (it walks, turns at walls, jumps
and attacks on a fixed schedule), so every run does the same thing. To start it without touching
the controller, set `benchmark = true` in `perf_settings.lua` (and `bench_quit = true` to leave
the game when it ends).

For each pair it prints one table row, which ends up in the console's `default.log` (the
numbers below only show the format):

```
perf: | 50 | 500 | 30.0 | 29.4 | 9.87 | 3.21 | 8.0 | worst frame 34.01 ms
```

and it rewrites `perf_results.md` in the save folder after every pair (so a run that is cut
short keeps its rows): the run's description (platform, seed, level hash), the table below and
a second table with the worst frame, update and draw, the fixed steps per frame, the live
particles and the enemies in view. On PC the file is in LÖVE's save directory for the identity
`perf_platformer`. On the console it is in `save/` inside the game folder, as
`l360save_perf_results.md.a` and `.b` (the runtime's two slots: take the newer one; the last
line of each is the runtime's own check line).

Columns: **FPS avg** is frames over measured time; **FPS min** is 1 over the longest frame;
**Update ms** and **Draw ms** are averages per frame; **Draw calls** the average per frame.

Reading the numbers on the console:

- The runtime's loop is paced at 30 FPS ([docs/API_SUBSET.md](../../docs/API_SUBSET.md),
  `love.timer`), so FPS avg reads 30 when the frame fits and less when it does not. With the
  logic at 60 Hz a 30 FPS frame runs two fixed steps: Update ms is the time of both.
- Draw ms is the CPU time of `love.draw` (building the batches and handing them to the GPU), not
  the time the GPU takes to draw.
- The particles are simulated in C on the console; their `update` is inside Update ms.

## Console results

To be filled in by the owner from `perf_results.md` (console build, date and commit of the base
on the first line).

Build: 

| N enemies | Particles | FPS avg | FPS min | Update ms | Draw ms | Draw calls |
|---|---|---|---|---|---|---|
| 0 | 500 | | | | | |
| 0 | 1000 | | | | | |
| 0 | 2000 | | | | | |
| 50 | 500 | | | | | |
| 50 | 1000 | | | | | |
| 50 | 2000 | | | | | |
| 100 | 500 | | | | | |
| 100 | 1000 | | | | | |
| 100 | 2000 | | | | | |
| 200 | 500 | | | | | |
| 200 | 1000 | | | | | |
| 200 | 2000 | | | | | |

## The rule

**If the console does not hold a steady 60 FPS with 50 enemies and 500 particles, measure what
weighs most and propose what to move to C.**

While the runtime's loop is paced at 30 FPS, "holds 60 FPS" is read from the timings of the
`50 | 500` row: half of Update ms (one fixed step) plus Draw ms has to stay under 16.6 ms, with
no worst frame far above the average.

If it does not hold, find what weighs most before changing anything:

1. Compare rows. `0 | 500` against `50 | 500` gives the cost of 50 enemies; `500` against `2000`
   particles at the same N gives the cost of the particles; Update ms against Draw ms says which
   half of the frame it is in.
2. Inside the update, time the parts separately (wrap them with `love.timer.getTime` in
   `perf/actors.lua` and `perf/play.lua`): the controllers' `body:step` (bump's `world:move`,
   which creates tables on every call), the state machines, `combat.world:step`, the particle
   update, the camera.
3. Inside the draw: the actors' batch (one `SpriteBatch:add` per actor in view per frame), the
   room batches, the particles, the overlay.

Then propose the move to C for the part that weighs most, with the numbers. The likely
candidates, in the order to check them: the collision step (bump's cell grid and `world:move`),
the hitbox against hurtbox search of the combat world, and filling a SpriteBatch from an array
of positions in one call instead of one call per sprite.
