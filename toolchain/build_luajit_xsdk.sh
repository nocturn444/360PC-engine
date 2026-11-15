#!/bin/bash
# Love360 - downloads LuaJIT 2.1 and builds the interpreter for the xsdk .xex (runtime/).
# Leaves third_party/luajit_xsdk/src/libluajit.a, which is what runtime/CMakeLists.txt links.
# It is a separate tree from third_party/luajit (the libXenon one): the two versions do not clash.
#
# Requires: the xsdk toolchain (xsdk's tools/toolchain/build.sh) in $XSDK_TOOLCHAIN
#           (defaults to ~/xsdk-gcc, the same one cmake/xsdk.cmake uses)
#           and gcc with 32-bit support on the PC (gcc-multilib package), because buildvm
#           has to run in 32 bits to generate the 32-bit PowerPC interpreter.
#
# Test without xsdk: CROSS=powerpc-linux-gnu- toolchain/build_luajit_xsdk.sh builds everything with Debian/Ubuntu's
# PowerPC gcc. Useful to check that the interpreter is generated with these options, but that
# library does NOT work on the console (different calling convention) and the checks below are skipped.
set -e
cd "$(dirname "$0")/.."
XSDK_TOOLCHAIN=${XSDK_TOOLCHAIN:-$HOME/xsdk-gcc}
export PATH=$XSDK_TOOLCHAIN/bin:$PATH
CROSS=${CROSS:-powerpc-xsdk-elf-}

# Fixed commit: toolchain/luajit_xsdk.patch is made against this one. To change it, a PR of its own that
# redoes the patch and runs tests/console/number_check.lua on the console again.
LUAJIT_COMMIT=a4c064539ea931274d407e1249b4bb575424a0f4
PATCH="$PWD/toolchain/luajit_xsdk.patch"
mkdir -p third_party
if [ ! -d third_party/luajit_xsdk ]; then
    git clone --depth 1 -b v2.1 https://github.com/LuaJIT/LuaJIT.git third_party/luajit_xsdk
fi
cd third_party/luajit_xsdk
if [ "$(git rev-parse HEAD)" != "$LUAJIT_COMMIT" ]; then
    git checkout -- . && git fetch --depth 1 origin "$LUAJIT_COMMIT" && git checkout -q "$LUAJIT_COMMIT"
fi
echo "LuaJIT: $(git rev-parse HEAD)"
# Patch for xsdk (interpreter fixes for GPR64; see the header of luajit_xsdk.patch)
if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "Patch luajit_xsdk.patch: already applied"
else
    git apply "$PATCH"
    echo "Patch luajit_xsdk.patch: applied"
fi

# Why each option (the usual ones are explained in build_luajit.sh):
#   _XBOX_VER=200    LuaJIT already has support for the 360 (the one from xedkbuild.bat, made for the XDK). With
#                    this it builds the same way: 64-bit registers with 32-bit pointers (LJ_ARCH_PPC32ON64),
#                    the 360 frame offsets in lj_frame.h, and in buildvm the symbols without "_".
#                    Needed on both sides: in the cross compiler and in the PC one (buildvm).
#   -D GPR64 (only)  the Makefile adds it when it sees LJ_ARCH_PPC32ON64: the interpreter saves r14-r31
#                    whole (std/ld). xsdk uses the 360 calling convention (-mcall-xsdk), in
#                    which C leaves 64-bit values in r14-r31: if the interpreter saved 32 bits
#                    (as in libXenon) the high halves would be lost when returning to C.
#   FRAME32          the 360's 32-bit frame: 64-byte parameter area at 16(sp), which is
#                    where xsdk C may write (xsdk's docs/HARDWARE.md, "The console's
#                    calling convention"). Without this the interpreter uses the PS3 frame and they clobber each other.
#   PPE              no mcrxr, as in libXenon.
#   MODE32           (added by luajit_xsdk.patch) the console runs titles in 32-bit mode
#                    (MSR[SF]=0, xsdk's docs/HARDWARE.md): integer overflow is detected with the
#                    32-bit instructions, not with the GPR64 trick (which assumes 64-bit mode).
#   -mcpu=cell -fno-pic  the ones from cmake/xsdk.cmake. -m32 and -mpowerpc64 are already set by the compiler.
#   (SQRT and DUALNUM are added by the Makefile on their own: -mcpu=cell defines _ARCH_PPCSQ.)
X="-DLUAJIT_DISABLE_JIT -DLUAJIT_DISABLE_FFI -DLUAJIT_USE_SYSMALLOC -DLUAJIT_SECURITY_PRNG=0 -DLUAJIT_DISABLE_PROFILE -DLUAJIT_NO_UNWIND"
make -C src clean >/dev/null
make -C src libluajit.a HOST_CC="gcc -m32 -D_XBOX_VER=200" CROSS="$CROSS" TARGET_SYS=Other BUILDMODE=static \
    DASM_XFLAGS="-D FRAME32 -D PPE -D MODE32" TARGET_CFLAGS="-D_XBOX_VER=200 -O2 -mcpu=cell -fno-pic" XCFLAGS="$X"

if [ "$CROSS" != "powerpc-xsdk-elf-" ]; then
    echo "Built with $CROSS: test only, do not copy to the console."
    exit 0
fi
OBJDUMP=${CROSS}objdump
# Check: the interpreter was generated for the 360 (384-byte frame: stwu sp,-384(sp) on entry)
n=$($OBJDUMP -d src/libluajit.a | grep -cE "stwu +r?1,-384\(r?1\)" || true)
echo "Interpreter entries with the 360 frame: $n (must be more than 0)"
[ "$n" != "0" ]
# Check: the patch is in the generated interpreter (num2int returns the right value: clrldi r3,r4,32)
p=$($OBJDUMP -d src/libluajit.a | grep -cE "(clrldi +r?3,r?4,32|rldicl +r?3,r?4,0,32)" || true)
echo "lj_vm_num2int_check with the patch: $p (must be more than 0)"
[ "$p" != "0" ]
# Check: no thread variables (xsdk compiles without TLS: __thread would go through emutls)
t=$($OBJDUMP -t src/libluajit.a | grep -c "__emutls" || true)
echo "__thread variables in libluajit.a: $t (must be 0)"
[ "$t" = "0" ]
# Check: no mcrxr instructions (it does not exist on the Xenon)
m=$($OBJDUMP -d src/libluajit.a | grep -c mcrxr || true)
echo "mcrxr instructions in libluajit.a: $m (must be 0)"
[ "$m" = "0" ]
