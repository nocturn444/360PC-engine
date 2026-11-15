# Love360 sobre xsdk: Balatro como un .xex que se abre desde Aurora (docs/tareas/05_port_xsdk.md).
# Hecho a partir de samples/template de xsdk. Antes: toolchain/build_luajit_xsdk.sh (deja libluajit.a).
# Compilar (en Linux o WSL, con xsdk armado con make como dice su docs/GETTING_STARTED.md):
#   cmake -S runtime_xsdk -B runtime_xsdk/build -G Ninja -DCMAKE_TOOLCHAIN_FILE=<xsdk>/cmake/xsdk.cmake \
#     -DXSDK_TOOLCHAIN=<prefijo> -DCMAKE_BUILD_TYPE=RelWithDebInfo
#   cmake --build runtime_xsdk/build
# Sale runtime_xsdk/build/love360.xex: en la consola va como Love360\default.xex (ver README.md de esta carpeta).
cmake_minimum_required(VERSION 3.25)
project(love360 C)

set(LUAJIT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/luajit_xsdk/src" CACHE PATH
	"LuaJIT compilado con el GCC de xsdk (toolchain/build_luajit_xsdk.sh)")
if(NOT EXISTS "${LUAJIT}/libluajit.a")
	message(FATAL_ERROR "Falta ${LUAJIT}/libluajit.a: correr antes toolchain/build_luajit_xsdk.sh")
endif()

# main.c primero: un .o antes de main.c en el enlace hace fallar a elf2xex ("section .init overlaps
# the PE headers", fase 1). l360_gfx.c usa stb_image y stb_truetype de runtime/source (sin copiarlos).
add_executable(love360 main.c l360_gfx.c l360_sys.c l360_audio.c l360_importar.c)
set_target_properties(love360 PROPERTIES C_STANDARD 17 C_EXTENSIONS ON)
target_compile_options(love360 PRIVATE -Wall -Wextra -Werror)
target_include_directories(love360 PRIVATE "${LUAJIT}" "${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb")
target_link_libraries(love360 PRIVATE "${LUAJIT}/libluajit.a")
# Version publicada (tarea 12): -DL360_PUBLICADO=ON deja el registro corto (solo errores, resumenes y
# [tiron]; ver main.c). En game:\l360_gfx.txt, registro_completo lo vuelve a dejar entero.
option(L360_PUBLICADO "Version publicada: registro corto" OFF)
if(L360_PUBLICADO)
	target_compile_definitions(love360 PRIVATE L360_REGISTRO_CORTO=1)
endif()
# Title ID propio y fijo (anotado en AGENTS.md): separa los guardados del sistema y lo que Aurora
# recuerda del juego. "LV" + 0360. No cambiarlo sin avisar: Aurora lo trataria como otro juego.
xsdk_add_xex(love360 TITLE_ID 0x4C560360 NAME "Balatro (Love360)")
