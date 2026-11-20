#!/usr/bin/env bash
# Builds a game's whole console folder on Linux, with no PC of the developer involved: the xsdk
# toolchain, xsdk, LuaJIT for xsdk, the .xex, the shaders (xost for Linux) and the package with
# the .ogg files converted to the console's WAV files. Used by .github/workflows/console.yml;
# also runs on any Debian/Ubuntu machine (or WSL).
#
#   tools/ci/build_console.sh <game folder> [output folder]
#   tools/ci/build_console.sh --tools-only     (only the toolchain, xost and xsdk: for CI caches)
#
# Output: <output>/<identity>/ (the folder that goes to Hdd1:/Games/) and <output>/<identity>.zip.
# Default output: dist/.
#
# Environment (all optional):
#   CI_CACHE         where the toolchain, xsdk and glslang live (default ~/.cache/360pc-ci).
#                    Keep it between runs: the toolchain takes about an hour on 4 cores.
#   JOBS             parallel jobs (default: nproc)
#   L360_RELEASE     ON for a release build of the runtime (short log). Default OFF.
#
# Requirements (Ubuntu 24.04): build-essential bison flex texinfo libgmp-dev libmpfr-dev
# libmpc-dev curl xz-utils patch gcc-multilib g++-multilib cmake ninja-build git python3
# luajit ffmpeg.
set -euo pipefail

TOOLS_ONLY=0
if [[ ${1:-} == --tools-only && $# -eq 1 ]]; then
    TOOLS_ONLY=1
elif [[ $# -lt 1 || $# -gt 2 || ${1:-} == -* ]]; then
    echo "usage: $0 <game folder> [output folder] | $0 --tools-only" >&2
    exit 2
fi
ROOT=$(cd -- "$(dirname -- "$0")/../.." && pwd)
if [[ $TOOLS_ONLY == 0 ]]; then
    GAME=$(cd -- "$1" && pwd)
    OUT=${2:-$ROOT/dist}
    mkdir -p "$OUT"
    OUT=$(cd -- "$OUT" && pwd)
fi
CI_CACHE=${CI_CACHE:-$HOME/.cache/360pc-ci}
JOBS=${JOBS:-$(nproc)}
L360_RELEASE=${L360_RELEASE:-OFF}

XSDK_URL=https://github.com/xenosworks/xsdk.git
XSDK_COMMIT=$(sed -n 2p "$ROOT/runtime/XSDK_VERSION" | tr -d '[:space:]')
GLSLANG_URL=https://github.com/xenosworks/glslang-xenon.git
GLSLANG_COMMIT=$(python3 -c "import re,sys; print(re.search(r'GLSLANG_VERSION\s*=\s*\"([0-9a-f]{40})\"', open(sys.argv[1]).read()).group(1))" \
    "$ROOT/tools/shaders/xost_windows/build.py")

XSDK=$CI_CACHE/xsdk
TOOLCHAIN=$CI_CACHE/xsdk-gcc
GLSLANG_SRC=$CI_CACHE/glslang-xenon
XOST=$CI_CACHE/xost-linux
BUILD=$ROOT/build/ci
mkdir -p "$CI_CACHE" "$BUILD"

step() { echo; echo "== $* ($(date -u +%H:%M:%S))"; }

# Clones <url> into <dir> at <commit>, or checks an existing clone out at it.
checkout() {
    local url=$1 dir=$2 commit=$3
    if [[ ! -d $dir/.git ]]; then
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" remote add origin "$url"
    fi
    if [[ $(git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null || true) != "$commit" ]]; then
        git -C "$dir" fetch -q --depth 1 origin "$commit"
        git -C "$dir" checkout -q --force "$commit"
    fi
}

# Reads a field of game.lua through the repository's reader.
game_field() { luajit "$ROOT/tools/read_game_config.lua" "$GAME" "$1"; }

if [[ $TOOLS_ONLY == 0 ]]; then
    step "game: $GAME"
    TITLE_ID=$(game_field title_id)
    NAME=$(game_field name)
    IDENTITY=$(game_field identity)
    [[ -n $TITLE_ID && -n $NAME && -n $IDENTITY ]] || { echo "game.lua needs title_id, name and identity" >&2; exit 1; }
    echo "title_id=$TITLE_ID name=$NAME identity=$IDENTITY"
fi

step "xsdk $XSDK_COMMIT"
checkout "$XSDK_URL" "$XSDK" "$XSDK_COMMIT"

step "xsdk toolchain (GCC for powerpc-xsdk-elf) in $TOOLCHAIN"
STAMP=$TOOLCHAIN/.built-for-$XSDK_COMMIT
if [[ -x $TOOLCHAIN/bin/powerpc-xsdk-elf-gcc && -f $STAMP ]]; then
    echo "cached: $("$TOOLCHAIN/bin/powerpc-xsdk-elf-gcc" --version | head -1)"
else
    WORK=$CI_CACHE/xsdk-gcc-work
    if ! (cd "$XSDK" && PREFIX="$TOOLCHAIN" WORK="$WORK" JOBS="$JOBS" bash tools/toolchain/build.sh); then
        echo "toolchain build failed; last lines of each log:" >&2
        for f in "$WORK"/logs/*; do [[ -f $f ]] || continue; echo "--- $f" >&2; tail -n 40 "$f" >&2; done
        exit 1
    fi
    rm -rf "$WORK"
    touch "$STAMP"
fi

step "glslang-xenon $GLSLANG_COMMIT and xost for Linux in $XOST"
if [[ -f $XOST/versions.json ]] && grep -q "$XSDK_COMMIT" "$XOST/versions.json" \
        && grep -q "$GLSLANG_COMMIT" "$XOST/versions.json"; then
    echo "cached"
else
    checkout "$GLSLANG_URL" "$GLSLANG_SRC" "$GLSLANG_COMMIT"
    (cd "$GLSLANG_SRC" && python3 update_glslang_sources.py)
    python3 "$ROOT/tools/shaders/xost_windows/build.py" --native --cc gcc --cxx g++ \
        --xsdk "$XSDK" --glslang-src "$GLSLANG_SRC" --out "$XOST" \
        --build "$CI_CACHE/glslang-build" --jobs "$JOBS"
    rm -rf "$CI_CACHE/glslang-build"
fi
# xsdk's CMake looks for glslang beside the toolchain (XSDK_GLSLANG).
cp -f "$XOST/glslang" "$TOOLCHAIN/bin/glslang"

step "xsdk (libxsdk.a)"
make -C "$XSDK" -j"$JOBS" TOOLCHAIN="$TOOLCHAIN/bin/powerpc-xsdk-elf-" >"$BUILD/xsdk_make.log" 2>&1 \
    || { tail -n 60 "$BUILD/xsdk_make.log" >&2; exit 1; }
tail -n 3 "$BUILD/xsdk_make.log"
if [[ $TOOLS_ONLY == 1 ]]; then
    step "tools ready in $CI_CACHE"
    exit 0
fi

step "LuaJIT for xsdk"
XSDK_TOOLCHAIN="$TOOLCHAIN" bash "$ROOT/toolchain/build_luajit_xsdk.sh"

step ".xex ($NAME, $TITLE_ID, release=$L360_RELEASE)"
XEX_BUILD=$BUILD/runtime-$IDENTITY
cmake -S "$ROOT/runtime" -B "$XEX_BUILD" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$XSDK/cmake/xsdk.cmake" -DXSDK_TOOLCHAIN="$TOOLCHAIN" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DL360_RELEASE="$L360_RELEASE" \
    -DGAME_TITLE_ID="$TITLE_ID" -DGAME_NAME="$NAME"
cmake --build "$XEX_BUILD" -j "$JOBS"
XEX=$XEX_BUILD/game.xex
[[ -f $XEX ]] || { echo "no $XEX after the build" >&2; exit 1; }

step "shaders"
SHADERS=$BUILD/shaders-$IDENTITY
rm -rf "$SHADERS"
python3 "$ROOT/tools/shaders/build_shaders.py" "$GAME" --tools "$XOST" --out "$SHADERS"

step "package (with .ogg converted to WAV)"
python3 "$ROOT/tools/package.py" "$GAME" --xex "$XEX" --shaders "$SHADERS" \
    --out "$OUT/$IDENTITY" --zip --force --audio-cache "$CI_CACHE/audio/$IDENTITY"

step "done"
echo "folder: $OUT/$IDENTITY"
echo "zip:    $OUT/$IDENTITY.zip"
sha256sum "$OUT/$IDENTITY/default.xex"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    { echo "identity=$IDENTITY"; echo "folder=$OUT/$IDENTITY"; } >>"$GITHUB_OUTPUT"
fi
