# Changelog

All notable changes to 360PC-Engine. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) as described in [docs/VERSIONING.md](docs/VERSIONING.md).
`VERSION`, `engine._VERSION` and the newest release below always agree (checked by
`tests/engine/engine_test.lua`).

## [Unreleased]

### Added
- `engine.pixelgrid`: shapes rasterized each frame into a small colour grid and drawn as
  pixel-aligned cells in one draw call.

### Changed
- `engine.pixel` uses `"direct"` mode by default on PC too, so PC shows what the console shows.
  `"canvas"` is still available on PC when asked for.
- The camera's `snap` is on by default.

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
