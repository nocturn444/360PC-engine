#!/bin/bash
# Love360 - baja LuaJIT 2.1 y compila el interprete para el .xex de xsdk (runtime/).
# Deja third_party/luajit_xsdk/src/libluajit.a, que es lo que enlaza runtime/CMakeLists.txt.
# Es un arbol aparte de third_party/luajit (el de libXenon): las dos versiones no se pisan.
#
# Necesita: el toolchain de xsdk (tools/toolchain/build.sh de xsdk) en $XSDK_TOOLCHAIN
#           (por defecto ~/xsdk-gcc, el mismo que usa cmake/xsdk.cmake)
#           y gcc con soporte de 32 bits en la PC (paquete gcc-multilib), porque buildvm
#           tiene que correr en 32 bits para generar el interprete de PowerPC de 32 bits.
#
# Prueba sin xsdk: CROSS=powerpc-linux-gnu- toolchain/build_luajit_xsdk.sh arma todo con el gcc de
# PowerPC de Debian/Ubuntu. Sirve para ver que el interprete se genera con estas opciones, pero esa
# biblioteca NO sirve para la consola (otra convencion de llamadas) y los controles de abajo se saltean.
set -e
cd "$(dirname "$0")/.."
XSDK_TOOLCHAIN=${XSDK_TOOLCHAIN:-$HOME/xsdk-gcc}
export PATH=$XSDK_TOOLCHAIN/bin:$PATH
CROSS=${CROSS:-powerpc-xsdk-elf-}

# Commit fijo: toolchain/luajit_xsdk.patch esta hecho sobre este. Para cambiarlo, PR propio que
# rehaga el parche y vuelva a pasar tests/console/xsdk_numeros.lua en la consola.
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
# Parche para xsdk (arreglos del interprete con GPR64; ver el encabezado de luajit_xsdk.patch)
if git apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "Parche luajit_xsdk.patch: ya aplicado"
else
    git apply "$PATCH"
    echo "Parche luajit_xsdk.patch: aplicado"
fi

# Por que cada opcion (las de siempre estan explicadas en build_luajit.sh):
#   _XBOX_VER=200    LuaJIT ya trae soporte para la 360 (el de xedkbuild.bat, hecho para el XDK). Con
#                    esto se arma igual: registros de 64 bits con punteros de 32 (LJ_ARCH_PPC32ON64),
#                    los offsets de marco de la 360 en lj_frame.h, y en buildvm los simbolos sin "_".
#                    Hace falta en los dos lados: en el compilador cruzado y en el de la PC (buildvm).
#   -D GPR64 (solo)  lo agrega el Makefile al ver LJ_ARCH_PPC32ON64: el interprete guarda r14-r31
#                    enteros (std/ld). xsdk usa la convencion de llamadas de la 360 (-mcall-xsdk), en
#                    la que el C deja valores de 64 bits en r14-r31: si el interprete guardara 32 bits
#                    (como en libXenon) se perderian las mitades altas al volver a C.
#   FRAME32          marco de 32 bits de la 360: area de parametros de 64 bytes en 16(sp), que es
#                    donde un C de xsdk puede escribir (docs/HARDWARE.md de xsdk, "The console's
#                    calling convention"). Sin esto el interprete usa el marco de la PS3 y se pisan.
#   PPE              sin mcrxr, como en libXenon.
#   MODE32           (lo agrega luajit_xsdk.patch) la consola corre los titulos en modo de 32 bits
#                    (MSR[SF]=0, docs/HARDWARE.md de xsdk): el desborde de enteros se detecta con las
#                    instrucciones de 32 bits, no con el truco de GPR64 (que supone modo de 64 bits).
#   -mcpu=cell -fno-pic  las de cmake/xsdk.cmake. -m32 y -mpowerpc64 ya los pone el compilador.
#   (SQRT y DUALNUM los agrega el Makefile solo: -mcpu=cell define _ARCH_PPCSQ.)
X="-DLUAJIT_DISABLE_JIT -DLUAJIT_DISABLE_FFI -DLUAJIT_USE_SYSMALLOC -DLUAJIT_SECURITY_PRNG=0 -DLUAJIT_DISABLE_PROFILE -DLUAJIT_NO_UNWIND"
make -C src clean >/dev/null
make -C src libluajit.a HOST_CC="gcc -m32 -D_XBOX_VER=200" CROSS="$CROSS" TARGET_SYS=Other BUILDMODE=static \
    DASM_XFLAGS="-D FRAME32 -D PPE -D MODE32" TARGET_CFLAGS="-D_XBOX_VER=200 -O2 -mcpu=cell -fno-pic" XCFLAGS="$X"

if [ "$CROSS" != "powerpc-xsdk-elf-" ]; then
    echo "Armado con $CROSS: solo prueba, no copiar a la consola."
    exit 0
fi
OBJDUMP=${CROSS}objdump
# Control: el interprete se genero para la 360 (marco de 384 bytes: stwu sp,-384(sp) al entrar)
n=$($OBJDUMP -d src/libluajit.a | grep -cE "stwu +r?1,-384\(r?1\)" || true)
echo "Entradas al interprete con el marco de la 360: $n (tiene que ser mas de 0)"
[ "$n" != "0" ]
# Control: el parche esta en el interprete generado (num2int devuelve lo correcto: clrldi r3,r4,32)
p=$($OBJDUMP -d src/libluajit.a | grep -cE "(clrldi +r?3,r?4,32|rldicl +r?3,r?4,0,32)" || true)
echo "lj_vm_num2int_check con el parche: $p (tiene que ser mas de 0)"
[ "$p" != "0" ]
# Control: ninguna variable de hilo (xsdk compila sin TLS: __thread pasaria por emutls)
t=$($OBJDUMP -t src/libluajit.a | grep -c "__emutls" || true)
echo "Variables __thread en libluajit.a: $t (tiene que ser 0)"
[ "$t" = "0" ]
# Control: ninguna instruccion mcrxr (no existe en el Xenon)
m=$($OBJDUMP -d src/libluajit.a | grep -c mcrxr || true)
echo "Instrucciones mcrxr en libluajit.a: $m (tiene que ser 0)"
[ "$m" = "0" ]
