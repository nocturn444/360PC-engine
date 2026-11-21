#!/usr/bin/env python3
"""One command from a game folder to the console: build the .xex, compile the shaders, package,
upload over FTP and (optionally) start the game.

    python tools/deploy.py <game folder> [--config FILE] [--skip-xex] [--skip-shaders]
        [--no-upload] [--launch | --no-launch] [--force] [--dry-run]

Each step is one of the existing tools, run with this Python:

    1. .xex      cmake + ninja (BUILDING.md), in WSL on Windows or directly on Linux. The Title ID
                 and the name come from the game's game.lua. Output: runtime/build/<identity>/game.xex
                 in the base (one build folder per game, so games never share a CMake cache).
    2. shaders   tools/shaders/build_shaders.py with the xost tools (Windows only), into
                 <game>/build/shaders. Without xost tools in the config, the last output is reused.
    3. package   tools/package.py, into <game>/dist/<identity>.
    4. upload    tools/install_ftp.py: only changed files; saves and default.log are never touched.
    5. launch    only with launch = xbdm in the config (or --launch): asks the xbdm.xex plugin on
                 the console (TCP 730) to start default.xex. Off by default.

The console's address, FTP login and the paths of the local tools are personal, so they live in a
local INI file that is never committed (deploy.local.ini; tools/deploy.example.ini shows every
key). It is looked for with --config, then in the game folder, then at the root of the base.
Environment variables X360_FTP_HOST, X360_FTP_PORT, X360_FTP_USER, X360_FTP_PASSWORD and
X360_FTP_TARGET override the [console] section.

Python 3.8 or later, standard library only; runs on Windows and Linux.
"""
import argparse
import configparser
import os
import shlex
import shutil
import socket
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
TOOLS = BASE / "tools"
sys.path.insert(0, str(TOOLS))
import package  # noqa: E402  (read_config: the game's identity, Title ID and name)
from install_ftp import DEFAULT_DRIVE_PATH, parse_target  # noqa: E402

CONFIG_NAME = "deploy.local.ini"
XBDM_PORT = 730
# The FTP server of Aurora names drives Hdd1, Usb0...; XBDM names the hard drive Hdd.
XBDM_DRIVES = {"hdd1": "Hdd"}

DEFAULTS = {
    "console": {"host": "", "port": "21", "user": "xboxftp", "password": "xboxftp", "target": ""},
    "xex": {"mode": "auto", "wsl_distro": "", "xsdk": "", "toolchain": "~/xsdk-gcc",
            "build_type": "RelWithDebInfo", "release": "false"},
    "shaders": {"tools": ""},
    "package": {"zip": "false"},
    "launch": {"method": "none", "port": str(XBDM_PORT), "path": "", "timeout": "10"},
}
ENV_KEYS = {"host": "X360_FTP_HOST", "port": "X360_FTP_PORT", "user": "X360_FTP_USER",
            "password": "X360_FTP_PASSWORD", "target": "X360_FTP_TARGET"}


class DeployError(Exception):
    """Something that stops the deploy; the message is for the user."""


# ---------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------

def find_config(game, explicit=None):
    """The INI to use: --config, then <game>/deploy.local.ini, then <base>/deploy.local.ini."""
    if explicit:
        p = Path(explicit)
        if not p.is_file():
            raise DeployError("%s not found" % p)
        return p
    for p in (Path(game) / CONFIG_NAME, BASE / CONFIG_NAME):
        if p.is_file():
            return p
    return None


def load_config(path=None, env=None):
    """A ConfigParser with every default filled in, the file read over it, then the environment."""
    cp = configparser.ConfigParser(interpolation=None)
    cp.read_dict(DEFAULTS)
    if path:
        with open(path, encoding="utf-8") as f:
            cp.read_file(f)
    env = os.environ if env is None else env
    for key, var in ENV_KEYS.items():
        if env.get(var):
            cp.set("console", key, env[var])
    return cp


def flag(cp, section, key):
    try:
        return cp.getboolean(section, key)
    except ValueError:
        raise DeployError("[%s] %s must be true or false" % (section, key))


# ---------------------------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------------------------

def xex_mode(cp, platform=None):
    """'wsl' or 'native' (or 'skip'): auto means WSL on Windows and native elsewhere."""
    mode = cp.get("xex", "mode").strip().lower()
    if mode not in ("auto", "wsl", "native", "skip"):
        raise DeployError("[xex] mode must be auto, wsl, native or skip (got %r)" % mode)
    if mode == "auto":
        mode = "wsl" if (platform or sys.platform).startswith("win") else "native"
    return mode


def xex_script(cp, cfg):
    """The shell lines that configure and build the .xex, run from the base's root."""
    xsdk = cp.get("xex", "xsdk").strip()
    if not xsdk:
        raise DeployError("[xex] xsdk is not set: the path of the xsdk checkout, as the build shell "
                          "sees it (in WSL, a Linux path such as ~/xsdk)")
    build_dir = "runtime/build/" + cfg["identity"]
    q = shlex.quote

    def path_arg(p):
        # ~ only expands outside quotes; keep it as $HOME so the rest can be quoted.
        p = p.rstrip("/")
        return '"$HOME"' + q(p[1:]) if p.startswith("~/") else q(p)

    configure = " ".join([
        "cmake", "-S", "runtime", "-B", q(build_dir), "-G", "Ninja",
        "-DCMAKE_TOOLCHAIN_FILE=" + path_arg(xsdk + "/cmake/xsdk.cmake"),
        "-DXSDK_TOOLCHAIN=" + path_arg(cp.get("xex", "toolchain").strip()),
        "-DCMAKE_BUILD_TYPE=" + q(cp.get("xex", "build_type").strip() or "RelWithDebInfo"),
        "-DL360_RELEASE=" + ("ON" if flag(cp, "xex", "release") else "OFF"),
        "-DGAME_TITLE_ID=" + q(cfg["title_id"]),
        "-DGAME_NAME=" + q(cfg["name"]),
    ])
    # One line: wsl.exe passes it through the Windows command line, where newlines are fragile.
    return "%s && cmake --build %s" % (configure, q(build_dir)), BASE / build_dir / "game.xex"


def xex_command(cp, cfg, platform=None):
    """(argv, cwd, the .xex it writes) for the build, or None when the mode is skip."""
    mode = xex_mode(cp, platform)
    if mode == "skip":
        return None
    script, xex = xex_script(cp, cfg)
    if mode == "native":
        return ["bash", "-c", script], str(BASE), xex
    argv = ["wsl.exe"]
    distro = cp.get("xex", "wsl_distro").strip()
    if distro:
        argv += ["-d", distro]
    # --cd takes the Windows path of the base; -e runs bash without the default shell re-parsing
    # the line, and a login shell (-l) gets the PATH set in ~/.profile.
    argv += ["--cd", str(BASE), "-e", "bash", "-lc", script]
    return argv, None, xex


def shaders_command(cp, game, out):
    tools = cp.get("shaders", "tools").strip()
    if not tools:
        return None
    return [sys.executable, str(TOOLS / "shaders" / "build_shaders.py"), str(game),
            "--tools", tools, "--out", str(out)]


def package_command(game, xex, shaders, out, zip_too=False):
    argv = [sys.executable, str(TOOLS / "package.py"), str(game), "--out", str(out)]
    argv += ["--xex", str(xex)] if xex else ["--no-xex"]
    argv += ["--shaders", str(shaders)] if shaders else ["--no-shaders"]
    if zip_too:
        argv.append("--zip")
    return argv


def console_target(cp, cfg):
    return cp.get("console", "target").strip() or "%s/%s" % (DEFAULT_DRIVE_PATH, cfg["identity"])


def upload_command(cp, out, target, force=False, dry_run=False, safe=False):
    """argv and environment for install_ftp.py; the password goes in the environment only."""
    host = cp.get("console", "host").strip()
    if not host:
        raise DeployError("[console] host is not set: the console's IP (Aurora shows it)")
    argv = [sys.executable, str(TOOLS / "install_ftp.py"), str(out), "--host", host,
            "--port", cp.get("console", "port").strip(), "--user", cp.get("console", "user"),
            "--target", target]
    if force:
        argv.append("--force")
    if dry_run:
        argv.append("--dry-run")
    if safe:
        argv.append("--safe")
    env = dict(os.environ, X360_FTP_PASSWORD=cp.get("console", "password"))
    env.pop("X360_FTP_TARGET", None)
    return argv, env


def xbdm_paths(cp, target):
    """(title, directory) as XBDM names them: 'Hdd1:/Games/x' -> 'Hdd:\\Games\\x\\default.xex'."""
    override = cp.get("launch", "path").strip()
    if override:
        folder = override.replace("/", "\\").rstrip("\\")
    else:
        parts = parse_target(target)
        drive = XBDM_DRIVES.get(parts[0].lower(), parts[0])
        folder = drive + ":\\" + "\\".join(parts[1:])
    return folder + "\\default.xex", folder + "\\"


def xbdm_launch(host, port, title, directory, timeout=10, connect=socket.create_connection):
    """Asks XBDM to start a title (magicboot). Returns XBDM's answer line."""
    if '"' in title or '"' in directory:
        raise DeployError("a launch path cannot contain a double quote")
    try:
        with connect((host, port), timeout) as s:
            f = s.makefile("rwb", buffering=0)
            hello = f.readline().decode("ascii", "replace").strip()
            if not hello.startswith("201"):
                raise DeployError("XBDM did not greet as expected: %r" % hello)
            cmd = 'magicboot title="%s" directory="%s"\r\n' % (title, directory)
            f.write(cmd.encode("ascii"))
            answer = f.readline().decode("ascii", "replace").strip()
            try:
                f.write(b"bye\r\n")
            except OSError:
                pass  # the console may already be rebooting into the title
    except OSError as e:
        raise DeployError("cannot reach XBDM at %s:%d (%s). Is the xbdm.xex plugin loaded? "
                          "Start the game from Aurora instead." % (host, port, e))
    if not answer.startswith("2"):
        raise DeployError("XBDM refused the launch: %s" % answer)
    return answer


# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------

def show(argv):
    return " ".join(shlex.quote(a) for a in argv)


def run(step, argv, log, dry_run, cwd=None, env=None, runner=subprocess.run):
    log("== %s: %s" % (step, show(argv) if len(show(argv)) < 400 else show(argv[:6]) + " ..."))
    if dry_run:
        return
    r = runner(argv, cwd=cwd, env=env)
    if r.returncode != 0:
        raise DeployError("%s failed (exit code %d); see the output above" % (step, r.returncode))


def main(argv=None, log=print, runner=subprocess.run, connect=socket.create_connection, env=None):
    ap = argparse.ArgumentParser(description="Build, package, upload and start a 360PC-Engine game on the console.")
    ap.add_argument("game", type=Path, help="game folder (with game.lua and main.lua)")
    ap.add_argument("--config", help="INI file (default: %s in the game folder, then in the base)" % CONFIG_NAME)
    ap.add_argument("--skip-xex", action="store_true", help="do not build; reuse the last .xex of this game")
    ap.add_argument("--skip-shaders", action="store_true", help="do not compile; reuse <game>/build/shaders")
    ap.add_argument("--no-upload", action="store_true", help="stop after packaging")
    launch = ap.add_mutually_exclusive_group()
    launch.add_argument("--launch", action="store_true", help="start the game after the upload (XBDM)")
    launch.add_argument("--no-launch", action="store_true", help="do not start it, whatever the config says")
    ap.add_argument("--force", action="store_true", help="upload every file, changed or not")
    ap.add_argument("--dry-run", action="store_true", help="print the steps; build, write and upload nothing")
    ap.add_argument("--lua", help="LuaJIT executable used to read game.lua (default: luajit on the PATH)")
    args = ap.parse_args(argv)
    try:
        game = args.game.resolve()
        if not game.is_dir():
            raise DeployError("%s is not a folder" % args.game)
        cfg_path = find_config(game, args.config)
        cp = load_config(cfg_path, env)
        log("config: %s" % (cfg_path or "none (defaults and X360_FTP_* only); see tools/deploy.example.ini"))
        try:
            cfg = package.read_config(game, args.lua, log)
        except package.PackageError as e:
            raise DeployError(str(e))
        log("%s (%s), Title ID %s" % (cfg["name"], cfg["identity"], cfg["title_id"]))

        # 1. .xex
        built = None if args.skip_xex else xex_command(cp, cfg)
        if built:
            xargv, cwd, xex = built
            run("xex", xargv, log, args.dry_run, cwd=cwd, runner=runner)
        else:
            xex = BASE / "runtime" / "build" / cfg["identity"] / "game.xex"
            log("== xex: skipped, reusing %s" % xex)
            if not xex.is_file() and not args.dry_run:
                raise DeployError("%s does not exist: build it once (without --skip-xex)" % xex)

        # 2. shaders
        shaders = game / "build" / "shaders"
        sargv = None if args.skip_shaders else shaders_command(cp, game, shaders)
        if sargv:
            run("shaders", sargv, log, args.dry_run, runner=runner)
        else:
            log("== shaders: not compiled (%s), reusing %s" % (
                "--skip-shaders" if args.skip_shaders else "no [shaders] tools in the config", shaders))
            if not shaders.is_dir() and not args.dry_run:
                raise DeployError("%s does not exist: set [shaders] tools (the xost folder) and run "
                                  "once without --skip-shaders" % shaders)

        # 3. package
        out = game / "dist" / cfg["identity"]
        run("package", package_command(game, xex, shaders, out, flag(cp, "package", "zip")), log,
            args.dry_run, runner=runner)
        if args.no_upload:
            log("done: %s (not uploaded)" % out)
            return 0

        # 4. upload
        target = console_target(cp, cfg)
        uargv, uenv = upload_command(cp, out, target, args.force)
        run("upload", uargv, log, args.dry_run, env=uenv, runner=runner)

        # 5. launch
        method = cp.get("launch", "method").strip().lower()
        if method not in ("none", "xbdm"):
            raise DeployError("[launch] method must be none or xbdm (got %r)" % method)
        if args.launch:
            method = "xbdm"
        if args.no_launch or method == "none":
            log("done: start it from Aurora (%s)" % target)
            return 0
        title, directory = xbdm_paths(cp, target)
        host = cp.get("console", "host").strip()
        port = cp.getint("launch", "port")
        log("== launch: XBDM %s:%d magicboot %s" % (host, port, title))
        if not args.dry_run:
            log("   " + xbdm_launch(host, port, title, directory, cp.getfloat("launch", "timeout"), connect))
        log("done")
        return 0
    except DeployError as e:
        print("deploy: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
