#!/usr/bin/env python3
"""
360PC-Engine - builds a game's shaders for the Xbox 360 (docs/SHADERS.md).

    python tools/shaders/build_shaders.py <game folder> --out <folder> --tools <xost folder>
    python tools/shaders/build_shaders.py <game folder> --out <folder> --hlsl-only

Reads the `shaders` table of the game's game.lua, translates each GLSL shader to HLSL
(glsl2hlsl.py) and compiles it with xost. Writes into --out, for the console's shaders\\ folder:
    <name>.psu / <name>.vsu   the stages the shader has (the "L3X1" header with xost's literals,
                              big-endian, followed by the xost container)
    <name>.meta.lua           uniforms -> registers, read by the runtime
    l360_*.psu / l360_*.vsu   the engine's own shaders (runtime/shaders/*.hlsl)
--tools is the folder with xsc.dll, glslang.exe and _xsc_native.py (tools/shaders/xost_windows/
builds it; on Linux, libxsc.so and glslang). Nothing is written unless every shader compiled.
--hlsl-only needs no compiler: it writes the translated .hlsl and the .meta.lua, to look at them.

game.lua is read with LuaJIT (tools/read_game_config.lua): `luajit` on the PATH, or --lua <exe>.
Without Lua, give the shaders by hand instead of the game folder:
    --shader name=shaders/x.glsl   or   --shader name=shaders/x.frag,shaders/x.vert   --base <game folder>
Standard Python 3.9 or later, no packages.
"""
import argparse
import importlib.util
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
import glsl2hlsl


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def declared_shaders(game, lua=None):
    """game.lua's shaders -> [(name, pixel path or None, vertex path or None)], through LuaJIT"""
    exe = lua or next((e for e in ("luajit", "lua5.1", "lua") if shutil.which(e)), None)
    if not exe:
        raise RuntimeError("LuaJIT not found (needed to read game.lua): install it, or use --lua or --shader")
    r = subprocess.run([exe, str(ROOT / "tools/read_game_config.lua"), str(game), "shaders"],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip())
    out = []
    for line in r.stdout.splitlines():
        name, pixel, vertex = (line.split("\t") + ["", ""])[:3]
        out.append((name, pixel or None, vertex or None))
    return out


def translate_all(shaders, base, log=print):
    """[(name, pixel path, vertex path)] -> ({file name: HLSL}, {file name: meta text}); raises
    RuntimeError with every shader that could not be translated"""
    hlsl, metas, failures = {}, {}, []
    read = lambda p: (Path(base) / p).read_text(encoding="utf-8-sig") if p else None
    for name, pixel, vertex in shaders:
        try:
            r = glsl2hlsl.translate(name, read(pixel), read(vertex))
        except (OSError, UnicodeError, glsl2hlsl.ShaderError) as e:
            failures.append(str(e) if isinstance(e, glsl2hlsl.ShaderError) else "%s: %s" % (name, e))
            log("ERROR " + failures[-1])
            continue
        for stage in ("ps", "vs"):
            if r[stage]:
                hlsl["%s_%s.hlsl" % (name, stage)] = r[stage]
        metas[name + ".meta.lua"] = glsl2hlsl.meta_lua(r["meta"])
    if failures:
        raise RuntimeError("%d of %d shaders could not be translated.\n%s"
                           % (len(failures), len(shaders), "\n".join(failures)))
    return hlsl, metas


def builtin_hlsl():
    """the engine's own shaders, with the xost rules"""
    return {p.name: glsl2hlsl.for_xost(p.read_text(encoding="utf-8-sig"))
            for p in sorted((ROOT / "runtime/shaders").glob("*.hlsl"))}


def compile_all(hlsl, tools, log=print):
    """{"x_ps.hlsl" / "x_vs.hlsl": HLSL} -> {"x.psu" / "x.vsu": bytes}, with xost"""
    tools = Path(tools).resolve()
    library = tools / ("xsc.dll" if os.name == "nt" else "libxsc.so")
    glslang = tools / ("glslang.exe" if os.name == "nt" else "glslang")
    bridge = tools / "_xsc_native.py"
    for f in (library, glslang, bridge):
        if not f.is_file():
            raise RuntimeError("shader compiler not found: %s (see tools/shaders/xost_windows/README.md)" % f)
    native = load_module(bridge, "_l360_xsc_native")
    native.LIBRARY = library
    out, failures = {}, []
    with tempfile.TemporaryDirectory(prefix="l360-shaders-") as tmp:
        tmp = Path(tmp)
        for i, (source, text) in enumerate(sorted(hlsl.items()), 1):
            try:
                stage, ext = ("frag", ".psu") if source.endswith("_ps.hlsl") else ("vert", ".vsu")
                src, spv = tmp / "shader.hlsl", tmp / "shader.spv"
                src.write_text(text, encoding="utf-8")
                r = subprocess.run([str(glslang), "-D", "-V", "--hlsl-dx9-compatible",
                                    "-fhlsl_functionality1", "-S", stage, "-e", "main", str(src),
                                    "-o", str(spv)], capture_output=True, text=True,
                                   encoding="utf-8", errors="replace",
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                if r.returncode:
                    raise RuntimeError("glslang: " + (r.stdout + r.stderr).strip())
                container, manifest, _ = native.compile_spirv(spv.read_bytes(), 64, 64, optimize=True)
                if any(len(need) != 2 for need in manifest):
                    raise RuntimeError("xost requires constants the runtime cannot load: %r" % (manifest,))
                data = b"L3X1" + struct.pack(">I", len(manifest))
                for reg, values in manifest:
                    if not 0 <= reg < (252 if stage == "frag" else 256):
                        raise RuntimeError("literal outside the allowed constant registers")
                    data += struct.pack(">I4f", reg, *values)
                out[source[:-8] + ext] = data + container
                log("[%d/%d] OK %s" % (i, len(hlsl), source))
            except (OSError, ValueError, RuntimeError, native.CompileError) as e:
                status = (" (%s)" % native.STATUS_NAMES[e.status]) if isinstance(e, native.CompileError) else ""
                failures.append("%s%s: %s" % (source, status, e))
                log("[%d/%d] ERROR %s" % (i, len(hlsl), failures[-1]))
    if failures:
        raise RuntimeError("Nothing written: %d of %d shaders failed to compile.\n%s"
                           % (len(failures), len(hlsl), "\n".join(failures)))
    return out


def publish(files, out):
    """{name: str or bytes} -> files in `out`, each one replaced atomically"""
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for name, data in sorted(files.items()):
        if isinstance(data, str):
            data = data.encode("utf-8")
        fd, pending = tempfile.mkstemp(dir=out, prefix=".l360-")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
            os.replace(pending, out / name)
        finally:
            Path(pending).unlink(missing_ok=True)


def build(shaders, base, out, tools=None, hlsl_only=False, log=print):
    hlsl, metas = translate_all(shaders, base, log)
    if hlsl_only:
        publish({**hlsl, **metas}, out)
        return sorted(list(hlsl) + list(metas))
    compiled = compile_all({**builtin_hlsl(), **hlsl}, tools, log)
    publish({**compiled, **metas}, out)
    return sorted(list(compiled) + list(metas))


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(description="Build a game's shaders for the Xbox 360 (docs/SHADERS.md).")
    p.add_argument("game", type=Path, nargs="?", help="game folder (with game.lua)")
    p.add_argument("--out", type=Path, required=True, help="output folder (the console's shaders\\ folder)")
    p.add_argument("--tools", type=Path, help="folder with xsc.dll, glslang.exe and _xsc_native.py")
    p.add_argument("--hlsl-only", action="store_true", help="translate only: write .hlsl and .meta.lua")
    p.add_argument("--lua", help="LuaJIT executable used to read game.lua (default: luajit on the PATH)")
    p.add_argument("--shader", action="append", default=[], metavar="NAME=GLSL[,GLSL]",
                   help="a shader given by hand instead of game.lua (one file, or pixel,vertex)")
    p.add_argument("--base", type=Path, help="folder the --shader paths are relative to")
    args = p.parse_args()
    if bool(args.game) == bool(args.shader):
        p.error("give the game folder or --shader")
    if not args.hlsl_only and not args.tools:
        p.error("--tools is required (or --hlsl-only)")
    try:
        if args.shader:
            shaders = []
            for s in args.shader:
                name, _, paths = s.partition("=")
                paths = paths.split(",")
                if not paths[0] or len(paths) > 2:
                    p.error("--shader takes name=file or name=pixel_file,vertex_file")
                shaders.append((name, paths[0], paths[1] if len(paths) == 2 else paths[0]))
            base = args.base or Path(".")
        else:
            shaders, base = declared_shaders(args.game, args.lua), args.game
        written = build(shaders, base, args.out, args.tools, args.hlsl_only)
    except (OSError, ValueError, RuntimeError) as e:
        print("ERROR: %s" % e, file=sys.stderr)
        return 1
    print("%d shaders declared, %d files written to %s" % (len(shaders), len(written), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
