# Changelog

All notable changes to 360PC-Engine. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) as described in [docs/VERSIONING.md](docs/VERSIONING.md).
`VERSION`, `engine._VERSION` and the newest release below always agree (checked by
`tests/engine/engine_test.lua`).

## [Unreleased]

### Added
- `engine.init` / `engine.run`: optional `autopause = { state, controller, focus }` pushes a
  pause state when the gamepad in use is disconnected or the window loses the focus, with the new
  `controllerlost(joystick)` and `controllerback(joystick)` hooks; a state can opt out with
  `autopause = false`. `examples/rooms` has a pause menu (Resume, Restart run, Quit game) that
  pauses its audio and shows when the controller is disconnected or back.
- `.github/workflows/opencode.yml`: run opencode from `/opencode` comments or a manual run,
  owner only, always on a branch with a pull request ([docs/OPENCODE_CI.md](docs/OPENCODE_CI.md)).
- `engine.pixelgrid`: shapes rasterized each frame into a small colour grid and drawn as
  pixel-aligned cells in one draw call.
- `engine/modules/softbody`: a soft body (points on a ring, springs and pressure) that falls,
  rolls and squashes against a tile grid, with an outline for `engine.pixelgrid`; and
  `examples/slime`, a slime made with both.
- `engine/modules/rooms`: a procgen map played room by room (exits, doors, arrival points,
  locks, explored rooms, save state) and fade or slide transitions; `examples/rooms` walks a
  generated map with them.
- `engine.text`: a built-in 3 x 5 pixel font drawn with rectangles, so overlays show text on
  the console without a TTF.
- `engine.tune`: live tuning of numbers with an overlay, the controller and a saved file;
  `examples/slime` tunes its body and controls with it.
- `softbody`: `width` / `height` for long bodies and `shape` to keep them lying down;
  `set_velocity` and `softbody.box`, a box that lets combat (fighters, knockback,
  behaviour targets) work with a soft body; `examples/rooms` adds enemies with patrol / chase /
  attack, stomps, health and respawn.
- `tools/deploy.py`: build, shaders, package, FTP upload and optional XBDM launch in one
  command, with the console's settings in an untracked `deploy.local.ini` (docs/DEPLOY.md).
- `tools/deploy_android.py`: from a phone or tablet that cannot build the `.xex`, pulls the
  branch, downloads the newest successful "Console build" artifact with the GitHub CLI (`gh`)
  and uploads it with `install_ftp.py`, sending only changed files.
- `combat.attacks`: attacks as data on top of a combat world: melee sweeps through a list of
  boxes (arcs, stabs, areas), ranged shots (fans, gravity, piercing, walls, lifetime) and
  explosive bombs (placed or thrown, bounces, fuse or contact, radius with falloff and radial
  knockback), with windup and cooldown, pooled so a warm step allocates nothing;
  `examples/rooms` gives the slime the three kinds, switched with a button.
- `engine.audio`: sound effects and music as data, with a few voices per effect, pitch and
  volume variation from its own generator, a minimum gap between plays, music crossfades,
  volume buses (`master`, `music`, `sfx` or the game's own) that can be saved, and pause /
  resume; it stays inside the console's audio subset and allocates nothing per play.
- `tools/audio_convert.py`, called by `tools/package.py`: the game keeps `.ogg` for the PC and
  the console package gets mono WAV files instead (16-bit PCM for short effects, IMA ADPCM for
  long ones, music split into streamed IMA ADPCM chunks with an `.idx`), cached between runs;
  settings in `game.lua`'s new `audio` table. Needs ffmpeg.
- `tools/level_editor`: an interactive level editor made with LÖVE for the level file of
  `engine.level`. It covers collision, doors and their abilities, the item, entities with
  fields, rooms (add, copy, delete, order, type, tags, weight, size), live checks, undo, and a
  play test with a platformer body. `level_editor.bat` opens it on Windows.
- `tools/room_editor_web`: the data layer of a touch-friendly web room editor, in plain
  JavaScript with no dependencies or build step. `SaveFmt` reads and writes the level file
  byte-identically to `engine/save.lua`, and `RoomModel` edits rooms, collision, doors, the
  item, entities, props (not entities) and biomes, with undo/redo, checks, filters, grouping
  and importing rooms from another file. The UI comes in part 2.
- `procgen.biomes`: the run's path through biomes of 1 to 3 floors, fixed (first, last, a
  floor) or variable (by weight, unlocked, or depending on the run), read by `procgen.floors`
  (templates, room types, room count, difficulty); `items` entries can be limited to biomes;
  `examples/rooms` has six biomes with their enemies, colours and music, and a treasure item.
- `procgen`: `branching` (0 to 1, default 0.5) makes the filler rooms avoid the gaps between
  rooms already placed, so a floor spreads into branches instead of a compact block; it is
  accepted by `procgen.generate`, `procgen.floors` and `procgen.seeds`. `examples/rooms` adds
  vertical and junction rooms (cross, shaft, T, corners) and opens up/down doors, so generated
  floors branch in both directions.
- `examples/rooms`: boss and miniboss rooms seal their doors until their enemies are dead, and
  every room remembers its enemies (the dead stay dead and a hurt one keeps its health).
- `procgen.roomtypes` and `procgen.floors`: special room types as modular data (count, chance,
  floors, distance from the start, minimum depth), with an Isaac-like default set (treasure,
  shop, miniboss). Special rooms are placed by the generator as dead ends (`specials`), and the
  boss can go far from the start (`boss_distance`). A run of floors grows from floor to floor
  (rooms, special rooms, templates by floor). `examples/rooms` is now a ten-floor run with
  stairs after each boss.
- `procgen.roomtypes`: `chance` and `count` functions receive the game's `run` table (so a
  chance can depend on what happened earlier in the run), `replaces` turns another type off on
  a floor, and `max` caps a type's count; `procgen.floors` passes the run through.
- `run_pc.bat`: double-click to update the repository and open a game on the PC with LOVE.
- `engine/modules/wallet`: a small bag of named integer currencies for a run (`virus` in the
  example), with add/can/spend, no negative amounts, and plain-data state for a run save.
- `examples/rooms`: six run stats (`luck`, `jump`, `speed`, `damage`, `shield`, `health`) built
  on `engine.modifiers`; attacks scale with `damage`; the shield absorbs damage and refills after
  `5 + 2.5 * capacity` seconds without a hit; boss/miniboss clears give a mutation.
- `examples/rooms`: content pools for mutations and consumables with source, mob, biome, floor,
  room and build filters, synergy weights, unique/stackable entries, deterministic per-room and
  per-enemy streams, and luck on drop chances.
- `examples/rooms`: a normal heart, virus pickups, breakable crates that can drop virus, a room
  clear virus chance, and a test machine with `accepts_money` (a healer bought with the interact
  action, one use per machine).
- `examples/rooms`: cosmetic mutations (colours, eyes, shape, limbs) and optional physical rest
  shapes; `softbody` gains `Body:set_rest_shape` for mutations that change the body and hitbox.
- `examples/rooms`: casino machines in `rooms_casino.lua`: a single-use genetic lottery that can
  give or take a mutation (gain chance from luck) and a slot machine that spends virus for a
  weighted prize, each keeping its own persistent state.
- `examples/rooms/docs/`: `STATS.md`, `CONTENT.md`, `ECONOMY.md` and `COSMETICS.md` (the prototype's
  systems; the numbers in them are examples pending the owner's design decisions).
- `examples/rooms`: `rooms_spawn.lua`, the spawn rules of the new special rooms (casino, super
  treasure, pact, trap, obstacle) as data and pure functions, plus the per-floor run state
  (casino, trap, obstacle, treasure skipped) they read. Not wired into the map yet.
- `examples/rooms`: bonus keys (`bonus_key`, a pale cyan `KEY+` pickup) for optional locks, a
  separate `bonus_keys` content pool with a `0.05` mob roll scaled by luck, and the `bonus_key`
  currency in the run wallet; its first use is the super treasure room.
- `examples/rooms`: `rooms_minimap.lua` draws the run's minimap from `nav:minimap()`, with a
  white outline around the current room and data-driven pixel icons for the special room types.
- `examples/rooms`: `rooms_pacts.lua`, the pact room's mutualist larvae (one heart slot for one
  mutation), and `stats:add_permanent` for the permanent health cost, saved with the run.
- `examples/rooms/rooms_shop.lua`: shop stock drawn once per room from the content pools with a
  virus price, buying that spends and marks an offer sold and takes it from its pool, the
  treasure / super treasure pedestal positions, and an optional offer draw.

### Changed
- `examples/rooms`: Escape (and P / Start) now pauses with the new menu instead of quitting on
  PC; on the console, holding Back still quits.
- `engine.pixel` uses `"direct"` mode by default on PC too, so PC shows what the console shows.
  `"canvas"` is still available on PC when asked for.
- `procgen` maps generated from a seed are different now because `branching` defaults to 0.5;
  pass `branching = 0` for the old uniform layout. The known answers in
  `tests/console/procgen_check.lua`, the engine tests and the level hash procedure were updated.
- The camera's `snap` is on by default.
- `examples/rooms` no longer uses `rooms_items.lua`: the treasure room holds one mutation from
  `rooms_content.lua`, and the old item bonuses were replaced by the stats system. The run's
  treasure draws use the new named streams, so they differ from the previous build.
- `tools/install_ftp.py`: a first install no longer runs `LIST` on an empty folder (Aurora's
  `LIST` hangs there); it compares sizes with `SIZE` instead. `--safe` opens a fresh connection
  for every file and checks its size, for Aurora FTP servers that mix consecutive transfers. This
  safe mode is now the default (also for `deploy.py`); `--fast` keeps one connection.
  `tools/deploy_android.py` warns when the build it installs is older than the branch's last commit.

### Fixed
- `examples/rooms`: an enemy that falls through a pit now moves to the room below, keeping its
  health, instead of vanishing and respawning at its spawn spot. Past an edge with no door it
  dies, without counting as a kill or dropping anything.
- `engine.ui` draws its text with the theme's font: a new `engine.text.font(scale)` adapter
  measures, wraps and draws with the built-in rectangles, so menus show text on the console
  without `default_font`; `examples/rooms` uses it for its pause menu.
- `examples/rooms`: the "controller disconnected" message has a fixed width, so an auto-pause
  no longer stretches the pause menu and its buttons off the screen.

## [0.1.0] - not tagged yet

The first version of the base, objectives 1 to 19 of [docs/ROADMAP.md](docs/ROADMAP.md).

### Added
- Console runtime on xsdk (C), started from Love360: a LÖVE 11 subset with one `.xex` per game,
  the Title ID and name taken from `game.lua`, precompiled shaders, a SpriteBatch, text, shapes,
  `love.timer`, the gamepad API, a ParticleSystem subset and the `alpha`/`add` blend modes
  (objectives 1 to 4b).
- `docs/API_SUBSET.md` and `tools/compat_check.lua`, to see on PC what a game uses that the console
  lacks (objective 5).
- `engine/`:
  - state machine, fixed timestep, action input, camera, pixel-art pipeline, layered sprites and
    anim8 animations (objective 6);
  - entities and data modifiers (objective 7);
  - seeded rng with named streams, the same on PC and console (objective 8);
  - saves for the run in progress and the permanent progress (objective 9);
  - controller-first UI with pick 1 of N (objective 10).
- LDtk levels: a converter and `engine.level` (objective 11).
- `engine/modules/`:
  - `platformer` (objective 12);
  - `combat` (objective 13);
  - `procgen` (objective 14);
  - `items` (objective 15).
- `lib/` rules and `tools/check_libs.lua` (objective 16).
- `template/`, packaging, the FTP installer, debug mode, the seed validator, the level hash check
  and `docs/NEW_GAME.md` (objective 17).
- `examples/perf_platformer`, the performance test (objective 18).
- This changelog, `VERSION`, `engine.requires` and `docs/VERSIONING.md` (objective 19).

[Unreleased]: https://github.com/nocturn444/360PC-Engine/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/nocturn444/360PC-Engine/releases/tag/v0.1.0
