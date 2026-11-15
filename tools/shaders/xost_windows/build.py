#!/usr/bin/env python3
"""Builds the xost shader compiler (xsc.dll, glslang.exe); build.sh picks Linux's cross compiler.
Usage and what it checks: README.md in this folder."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from licenses import build_notices

GLSLANG_VERSION = "d2f00185cf5feaa449f6e15c1894fb232b2b6bcd"


def run(args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def check_tree(path, revision):
    head = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if head != revision:
        raise SystemExit("Wrong revision in %s: %s, %s is required" % (path, head, revision))
    run(["git", "-C", path, "diff", "--exit-code", "HEAD", "--"])


def variable(text, name):
    # Continuation lines of the Makefile are indented; do not include the next variable.
    value = re.search(r"^" + name + r" := (.*(?:\n[ \t]+.*)*)", text, re.M).group(1)
    return value.replace("\\\n", " ").split()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--xsdk", type=Path, required=True)
    p.add_argument("--glslang-src", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--build", type=Path, required=True)
    p.add_argument("--cc", default="x86_64-w64-mingw32-gcc")
    p.add_argument("--cxx", default="x86_64-w64-mingw32-g++")
    p.add_argument("--native", action="store_true", help="build for this machine: Linux tools, or building on Windows")
    p.add_argument("--jobs", type=int, default=4)
    p.add_argument("--cmake", default="cmake")
    p.add_argument("--ninja", default="ninja")
    p.add_argument("--toolchain-notices", type=Path, help="folder with the notices of the MinGW/GCC runtime that is linked in")
    args = p.parse_args()
    root = Path(__file__).resolve().parents[3]
    sdk, glslang = args.xsdk.resolve(), args.glslang_src.resolve()
    version = (root / "runtime/XSDK_VERSION").read_text().splitlines()[1].strip()
    check_tree(sdk, version)
    check_tree(glslang, GLSLANG_VERSION)
    # OPT=OFF leaves calls and local variables that xost cannot lower.
    known = json.loads((glslang / "known_good.json").read_text())
    for repo in known["commits"]:
        if "spirv" in repo["name"].lower():
            check_tree(glslang / repo["subdir"], repo["commit"])
    text = (sdk / "Makefile").read_text()
    sources, headers = variable(text, "XSC_SOURCES"), variable(text, "XSC_HEADERS")
    version_hash = hashlib.sha256(b"".join((sdk / f).read_bytes().replace(b"\r", b"")
                                          for f in sources + headers)).hexdigest()[:16]
    out, build = args.out.resolve(), args.build.resolve()
    out.mkdir(parents=True, exist_ok=True)
    build.mkdir(parents=True, exist_ok=True)
    windows = not args.native or os.name == "nt"
    if windows and not args.toolchain_notices:
        raise SystemExit("A Windows build needs --toolchain-notices (see README.md)")
    # Validate the texts before spending time on the build.
    notices = build_notices(sdk, glslang, args.toolchain_notices)
    library = out / ("xsc.dll" if windows else "libxsc.so")
    cc, cxx = shutil.which(args.cc), shutil.which(args.cxx)
    if not cc or not cxx:
        raise SystemExit("Compiler not found: %s / %s (mingw-w64 for a Windows build)" % (args.cc, args.cxx))
    run([cc, "-O2", "-std=gnu17", "-ffp-contract=off", "-shared", "-Iinclude", "-Isrc",
         '-DXSDK_XSC_SOURCE_HASH="%s"' % version_hash, "-o", library, *sources,
         *(["-static-libgcc", "-Wl,--export-all-symbols"] if windows else ["-fPIC", "-lm"])], cwd=sdk)
    configure = [args.cmake, "-S", glslang, "-B", build, "-G", "Ninja",
                 "-DCMAKE_MAKE_PROGRAM=" + str(Path(shutil.which(args.ninja) or args.ninja).resolve()),
                 "-DCMAKE_C_COMPILER=" + cc, "-DCMAKE_CXX_COMPILER=" + cxx,
                 "-DCMAKE_BUILD_TYPE=Release", "-DENABLE_OPT=ON", "-DBUILD_SHARED_LIBS=OFF",
                 "-DGLSLANG_TESTS=OFF", "-DSPIRV_SKIP_EXECUTABLES=ON", "-DSPIRV_SKIP_TESTS=ON"]
    if windows:
        configure += ["-DCMAKE_EXE_LINKER_FLAGS=-static"]
    if not args.native:
        configure += ["-DCMAKE_SYSTEM_NAME=Windows", "-DCMAKE_SYSTEM_PROCESSOR=AMD64"]
    run(configure)
    # When reusing a build with another compiler, CMake clears the cache and loses
    # the -D flags of the first pass. Reapply them before building (Release,
    # static linking and OPT included), even if only the case of .exe changed.
    run(configure)
    run([args.cmake, "--build", build, "--target", "glslang-standalone", "-j", str(args.jobs)])
    exe = "glslang.exe" if windows else "glslang"
    shutil.copy2(build / "StandAlone" / exe, out / exe)
    shutil.copy2(sdk / "xenos-toolchain/xsc/native.py", out / "_xsc_native.py")
    (out / "THIRD_PARTY_NOTICES.txt").write_text(notices, encoding="utf-8", newline="\n")
    metadata = {"xsdk": version, "xsc_hash": version_hash, "glslang": GLSLANG_VERSION,
                "glslang_opt": True,
                "cc": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
                "cxx": subprocess.check_output([cxx, "--version"], text=True).splitlines()[0],
                "sha256": {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                           for name in [library.name, exe, "_xsc_native.py", "THIRD_PARTY_NOTICES.txt"]}}
    (out / "versions.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
