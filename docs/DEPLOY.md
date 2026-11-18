# Deploy to the console in one command

`tools/deploy.py` runs the whole chain for a game: build the `.xex`, compile the shaders,
package, upload over FTP and, if asked, start the game.

```bat
python base\tools\deploy.py .
```

It only calls the tools described step by step in [NEW_GAME.md](NEW_GAME.md) (sections 4 to 8),
so everything there still applies; this page covers what the wrapper adds.

## Double-click on Windows

`deploy_console.bat`, at the root of the base, does everything without typing commands:

1. Updates the repository with `git pull` on the branch named at its top (`BRANCH`). If there
   are uncommitted changes it does not touch them: it shows them and asks whether to continue
   without updating. If the pull fails (for example, the branch diverged), it asks the same.
2. Finds Python 3 (`py -3`, then `python`).
3. The first time, creates `deploy.local.ini` from the example, opens it in Notepad and stops:
   set the console's IP and run it again.
4. Lists the games (`examples\*` and `template`) and asks for one (Enter picks `rooms`).
5. Runs `tools\deploy.py` on it and waits for a key, so the window stays open to read.

It runs from a copy in `%TEMP%`, so a pull that changes the script itself is safe.

`run_pc.bat`, next to it, does the same update and then opens a game on the PC: it finds
`love.exe` (`%ProgramFiles%\LOVE`, then the PATH; if LOVE is missing it says so and opens
https://love2d.org to get LOVE 11.5), lists the games and starts the chosen one (Enter picks
`rooms`) from the repository root.

`level_editor.bat` opens the level editor with LOVE ([LEVEL_EDITOR.md](LEVEL_EDITOR.md)). It does
not update the repository.

## One-time setup

1. Do the setup of [BUILDING.md](../BUILDING.md): WSL with xsdk, its GCC and LuaJIT for xsdk
   (`toolchain/build_luajit_xsdk.sh`), and the xost tools of [SHADERS.md](SHADERS.md).
2. Copy `tools/deploy.example.ini` to `deploy.local.ini`, in the game folder (or at the root of
   the base, to share it between games), and fill it in: the console's IP, the FTP login, the
   xsdk paths as WSL sees them and the xost folder.
3. `deploy.local.ini` is in `.gitignore` of the base. Add it to the game's `.gitignore` too
   (the template already does): it holds the console's address and password.

On the console: Aurora running with its FTP server enabled, and the install folder (by default
`Hdd1:\Games`) in a scan path.

## What it runs

| Step | Tool | Notes |
|---|---|---|
| 1. `.xex` | `cmake` + `ninja` | In WSL on Windows (`wsl.exe --cd <base> -e bash -lc ...`), directly on Linux. Title ID and name from `game.lua`. One build folder per game: `runtime/build/<identity>/`. |
| 2. Shaders | `tools/shaders/build_shaders.py` | Into `<game>/build/shaders`. Without `[shaders] tools`, the last output is reused. |
| 3. Package | `tools/package.py` | Into `<game>/dist/<identity>/`. |
| 4. Upload | `tools/install_ftp.py` | Only changed files. Saves and `default.log` are never touched. The password goes in the environment, not on the command line. |
| 5. Launch | XBDM `magicboot` | Only with `[launch] method = xbdm` or `--launch`. Off by default. |

Every step stops the chain when it fails, with the tool's own output above the error.

## Options

- `--skip-xex`: do not build; reuse `runtime/build/<identity>/game.xex` (for Lua-only changes;
  the build is incremental anyway, so this mostly saves starting WSL).
- `--skip-shaders`: reuse `<game>/build/shaders`.
- `--no-upload`: stop after packaging (to copy the folder to a USB drive).
- `--launch` / `--no-launch`: override `[launch] method` for this run.
- `--force`: upload every file, changed or not.
- `--dry-run`: print the commands of every step; build, write and upload nothing.
- `--config FILE`: another INI file.

`X360_FTP_HOST`, `X360_FTP_PORT`, `X360_FTP_USER`, `X360_FTP_PASSWORD` and `X360_FTP_TARGET`
override the `[console]` section.

## Starting the game after the upload (optional)

Aurora's FTP server cannot start a title. With `[launch] method = xbdm`, the script connects to
the console on TCP 730 and sends XBDM's `magicboot` with the path of `default.xex`, which starts
it as if opened from Aurora. This needs the `xbdm.xex` plugin loaded on the console (through
DashLaunch); the repository contains no XDK code, only that one text command. Without the plugin
the script says so and the game is started from Aurora as usual.

XBDM names the hard drive `Hdd:` where Aurora's FTP says `Hdd1`; the script translates it. If the
folder is elsewhere, set `[launch] path`.

## To verify on the console (not tested on hardware yet)

1. `python base\tools\deploy.py . --dry-run`: the commands look right and the paths exist.
2. `python base\tools\deploy.py .`: the `.xex` builds in WSL, the upload ends with
   `N uploaded`, and the game appears in Aurora after a scan and runs.
3. Change one Lua file and run it again with `--skip-xex --skip-shaders`: only that file and the
   manifest are uploaded.
4. With the XBDM plugin: `--launch` starts the game; check `default.log` if it does not.
