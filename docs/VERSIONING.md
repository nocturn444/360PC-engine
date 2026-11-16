# Versioning

360PC-Engine uses [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`. The current
version is in three places that always agree, as `tests/engine/engine_test.lua` checks:

- `VERSION`, at the repository root;
- `engine._VERSION`;
- the newest release in [CHANGELOG.md](../CHANGELOG.md).

## What the version promises

The public surface is what a game touches:

- the `engine/` and `engine/modules/` functions and fields documented in `docs/ENGINE.md` and the
  module READMEs;
- the `game.lua` fields (`docs/GAME_CONFIG.md`);
- the console's LÖVE subset (`docs/API_SUBSET.md`);
- the save file format, the level file format and the layout hash;
- the command lines of the tools in `tools/`.

| Change | Version |
|---|---|
| A fix that keeps the public surface and every saved or generated result | PATCH |
| Something new that leaves every existing game working | MINOR |
| A game has to change: an API removed or changed, a `game.lua` field renamed, the same seed now giving another map or other loot, or a save or level file needing migration | MAJOR |

Determinism is part of the surface. A change to `engine.rng`, `procgen` or `items` that gives
other results for the same seed is a major change, even when no function changes. Players' seeds
and saved runs depend on those results, and so do the known answers in `tests/console/`.

**Before 1.0.0, the minor number acts as the major one.** 0.2.0 may break 0.1 games; 0.1.1 may not.
`engine.requires` follows that rule.

## In a game

A game pins the base at a tag: a submodule checked out at `v0.1.0`, or a pinned copy. It can then
state the version it was written for, first thing in `main.lua`:

```lua
local engine = require("engine").requires("0.1")   -- stops with a clear error on 0.2 or 0.0
```

## Releasing (done by the owner)

1. Merge the release's work into `main`.
2. In `CHANGELOG.md`:
   - move `[Unreleased]` into a new `## [x.y.z] - YYYY-MM-DD` section;
   - set `VERSION` and `engine._VERSION` to the same number;
   - run `luajit -joff tests/engine/run.lua`.
3. Commit, then tag that commit on `main`, with an annotated tag:
   `git tag -a vx.y.z -m "360PC-Engine x.y.z"`, then `git push origin vx.y.z`.
4. Test the tagged build on the console (`tests/console/` checks and `examples/perf_platformer`)
   before announcing it.

Tags are only made on `main`, never on a work branch. The `0.1.0` entry is ready, but the tag
waits for the owner's merge.
