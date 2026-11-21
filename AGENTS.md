# AGENTS.md: rules for AI agents working on 360PC-Engine

Read this whole file before changing anything. It applies to every AI agent (DeepSeek, Codex,
Gemini, Claude, ...). If something here conflicts with what the owner says in the current
conversation, the owner wins. If something is ambiguous or a choice has design consequences,
**stop and ask the owner** instead of guessing.

## 1. What this repository is

A reusable, genre-agnostic base for original 2D homebrew games that run on:

- **PC**: official LÖVE 11.x, no build step.
- **Xbox 360**: a `.xex` launched from Aurora, with a C runtime on
  [xsdk](https://github.com/xenosworks/xsdk) over the Xenos GPU, running the game's Lua on
  LuaJIT **in interpreter mode** (no JIT on the console).

The same game folder (`main.lua`, `conf.lua`, `game.lua`, assets) runs on both. The first game
built on it is a pixel-art platformer roguevania (hand-made rooms joined procedurally, per-run
mutations, permanent progress). Its prototype currently lives in `examples/rooms/`. The base
itself must stay generic.

Owner: Mateo (GitHub `nocturn444`). He speaks Spanish: **explain things to him in Spanish**,
briefly. Code, identifiers, comments, logs, commit messages and docs are **in English**.
No emojis in text.

## 2. Module map

| Path | What it is |
|---|---|
| `runtime/` | C runtime on xsdk (`main.c`, `l360_gfx.c`, `l360_audio.c`, `l360_particles.c`, `l360_sys.c`), builds the `.xex`. Same code for every game. [runtime/README.md](runtime/README.md) |
| `runtime/lua/` | The LÖVE layer that runs on the console (`boot.lua`, `config.lua`, `input.lua`, `save.lua`, `l360_gfx_stub.lua`). Shipped as `l360/` in the game folder. |
| `runtime/shaders/` | The engine's own HLSL shaders. |
| `engine/` | Generic engine layer in Lua: state, timestep, input, camera, pixel, pixelgrid, layers, entity, modifiers, rng, save, level, ui, text, audio, tune, anim, debug. [engine/README.md](engine/README.md), reference in [docs/ENGINE.md](docs/ENGINE.md). |
| `engine/modules/` | Optional genre modules: `platformer`, `combat` (incl. `attacks`), `procgen` (graph, templates, roomtypes, floors, biomes, seeds, reach), `items`, `wallet`, `softbody`, `rooms`. [engine/modules/README.md](engine/modules/README.md) |
| `lib/` | Third-party Lua libraries (`anim8`, `bump`), pinned, each with its LICENSE. |
| `tools/` | Packaging, FTP install, deploy, shader build, LDtk converter, level editor, seed validator, `compat_check`, `check_libs`, `gen_api_subset`. [tools/README.md](tools/README.md) |
| `tools/ci/build_console.sh` | The whole console build on Ubuntu (used by CI). |
| `template/` | Minimal project to start a new game. |
| `examples/` | `engine_demo`, `perf_platformer` (performance test), `slime` (soft body), `rooms` (generated map, enemies, attacks, floors, biomes: the game prototype). |
| `tests/` | PC tests and console checks. [tests/README.md](tests/README.md) |
| `toolchain/` | Scripts and patch to build LuaJIT for xsdk. |
| `docs/` | Documentation: `ROADMAP`, `ENGINE`, `API_SUBSET`, `GAME_CONFIG`, `LEVELS`, `LEVEL_EDITOR`, `SHADERS`, `NEW_GAME`, `DEPLOY`, `CLOUD_BUILD`, `VERSIONING`, `STATS`, `CONTENT`, `ECONOMY`, `COSMETICS`. |

## 3. Hard rules (do not break)

1. **Engine vs game boundary.** Nothing in `engine/` or `runtime/` may depend on a specific
   game. Genre code goes in `engine/modules/<name>/` (and a module knows nothing about a game);
   game-specific content (rooms, enemies, attacks, items, biomes, balance numbers) goes in the
   game's folder (today `examples/rooms/`), as data. Do not hard-code game names, Title IDs or
   assets in the base.
2. **Only the console's LÖVE subset.** The console implements only what
   [docs/API_SUBSET.md](docs/API_SUBSET.md) lists. Anything else logs `[missing] <name>` and
   does nothing there. Do not use LÖVE functions outside that list in `engine/`, modules,
   examples or `lib/`. `docs/API_SUBSET.md` is **generated**: never edit it by hand; change the
   runtime or `tools/api_subset_notes.lua` and run `luajit tools/gen_api_subset.lua`.
3. **Plain Lua 5.1** in all Lua code: no FFI, no `goto`, no `jit.*`, no Lua 5.2+ features.
4. **No per-frame allocation** in engine and module update/draw paths (no new tables or
   closures per frame or per step). Tests check this for several modules.
5. **Determinism.** Random numbers only through `engine/rng.lua` streams (never
   `math.random`/`love.math.random` in generation or gameplay). Same seed must give the same
   result on PC and console; known-answer checks in `tests/console/` must stay at 0 wrong.
6. **No JSON parsing on the console.** Levels are made in LDtk and converted on PC at build
   time (`tools/ldtk_convert.py`) into the engine's `.lvl` text format (the `engine/save.lua`
   format) that `engine/level.lua` reads. The level editor (`tools/level_editor/`, PC only)
   edits `.lvl` directly.
7. **Performance target: 30 FPS** on console and PC (decided 2026-11-16, may be revisited).
   Keep `examples/perf_platformer` working; if something is too slow in Lua, measure and
   propose moving it to C, do not just do it.
8. **Pixel art:** `engine/pixel.lua` in `"direct"` mode by default, positions rounded to the
   game pixel grid (camera `snap` on by default, `pixel.snap`). Small canvases in C are
   deferred: do not add them without the owner's approval.
9. **Audio:** `.ogg` on PC; at packaging `tools/package.py` converts them with
   `tools/audio_convert.py` (ffmpeg) to mono PCM / IMA ADPCM WAV, music as streamed ADPCM
   chunks with an `.idx`. Settings in `game.lua`'s `audio` table.
10. **One `.xex` per game**, with the Title ID and name from that game's `game.lua`. A Title ID
    is never changed after release (it would split saves).
11. **No Vulkan, no SDL, no official or leaked XDK.** Graphics go through xsdk only.
12. **Console C constraints:** no thread-local storage (`__thread`, `thread_local`), no `mcrxr`
    (LuaJIT built with `-D PPE`), `main.c` first in the link. See `runtime/README.md`.
13. **Licenses:** the project is MIT. Any third-party code goes in `lib/` (or
    `runtime/third_party/`) with its license file, a row in `lib/README.md` and an entry in
    `THIRD_PARTY_NOTICES.md`; `luajit tools/check_libs.lua` must pass. Never copy code with an
    incompatible license, and never add content from commercial games.
14. **Love360 repositories** (`nocturn444/love360`, `nocturn444/love360-xbox360`) are
    **read-only references**: never commit, branch or open PRs there.

## 4. Workflow

- **Never push to `main` directly.** One branch and one pull request per objective or topic,
  small and focused. Branch names: `<agent>/<topic>` (e.g. `deepseek/shop-room`).
- A PR description says: what changed, why, how to test it on PC, what to test on the console,
  and known risks. If you could not run something (tests, console build), say so plainly.
- **Stacked PRs** are allowed while earlier ones are not merged: base the new branch on the
  previous one and say so in the PR. Merge with merge commits, not squash.
- The owner decides every merge to `main` (an agent merges only when he explicitly says so in
  that conversation).
- **Keep CI green.** A push to `main` (except Markdown and `docs/` only) triggers the console
  build; a red run means the owner cannot get a `.xex`.
- **Do not touch** `.github/workflows/`, `tools/ci/`, `tools/package.py`,
  `tools/audio_convert.py`, `tools/shaders/`, `toolchain/`, `runtime/XSDK_VERSION`,
  `run_pc.bat` or `deploy_console.bat` without a clear reason stated in the PR. These are the
  owner's only path to the console.
- Do not commit build output (`build/`, `dist/`, `*.xex`, `*.psu`, `*.vsu`) or local settings
  (`deploy.local.ini`). Never commit secrets.
- When you add or change behaviour, update the docs in the same PR (`docs/ENGINE.md`, the
  module's `README.md`, `tests/README.md`, `CHANGELOG.md` under `[Unreleased]`). Versioning
  rules: [docs/VERSIONING.md](docs/VERSIONING.md); `VERSION`, `engine._VERSION` and the
  changelog must agree.

## 5. Running and testing

On PC (from the repository root; needs LuaJIT and Python 3; ffmpeg for audio conversion):

```sh
love examples/rooms                          # run a game on PC (LÖVE 11.x); run_pc.bat on Windows
luajit -joff tests/engine/run.lua            # engine + modules, must end with "OK:"
luajit tests/engine/run.lua                  # same with JIT on, must end with "OK:"
luajit -joff tests/pc/boot_pc.lua            # console boot on PC, "OK:"
luajit -joff tests/pc/rooms_example_test.lua # the game prototype, "OK:"
luajit -joff tests/pc/<other>_test.lua       # slime, template, perf_platformer, level_editor, ...
luajit tests/pc/check_libs_test.lua
luajit tools/check_libs.lua
luajit tools/gen_api_subset.lua --check      # API_SUBSET.md up to date
python3 -m unittest discover -s tests/tools
python3 -m unittest discover -s tests/shaders
luajit -joff tests/console/rng_check.lua     # also procgen_check, items_check: "0 of N wrong"
```

The full list with what each test covers is in [tests/README.md](tests/README.md). Run the
tests that cover what you touched before opening a PR, and report the results in it. Tests use
a fake `love` (`tests/engine/fake_love.lua`); when you add a module or feature, add tests in
the same style. When the console checks' known answers change, explain why in the PR: it means
the console will generate different levels.

`-joff` matters: the console runs LuaJIT without JIT, so tests run in interpreter mode.

## 6. Console build and deploy

- The owner's PC is currently unavailable, so **the console build runs on GitHub Actions**:
  `.github/workflows/console.yml` + `tools/ci/build_console.sh`
  ([docs/CLOUD_BUILD.md](docs/CLOUD_BUILD.md)). Manual run: Actions, "Console build", "Run
  workflow", pick branch and game folder (default `examples/rooms`). Pushes to `main` build
  `examples/rooms`. First run on a branch without cache takes about an hour (toolchain), later
  runs a few minutes. The repo is private: runs cost Actions minutes, do not trigger them
  needlessly.
- The result is the artifact `<identity>-console` (zip of the game folder with
  `default.xex`). The owner downloads it on his phone, unzips it and uploads it with an FTP app
  over home Wi-Fi to `Hdd1:/Games/<identity>/`, then launches it from Aurora. The cloud cannot
  reach the console's FTP.
- The console log is `default.log` in the game folder; ask the owner for it when debugging.
- Local alternatives (when a PC is available): [BUILDING.md](BUILDING.md),
  [docs/DEPLOY.md](docs/DEPLOY.md) (`tools/deploy.py`), `deploy_console.bat`.
- Console tests cost the owner time: test everything you can on PC first.

## 7. Coding style

- Follow the style of the surrounding code: modules return a table, `local` everything,
  constructors like `module.new(opts)` with options as data tables, small focused files.
- Configuration and content are data (Lua tables), validated with clear error messages that
  name the offending field.
- Python tools use the standard library only and must work on Windows and Linux.
- Keep comments short and in English. Do not reformat files you are not changing.

## 8. Decisions already made (do not reopen without the owner)

- Game config is `game.lua`, a data-only table ([docs/GAME_CONFIG.md](docs/GAME_CONFIG.md)).
- Input on the console: LÖVE gamepad API (the pad is an Xbox controller); no key emulation.
- Console shaders are compiled at build time and shipped precompiled ([docs/SHADERS.md](docs/SHADERS.md)).
- Level editor format: LDtk, converted to Lua-readable `.lvl` on PC; plus the own editor.
- Room transitions: only the current room loaded, camera scrolls inside it, short fade at doors.
- Procedural floors Isaac-style: modular room type registry (shop, miniboss, treasure, ...),
  about 10 floors per run, each bigger than the last; biomes span 1 to 3 floors, some fixed
  (first and last), others random, unlockable or run-dependent.
- Player: a round soft-body slime (spring-chained points) rasterized each frame with
  `engine.pixelgrid` (no sprite); body colour `0.98, 0.90, 0.52`. Some enemies use sprites.
- Attacks: melee, ranged and explosive, defined as data (`combat.attacks`).

## 9. Open questions (ask the owner, do not decide alone)

- The real attacks, enemies and items of the game (current ones in `examples/rooms/` are
  examples).
- What scales per floor besides size (enemies, ability locks, rooms) and what the shop does.
- How the own level editor relates to LDtk long term (painting tiles is not done yet).
- Whether WAV size is a problem on the console.
- When to tag `v0.1.0` (after console tests) and when the first game moves to its own repo.

## 10. When in doubt

Read the relevant doc in `docs/` and the module's `README.md`, look at the tests, and ask the
owner. Prefer a small, tested, clearly described PR over a large one.
