# template/

The smallest game on 360PC-Engine: copy this folder to start a new game repository. The full
walkthrough, from this folder to the game running on the console, is
[docs/NEW_GAME.md](../docs/NEW_GAME.md).

| File | What it is |
|---|---|
| `game.lua` | The per-game config: name, Title ID, save folder ([docs/GAME_CONFIG.md](../docs/GAME_CONFIG.md)). Change every value. |
| `conf.lua` | LÖVE's window settings for PC. |
| `main.lua` | `engine.run` with the fixed timestep, the pixel resolution, the input actions and the states. |
| `states/play.lua` | One example state: a square moved with the keyboard or the controller. |
| `.gitignore` | Build and packaging output, saves, logs. |

## Where the base lives

A game uses a fixed version of the base. Pick one:

- **Git submodule** (recommended): `git submodule add <360PC-Engine URL> base`, then check out
  the version you want inside `base/`. `main.lua` already adds `base/` to LÖVE's require path
  on PC, and the tools are run as `base/tools/...`. Update with `git -C base fetch` and
  `git -C base checkout <tag or commit>`, then commit the new submodule pointer.
- **Pinned copy**: copy the base's `engine/` and `lib/` folders into the game folder (and keep
  a checkout of the same base version somewhere for the tools and the runtime). Write the
  version you copied in your README. Update by replacing both folders.

`tools/package.py` handles both: it leaves `base/` out of the console folder and adds the
base's `engine/`, `lib/` and runtime files, or ships the game's own `engine/` and `lib/`
when it has them.

## Run it

```sh
love .                                                    # PC, official LÖVE 11.x
luajit -joff base/tests/pc/boot_pc.lua .                  # the console's boot on PC, without a GPU
```

(With the pinned copy, run `boot_pc.lua` from the base checkout with the game folder as its
argument.) In this repository: `luajit -joff tests/pc/template_test.lua`.
