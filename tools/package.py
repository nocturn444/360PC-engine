#!/usr/bin/env python3
"""Assembles the console folder of a game: what goes next to default.xex on the Xbox 360.

    python tools/package.py <game folder> --xex runtime/build/game.xex \
        --shaders build/mygame/shaders [--out dist/<identity>] [--zip] [--dry-run]

The folder it writes (runtime/README.md, "Console folder"):

    default.xex               the .xex given with --xex
    game.lua, conf.lua, main.lua and the game's other files, without development files
    engine/                   the base's engine/ (core files, plus the modules the game uses)
    lib/                      the base's libraries the game uses, with their licenses
    l360/                     the base's runtime/lua/*.lua
    shaders/                  the output of tools/shaders/build_shaders.py (--shaders)
    package_manifest.txt      size and CRC-32 of every file (tools/install_ftp.py reads it)

save/ and default.log are never written: they belong to the console. A game that has its own
engine/ or lib/ folder (a pinned copy) ships that one as it is. The base is the repository this
script is in, so it works the same for a submodule and for a copy.

Python 3.8 or later, standard library only; runs on Windows and Linux. game.lua is read with
LuaJIT (tools/read_game_config.lua) when there is one on the PATH (or --lua), otherwise with a
small parser that understands the plain "key = value" form the template uses.
"""
import argparse
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import zipfile
import zlib
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
MANIFEST = "package_manifest.txt"
MANIFEST_HEADER = "# 360PC-Engine package v1"
DEV_TITLE_ID = "0xFFFF0360"

# Names (not paths) left out of the game folder, at any depth. --exclude adds more.
DEFAULT_EXCLUDES = [
    ".*", "*.md", "*.xex", "*.log", "*.zip", "*.psu", "*.vsu", "*.meta.lua", "*.hlsl",
    "*.py", "*.pyc", "*.bat", "*.sh", "*.cmd", "*.love", "*.exe", "*.dll",
    "*.psd", "*.xcf", "*.kra", "*.aseprite", "*.ase", "*.tiled-session", "*.blend", "*.bak", "*.tmp",
    "*.orig", "*~", "__pycache__", "Thumbs.db", "desktop.ini", "deploy.local.ini", MANIFEST,
]
# Folders left out only at the top of the game folder.
TOP_EXCLUDES = ["dist", "build", "tests", "tools", "docs"]
# Names the runtime owns in the console folder.
RESERVED_TOP = ["l360", "default.xex", "default.log", MANIFEST]
BUILTIN_SHADERS = ["l360_default.psu", "l360_default.vsu", "l360_love.psu", "l360_love.vsu"]
# Libraries a module needs (lib/README.md).
MODULE_LIBS = {"platformer": ["bump"]}


class PackageError(Exception):
    """Something that stops the packaging; the message is for the user."""


# ---------------------------------------------------------------------------------------------
# game.lua
# ---------------------------------------------------------------------------------------------

def _tokens(text):
    """Lua tokens of a data-only file: ('name', s), ('string', s), ('sym', c). Comments dropped."""
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                end = text.find("]" + m.group(1) + "]", i)
                i = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = text.find("\n", i)
                i = n if end < 0 else end
        elif c in "\"'":
            j, out = i + 1, []
            while j < n and text[j] != c:
                if text[j] == "\\" and j + 1 < n:
                    out.append(text[j + 1])
                    j += 2
                else:
                    out.append(text[j])
                    j += 1
            yield ("string", "".join(out))
            i = j + 1
        elif c.isalpha() or c == "_":
            m = re.match(r"\w+", text[i:])
            yield ("name", m.group(0))
            i += len(m.group(0))
        else:
            yield ("sym", c)
            i += 1


def parse_game_lua(text):
    """The fallback reader, for a PC without LuaJIT: top-level `key = "text"` and `key = true`,
    and the names in `shaders = { ... }`. Not a Lua interpreter: computed values are not seen."""
    fields, shaders = {}, {}
    depth, inside = 0, []
    toks = list(_tokens(text))
    for k, (kind, value) in enumerate(toks):
        if kind == "sym" and value == "{":
            name = toks[k - 2][1] if k >= 2 and toks[k - 1] == ("sym", "=") and toks[k - 2][0] == "name" else None
            inside.append(name)
            depth += 1
        elif kind == "sym" and value == "}":
            depth -= 1
            if inside:
                inside.pop()
        elif kind == "name" and k + 2 < len(toks) and toks[k + 1] == ("sym", "="):
            nxt = toks[k + 2]
            if depth == 1:
                if nxt[0] == "string":
                    fields[value] = nxt[1]
                elif nxt == ("name", "true"):
                    fields[value] = True
                elif nxt == ("name", "false"):
                    fields[value] = False
            elif depth == 2 and inside[-1] == "shaders":
                shaders[value] = True
    return fields, shaders


def validate_config(fields):
    """The checks of runtime/lua/config.lua that matter to the packaging. Returns the config."""
    name = fields.get("name")
    if (not isinstance(name, str) or not 1 <= len(name) <= 64 or re.search(r'[^\x20-\x7e]|["\\;]', name)
            or name != name.strip()):
        raise PackageError('game.lua: name is required: 1 to 64 printable ASCII characters, without " \\ ;')
    title = fields.get("title_id")
    m = isinstance(title, str) and re.fullmatch(r"(?:0[xX])?([0-9a-fA-F]{8})", title)
    if not m or m.group(1) == "00000000":
        raise PackageError('game.lua: title_id is required to package the game: 8 hex digits, like "0x4D470001"')
    identity = fields.get("identity")
    if identity is None:
        identity = re.sub(r"[^0-9a-z]+", "_", name.lower()).strip("_")[:32] or "game"
    save_dir = fields.get("save_dir", "save")
    for what, v in (("identity", identity), ("save_dir", save_dir)):
        if not isinstance(v, str) or not re.fullmatch(r"[\w\-]{1,32}", v, re.ASCII):
            raise PackageError("game.lua: %s must be 1 to 32 characters: letters, digits, _ and -" % what)
    if save_dir.lower() in ("l360", "shaders"):
        raise PackageError("game.lua: save_dir cannot be %s (used by the runtime)" % save_dir)
    return {"name": name, "title_id": "0x" + m.group(1).upper(), "identity": identity, "save_dir": save_dir}


def find_lua(lua=None):
    if lua:
        return lua
    return next((e for e in ("luajit", "lua5.1", "lua") if shutil.which(e)), None)


def read_config(game, lua=None, log=print):
    """name, title_id, identity, save_dir, shaders (names), debug and default_font of game.lua."""
    path = Path(game) / "game.lua"
    if not path.is_file():
        raise PackageError("%s not found: the packaging needs the game's game.lua" % path)
    text = path.read_text(encoding="utf-8", errors="replace")
    fields, shader_names = parse_game_lua(text)
    exe = find_lua(lua)
    if exe:
        tool = str(BASE / "tools" / "read_game_config.lua")

        def ask(*args):
            r = subprocess.run([exe, tool, str(game), *args], capture_output=True, text=True)
            if r.returncode != 0:
                raise PackageError((r.stderr or r.stdout).strip() or "read_game_config.lua failed")
            return r.stdout

        cfg = dict(line.split("=", 1) for line in ask().splitlines() if "=" in line)
        cfg["shaders"] = sorted(line.split("\t")[0] for line in ask("shaders").splitlines() if line.strip())
    else:
        log("  note: no LuaJIT found; game.lua read with the built-in parser (plain values only)")
        cfg = validate_config(fields)
        cfg["shaders"] = sorted(shader_names)
    cfg["debug"] = fields.get("debug") is True
    cfg["default_font"] = fields.get("default_font") if isinstance(fields.get("default_font"), str) else None
    return cfg


# ---------------------------------------------------------------------------------------------
# The plan: what goes where
# ---------------------------------------------------------------------------------------------

def _excluded(name, patterns):
    return any(fnmatch.fnmatchcase(name.lower(), p.lower()) for p in patterns)


def _is_base(folder):
    """a checkout or copy of the base inside the game folder (the submodule): never shipped whole"""
    return (folder / "runtime" / "lua" / "boot.lua").is_file() and (folder / "engine" / "init.lua").is_file()


def game_files(game, cfg, excludes=(), skip_dirs=()):
    """(destination, source) for the game's own files, development files left out"""
    game = Path(game)
    patterns = list(DEFAULT_EXCLUDES) + list(excludes)
    skip = {Path(p).resolve() for p in skip_dirs}
    reserved = {n.lower() for n in RESERVED_TOP} | {cfg["save_dir"].lower()}
    out = []
    for root, dirs, files in os.walk(game):
        rootp = Path(root)
        top = rootp == game
        keep = []
        for d in sorted(dirs):
            full = rootp / d
            if _excluded(d, patterns) or full.resolve() in skip or _is_base(full):
                continue
            if top and (d.lower() in TOP_EXCLUDES or d.lower() == cfg["save_dir"].lower()):
                continue
            if top and d.lower() == "l360":
                raise PackageError("the game has a folder named l360: that name belongs to the runtime")
            if any(fnmatch.fnmatchcase((full.relative_to(game)).as_posix(), p) for p in excludes):
                continue
            keep.append(d)
        dirs[:] = keep
        for f in sorted(files):
            rel = (rootp / f).relative_to(game).as_posix()
            if _excluded(f, patterns) or any(fnmatch.fnmatchcase(rel, p) for p in excludes):
                continue
            if top and f.lower() in reserved:
                continue
            out.append((rel, rootp / f))
    return out


def used_modules(files):
    """names of engine/modules and lib/ folders the game's Lua mentions, and whether it requires engine"""
    modules, libs, engine = set(), set(), False
    for rel, src in files:
        if not rel.endswith(".lua") or rel.startswith(("engine/", "lib/")):
            continue
        text = Path(src).read_text(encoding="utf-8", errors="replace")
        modules.update(re.findall(r"engine[./]modules[./](\w+)", text))
        libs.update(re.findall(r"""["']lib[./](\w+)""", text))
        if re.search(r"engine\.anim\b|anim8", text):
            libs.add("anim8")
        if re.search(r"""require\s*\(?\s*["']engine\b""", text):
            engine = True
    return modules, libs, engine


def base_files(files, modules=(), libs=(), all_modules=False, log=print):
    """(destination, source) for the base's engine/ and lib/ files the game needs"""
    have_engine = any(rel.startswith("engine/") for rel, _ in files)
    have_lib = any(rel.startswith("lib/") for rel, _ in files)
    found_modules, found_libs, uses_engine = used_modules(files)
    modules = set(modules) | found_modules
    libs = set(libs) | found_libs
    out = []
    if have_engine:
        log("  engine/: the game's own copy")
    elif not (uses_engine or modules or all_modules):
        log("  engine/: not used by the game, left out")
    else:
        engine = BASE / "engine"
        out += [("engine/" + p.name, p) for p in sorted(engine.glob("*.lua"))]
        available = sorted(p.name for p in (engine / "modules").iterdir() if p.is_dir())
        if all_modules:
            modules = set(available)
        for m in sorted(modules):
            if m not in available:
                raise PackageError("the game uses engine.modules.%s, which the base does not have (it has: %s)"
                                   % (m, ", ".join(available)))
            for p in sorted((engine / "modules" / m).rglob("*")):
                if p.is_file() and p.suffix == ".lua":
                    out.append(("engine/modules/%s/%s" % (m, p.relative_to(engine / "modules" / m).as_posix()), p))
            libs.update(MODULE_LIBS.get(m, []))
        log("  engine/: core%s" % ("".join(", modules/" + m for m in sorted(modules))))
    if have_lib:
        log("  lib/: the game's own copy")
    else:
        for name in sorted(libs):
            folder = BASE / "lib" / name
            if not folder.is_dir():
                raise PackageError("the game uses lib/%s, which the base does not have" % name)
            for p in sorted(folder.rglob("*")):
                if p.is_file():
                    out.append(("lib/%s/%s" % (name, p.relative_to(folder).as_posix()), p))
        if libs:
            log("  lib/: %s" % ", ".join(sorted(libs)))
    return out


def runtime_files():
    return [("l360/" + p.name, p) for p in sorted((BASE / "runtime" / "lua").glob("*.lua"))]


def shader_files(shaders_dir, declared):
    """the shader build's output, checked: the engine's four files and every declared shader"""
    folder = Path(shaders_dir)
    if not folder.is_dir():
        raise PackageError("--shaders %s is not a folder (run tools/shaders/build_shaders.py first)" % folder)
    out = [("shaders/" + p.name, p) for p in sorted(folder.iterdir())
           if p.is_file() and (p.suffix in (".psu", ".vsu") or p.name.endswith(".meta.lua"))]
    names = {rel.split("/", 1)[1] for rel, _ in out}
    missing = [n for n in BUILTIN_SHADERS if n not in names]
    missing += ["%s.meta.lua" % n for n in declared if "%s.meta.lua" % n not in names]
    for n in declared:
        if n + ".psu" not in names and n + ".vsu" not in names:
            missing.append("%s.psu or %s.vsu" % (n, n))
    if missing:
        raise PackageError("--shaders %s is incomplete, missing: %s\n(the output of "
                           "tools/shaders/build_shaders.py without --hlsl-only)" % (folder, ", ".join(missing)))
    return out


def check_xex(xex):
    path = Path(xex)
    if not path.is_file():
        raise PackageError("--xex %s not found (build it: BUILDING.md)" % path)
    with open(path, "rb") as f:
        if f.read(4) != b"XEX2":
            raise PackageError("--xex %s is not a .xex file (no XEX2 header)" % path)
    return path


def make_plan(game, cfg, xex=None, shaders=None, excludes=(), modules=(), libs=(), all_modules=False,
              extras=(), out=None, log=print):
    """the sorted list of (destination, source) and the warnings; raises PackageError"""
    game = Path(game)
    warnings = []
    files = game_files(game, cfg, excludes, skip_dirs=[out] if out else [])
    names = {rel for rel, _ in files}
    if "main.lua" not in names:
        raise PackageError("%s has no main.lua" % game)
    if "conf.lua" not in names:
        warnings.append("the game has no conf.lua")
    if cfg.get("default_font") and cfg["default_font"] not in names:
        raise PackageError("game.lua: default_font %s is not in the package" % cfg["default_font"])
    if cfg["title_id"].upper() == DEV_TITLE_ID.upper():
        warnings.append("title_id is the development Title ID %s: do not distribute this" % DEV_TITLE_ID)
    if cfg.get("debug"):
        warnings.append("game.lua has debug = true: this is a development package")
    if any(rel.startswith("shaders/") for rel, _ in files) and not cfg["shaders"]:
        warnings.append("the game has a shaders/ folder but declares no shaders in game.lua")
    files += base_files(files, modules, libs, all_modules, log)
    files += runtime_files()
    if shaders is not None:
        files += shader_files(shaders, cfg["shaders"])
    else:
        warnings.append("no shaders in the package (--no-shaders): the console folder needs shaders/ to draw")
    if xex is not None:
        files.append(("default.xex", check_xex(xex)))
    else:
        warnings.append("no default.xex in the package (--no-xex)")
    for extra in extras:
        src, _, dest = extra.partition("=")
        srcp = Path(src)
        if not srcp.is_file():
            raise PackageError("--extra %s not found" % src)
        dest = (dest or srcp.name).replace("\\", "/").strip("/")
        if ".." in dest.split("/") or dest.split("/")[0].lower() == cfg["save_dir"].lower():
            raise PackageError("--extra destination %s is not allowed" % dest)
        files = [(r, s) for r, s in files if r.lower() != dest.lower()]
        files.append((dest, srcp))
    seen = {}
    for rel, src in files:
        key = rel.lower()
        if key in seen and seen[key] != rel:
            raise PackageError("two files differ only in case, which the console cannot hold: %s and %s"
                               % (seen[key], rel))
        if key in seen:
            raise PackageError("two files go to %s" % rel)
        seen[key] = rel
    return sorted(files, key=lambda f: f[0].lower()), warnings


# ---------------------------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------------------------

def crc32_of(path):
    crc = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            crc = zlib.crc32(chunk, crc)
    return crc & 0xFFFFFFFF


def manifest_text(cfg, entries):
    """entries: (path, size, crc)"""
    lines = [MANIFEST_HEADER, "# name=%s" % cfg["name"], "# title_id=%s" % cfg["title_id"],
             "# identity=%s" % cfg["identity"], "# save_dir=%s" % cfg["save_dir"]]
    lines += ["%d %08X %s" % (size, crc, rel) for rel, size, crc in entries]
    return "\n".join(lines) + "\n"


def parse_manifest(text):
    """{path: (size, crc)} and the header fields of a package manifest; None if it is not one"""
    if not text.startswith(MANIFEST_HEADER):
        return None
    files, fields = {}, {}
    for line in text.splitlines()[1:]:
        if line.startswith("# "):
            k, _, v = line[2:].partition("=")
            fields[k] = v
            continue
        parts = line.split(" ", 2)
        if len(parts) == 3:
            try:
                files[parts[2]] = (int(parts[0]), int(parts[1], 16))
            except ValueError:
                return None
    return {"files": files, "fields": fields}


def write_package(plan, cfg, out, force=False):
    out = Path(out)
    if out.exists():
        if not out.is_dir():
            raise PackageError("%s exists and is not a folder" % out)
        ours = (out / MANIFEST).is_file() and (out / MANIFEST).read_text(errors="replace").startswith(MANIFEST_HEADER)
        if any(out.iterdir()) and not (ours or force):
            raise PackageError("%s is not empty and was not written by this tool; use --force to replace it" % out)
        shutil.rmtree(out)
    entries = []
    for rel, src in plan:
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dest)
        entries.append((rel, dest.stat().st_size, crc32_of(dest)))
    (out / MANIFEST).write_bytes(manifest_text(cfg, entries).encode("utf-8"))
    return entries


def write_zip(out, zip_path=None):
    """<out>.zip with the folder inside, files in a fixed order"""
    out = Path(out)
    zip_path = Path(zip_path) if zip_path else out.with_name(out.name + ".zip")
    paths = sorted((p for p in out.rglob("*") if p.is_file()), key=lambda p: p.relative_to(out).as_posix().lower())
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for p in paths:
            z.write(p, "%s/%s" % (out.name, p.relative_to(out).as_posix()))
    return zip_path


def main(argv=None, log=print):
    ap = argparse.ArgumentParser(description="Assemble the console folder of a 360PC-Engine game.")
    ap.add_argument("game", type=Path, help="game folder (with game.lua and main.lua)")
    ap.add_argument("--xex", type=Path, help="the built .xex (runtime/build/game.xex); copied as default.xex")
    ap.add_argument("--no-xex", action="store_true", help="package without default.xex (to update the game's files)")
    ap.add_argument("--shaders", type=Path, help="output folder of tools/shaders/build_shaders.py")
    ap.add_argument("--no-shaders", action="store_true", help="package without shaders/")
    ap.add_argument("--out", type=Path, help="folder to write (default: dist/<identity>)")
    ap.add_argument("--zip", action="store_true", help="also write <out>.zip")
    ap.add_argument("--dry-run", action="store_true", help="list what would be packaged and write nothing")
    ap.add_argument("--force", action="store_true", help="replace --out even if this tool did not write it")
    ap.add_argument("--exclude", action="append", default=[], metavar="PATTERN",
                    help="leave out game files matching this name or path pattern (repeatable)")
    ap.add_argument("--module", action="append", default=[], metavar="NAME",
                    help="include engine/modules/NAME even if no game file mentions it (repeatable)")
    ap.add_argument("--all-modules", action="store_true", help="include every engine module")
    ap.add_argument("--lib", action="append", default=[], metavar="NAME", help="include lib/NAME (repeatable)")
    ap.add_argument("--extra", action="append", default=[], metavar="FILE[=DEST]",
                    help="add a file (e.g. a console check script); DEST is its path in the package")
    ap.add_argument("--lua", help="LuaJIT executable used to read game.lua (default: luajit on the PATH)")
    args = ap.parse_args(argv)
    try:
        if not args.game.is_dir():
            raise PackageError("%s is not a folder" % args.game)
        if not args.xex and not args.no_xex:
            raise PackageError("give --xex <file> (or --no-xex to package without default.xex)")
        if not args.shaders and not args.no_shaders:
            raise PackageError("give --shaders <folder> (or --no-shaders to package without shaders/)")
        cfg = read_config(args.game, args.lua, log)
        out = args.out or Path("dist") / cfg["identity"]
        log("%s (%s), Title ID %s" % (cfg["name"], cfg["identity"], cfg["title_id"]))
        plan, warnings = make_plan(args.game, cfg, None if args.no_xex else args.xex,
                                   None if args.no_shaders else args.shaders, args.exclude, args.module,
                                   args.lib, args.all_modules, args.extra, out, log)
        for w in warnings:
            log("  warning: " + w)
        total = sum(Path(src).stat().st_size for _, src in plan)
        if args.dry_run:
            for rel, src in plan:
                log("%10d  %s" % (Path(src).stat().st_size, rel))
            log("dry run: %d files, %.1f KB would go to %s" % (len(plan), total / 1024, out))
            return 0
        write_package(plan, cfg, out, args.force)
        log("%d files, %.1f KB in %s" % (len(plan), total / 1024, out))
        if args.zip:
            log("zip: %s" % write_zip(out))
        return 0
    except PackageError as e:
        print("package: " + str(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
