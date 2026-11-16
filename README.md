# 360PC-Engine

A reusable base for original 2D homebrew games that run on:

- **PC**, with the official [LÖVE](https://love2d.org/) 11.x.
- **Xbox 360**, as a `.xex` launched from Aurora (Bad Update), with a C runtime
  built on [xsdk](https://github.com/xenosworks/xsdk) over the Xenos GPU.

Each game lives in its own repository and uses this base, either as a git
submodule or as a pinned copy of a released version. The base is not tied to
any genre: genre-specific code lives in optional modules.

The console runtime starts from the one in
[Love360](https://github.com/nocturn444/love360-xbox360) (commit `e46bc8f`),
copied here and made generic.

## Status

Early development. Nothing is released yet. The roadmap is in
[docs/ROADMAP.md](docs/ROADMAP.md).

## Start a game

[docs/NEW_GAME.md](docs/NEW_GAME.md) goes from `template/` to the game running on PC and on
the console: build the `.xex` with the game's Title ID ([BUILDING.md](BUILDING.md)), compile
the shaders ([docs/SHADERS.md](docs/SHADERS.md)), package (`tools/package.py`), install over
FTP (`tools/install_ftp.py`) and launch from Aurora. The tools are listed in
[tools/README.md](tools/README.md), the engine layer in [docs/ENGINE.md](docs/ENGINE.md) and
the tests in [tests/README.md](tests/README.md). The performance test, with the table for the
console's measurements, is [examples/perf_platformer](examples/perf_platformer/README.md).

## Layout (planned)

| Path | What it is |
|---|---|
| `runtime/` | C runtime on xsdk; builds the `.xex`. Same code for every game. |
| `engine/` | Generic engine layer in Lua. |
| `engine/modules/` | Optional modules per genre (e.g. tilemap and collisions for platformers). |
| `lib/` | Third-party Lua libraries, each with its LICENSE. |
| `tools/` | Shader build, packaging, FTP installer, seed validator, `compat_check`. |
| `template/` | Minimal project to start a new game. |
| `examples/perf_platformer/` | Example and performance test ([README](examples/perf_platformer/README.md)). |
| `docs/` | Documentation. |
| `tests/` | PC tests (including fake xsdk GPU and audio). |

Rule: nothing in `engine/` or `runtime/` may depend on a specific game.
Anything game-specific goes in the game's configuration.

## Constraints

- No Vulkan, no SDL, no official or leaked XDK. Graphics go through xsdk on the
  Xenos GPU.
- New code, identifiers, logs and documentation are in English.

## Contributing

`main` holds what has been built and tested on the console. Work happens in
branches, one pull request per objective. The owner tests on the console and
decides every merge to `main`.

## License

MIT, see [LICENSE](LICENSE). Third-party notices will be collected in
`THIRD_PARTY_NOTICES.md` as components are added.
