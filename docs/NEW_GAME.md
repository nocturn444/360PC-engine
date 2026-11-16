# A new game, from the template to the console

Step by step: a new game repository, running on PC, then built, packaged and installed on an
Xbox 360 with Aurora. Each step names the tool and the page with the details.

You need: LÖVE 11.x and LuaJIT on the PC; Python 3.8 or later; for the console build, the
requirements of [BUILDING.md](../BUILDING.md) (Linux or WSL, xsdk and its toolchain) and the
shader compiler of [SHADERS.md](SHADERS.md) (Windows, or Linux with `libxsc.so`).

## 1. Start the repository

```sh
mkdir my_game && cd my_game && git init
cp -r <360PC-Engine>/template/. .
git submodule add <360PC-Engine URL> base        # the base, at the version you choose
git -C base checkout <tag or commit>
```

The other way to hold the base (a pinned copy of `engine/` and `lib/`) is in
[template/README.md](../template/README.md). The commands below assume the submodule in
`base/`; with a pinned copy, run the same tools from your checkout of the base.

## 2. Make it yours

Edit `game.lua` ([GAME_CONFIG.md](GAME_CONFIG.md)):

- `name`: what Aurora shows.
- `identity`: the short name (also the default package folder).
- `title_id`: 8 hex digits, unique to this game, never changed after a release. It goes into
  the `.xex`.
- `default_font`: a TTF in the game folder, if the game draws text on the console.

Edit `conf.lua` (window title and identity for PC) to match. The game itself starts in
`main.lua` and `states/play.lua`; the engine's reference is [ENGINE.md](ENGINE.md) and the
genre modules are in `base/engine/modules/`.

## 3. Run on PC

```sh
love .
```

While developing, check the game against the console's API subset with
`tools/compat_check.lua` (copy it and `api_subset_data.lua` into the game folder and require
it first in `main.lua`: [API_SUBSET.md](API_SUBSET.md)), and run the console's boot without a
console:

```sh
luajit -joff base/tests/pc/boot_pc.lua .          # must end with "OK:"
```

## 4. Build the .xex with the game's Title ID

Once per game (and again when the base version or `game.lua`'s name or Title ID changes),
following [BUILDING.md](../BUILDING.md):

```sh
cd base
XSDK_TOOLCHAIN=~/xsdk-gcc bash toolchain/build_luajit_xsdk.sh        # once per base version
cmake -S runtime -B runtime/build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<xsdk>/cmake/xsdk.cmake -DXSDK_TOOLCHAIN=~/xsdk-gcc \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DL360_RELEASE=ON \
  -DGAME_TITLE_ID="$(luajit tools/read_game_config.lua .. title_id)" \
  -DGAME_NAME="$(luajit tools/read_game_config.lua .. name)"
cmake --build runtime/build
cd ..
```

The result is `base/runtime/build/game.xex`. One `.xex` per game: it carries the Title ID.

## 5. Compile the shaders

Every time a shader changes (and once even if the game has none: the engine's own four shader
files are needed by every game), following [SHADERS.md](SHADERS.md):

```bat
python base\tools\shaders\build_shaders.py . --tools C:\xost --out build\shaders
```

## 6. Package

```sh
python base/tools/package.py . --xex base/runtime/build/game.xex --shaders build/shaders --zip
```

This writes `dist/<identity>/`, the folder that goes on the console, and `dist/<identity>.zip`:

- `default.xex`, the game's files (without development files: dot files, `*.md`, `dist/`,
  `build/`, `tests/`, `tools/`, `docs/`, the `base/` submodule, saves, logs, art sources, `deploy.local.ini`);
- `engine/` (the core, plus the modules the game's Lua mentions) and the `lib/` libraries it
  uses, with their licenses;
- `l360/` (the runtime's Lua) and `shaders/` (the compiled shaders);
- `package_manifest.txt` (sizes and CRC-32, used by the installer).

Useful options: `--dry-run` lists the files and writes nothing; `--exclude PATTERN` leaves
more out; `--module NAME` / `--lib NAME` add a module or library the scan did not see (one
required through a computed name); `--extra FILE[=DEST]` adds a file such as a console check;
`--no-xex` and `--no-shaders` package only the rest (to update the game's files quickly). The
script stops if `game.lua` is not valid or has no Title ID, if the `.xex` is not one, or if
the shader folder lacks the engine's files or a declared shader. It warns when `game.lua` has
`debug = true`.

## 7. Install over FTP

Steps 4 to 8 can run as one command, `python base/tools/deploy.py .`, with the console's
address and the tool paths in a local `deploy.local.ini`: [DEPLOY.md](DEPLOY.md).

With the console on, Aurora running and its FTP server enabled (Aurora shows the console's IP;
the default user and password are `xboxftp` / `xboxftp`):

```sh
python base/tools/install_ftp.py dist/my_game --host 192.168.0.20 --dry-run     # what would go
python base/tools/install_ftp.py dist/my_game --host 192.168.0.20
```

The default target is `Hdd1:/Games/<package folder name>/`; change it with
`--target Usb0:/Games/my_game`. The host, port, user, password and target can also come from
`X360_FTP_HOST`, `X360_FTP_PORT`, `X360_FTP_USER`, `X360_FTP_PASSWORD` and `X360_FTP_TARGET`.

Only files that changed are uploaded (same size, and the same CRC-32 as the manifest the last
install left on the console); `--force` uploads everything. Nothing on the console is deleted
or renamed, and `save/` (the game's `save_dir`) and `default.log` are never touched. Files on
the console that are no longer in the package are listed and left alone: remove them by hand
if they matter.

Without a network, copy `dist/<identity>/` to a USB drive (or unpack the zip there).

## 8. Launch from Aurora

In Aurora, make sure the folder you installed to is in a scan path (Settings, Content, Scan
Paths: for example `Hdd1:\Games`), scan, and the game appears under its `name`. Or open
`default.xex` from Aurora's file manager. On a Bad Update console, run the exploit and open
Aurora first.

- Hold Back for 3 seconds to leave the game.
- The log is `<folder>\default.log`; saves are in `<folder>\save\`. Fetch the log with any FTP
  client when something goes wrong.

## Debug mode

`engine.debug` ([ENGINE.md](ENGINE.md)) gives a development build a seed display and entry, a
list that grants modifiers, and a hitbox overlay. It is off unless `game.lua` has
`debug = true` (or the game enables it itself). Remove the flag before packaging a release;
`package.py` warns while it is set.

## Seed validation and the level hash test (games with procedural levels)

A game that generates levels with `engine.modules.procgen` writes a small spec module, for
example `level_spec.lua` next to `main.lua`, returning what it generates with:

```lua
return {
  templates = require("rooms"),            -- or a function returning them
  abilities = { "dash", "double_jump" },
  rooms = 16,
  check = function(map) return true end,   -- optional: the game's own rule
  -- stream = "level",                     -- the engine.rng stream levels use (the default)
}
```

**Bulk validation on PC.** Generate many seeds and look for failures:

```sh
luajit base/tools/seed_validator.lua . level_spec --count 10000
```

It prints each seed that gave no map (with its seed code and the reason), how many attempts
the others took, and one hash of the whole list. It exits with 1 if any seed failed.

**PC vs 360.** The same seed must give the same level on both. To check it on hardware:

1. On PC, write a hash list (a few hundred seeds take seconds on PC; the console's
   interpreter is much slower, so start with 200):
   `luajit base/tools/seed_validator.lua . level_spec --count 200 --out build/level_hashes.txt`
2. Check the check itself on PC:
   `luajit -joff base/tests/console/level_hash_check.lua . build/level_hashes.txt`
   must end with `== level hashes: 0 of 200 wrong ==`.
3. Add `require("level_hash_check")` as the first line of `main.lua`, and package with the
   check and the list:
   `python base/tools/package.py . --xex ... --shaders ... --module procgen --extra base/tests/console/level_hash_check.lua --extra build/level_hashes.txt`
4. Install, start the game on the console, and read `default.log`. Every seed whose hash or
   number of attempts differs is logged as `[BAD] seed N: got ..., expected ...`, and the
   last line must be `== level hashes: 0 of 200 wrong ==`.
5. Remove the `require` line and package again without the two `--extra` files.

A mismatch means the generation depends on something that differs between the two LuaJIT
builds: look for `math.random`, `pairs()` order, or floating point in the game's `check` or
templates first ([ENGINE.md](ENGINE.md), "engine.rng", "What not to do").

## Updating the base in a game

`git -C base fetch && git -C base checkout <new tag or commit>`, commit the submodule pointer,
then rebuild the `.xex` and the shaders (steps 4 and 5), package and install. With a pinned
copy, replace the game's `engine/` and `lib/` with the new version's and do the same. Run the
game on PC and `boot_pc.lua` before installing.
