#!/usr/bin/env bash
# Builds the xost shader compiler for Windows x64 from Linux (README.md in this folder).
# Linux: apt install mingw-w64 cmake ninja-build git python3
# Usage: TOOLCHAIN_NOTICES=<folder> build.sh <xsdk> <glslang-xenon> <output> [build folder]
# The sources are fetched by whoever builds the tools; nothing is downloaded here.
set -euo pipefail
: "${TOOLCHAIN_NOTICES:?set TOOLCHAIN_NOTICES=folder with the MinGW/GCC notices (see README.md)}"
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "usage: $0 <xsdk> <glslang-xenon> <output> [build folder]" >&2
    exit 2
fi
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
python3 "$HERE/build.py" --xsdk "$1" --glslang-src "$2" --out "$3" \
    --build "${4:-$3/build-glslang}" --cc "${CC:-x86_64-w64-mingw32-gcc}" \
    --cxx "${CXX:-x86_64-w64-mingw32-g++}" --jobs "${JOBS:-4}" \
    --toolchain-notices "$TOOLCHAIN_NOTICES"
