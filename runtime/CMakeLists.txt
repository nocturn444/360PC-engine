# 360PC-Engine console runtime: one .xex per game, opened from Aurora. Same source for every game;
# the Title ID and the name come from the game's game.lua (docs/GAME_CONFIG.md).
# Made from xsdk's samples/template. First: toolchain/build_luajit_xsdk.sh (builds libluajit.a).
# Build (Linux or WSL, with xsdk built with make as its docs/GETTING_STARTED.md says):
#   cmake -S runtime -B runtime/build -G Ninja -DCMAKE_TOOLCHAIN_FILE=<xsdk>/cmake/xsdk.cmake \
#     -DXSDK_TOOLCHAIN=<prefix> -DCMAKE_BUILD_TYPE=RelWithDebInfo \
#     -DGAME_TITLE_ID="$(luajit tools/read_game_config.lua <game> title_id)" \
#     -DGAME_NAME="$(luajit tools/read_game_config.lua <game> name)"
#   cmake --build runtime/build
# Output: runtime/build/game.xex; on the console it is <game folder>\default.xex (see README.md).
cmake_minimum_required(VERSION 3.25)
project(engine360_runtime C)

# Per game. The defaults are for development only: every game built with them shares one Title ID,
# so Aurora and the console treat them all as the same title.
set(GAME_TITLE_ID "" CACHE STRING "Title ID of the game: 0x and 8 hex digits (title_id in game.lua)")
set(GAME_NAME "" CACHE STRING "Name of the game shown by Aurora (name in game.lua)")
if(GAME_TITLE_ID STREQUAL "" OR GAME_NAME STREQUAL "")
	if(NOT (GAME_TITLE_ID STREQUAL "" AND GAME_NAME STREQUAL ""))
		message(FATAL_ERROR "Set both GAME_TITLE_ID and GAME_NAME (or neither, for a development build)")
	endif()
	set(GAME_TITLE_ID "0xFFFF0360")
	set(GAME_NAME "360PC-Engine dev build")
	message(WARNING "GAME_TITLE_ID and GAME_NAME not set: development build "
		"(${GAME_TITLE_ID}, \"${GAME_NAME}\"). Do not distribute it.")
endif()
if(NOT GAME_TITLE_ID MATCHES "^0x[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$")
	message(FATAL_ERROR "GAME_TITLE_ID must be 0x and 8 hex digits, like 0x4D470001 (got \"${GAME_TITLE_ID}\")")
endif()
message(STATUS "Game: ${GAME_TITLE_ID} \"${GAME_NAME}\"")

set(LUAJIT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/luajit_xsdk/src" CACHE PATH
	"LuaJIT built with xsdk's GCC (toolchain/build_luajit_xsdk.sh)")
if(NOT EXISTS "${LUAJIT}/libluajit.a")
	message(FATAL_ERROR "Missing ${LUAJIT}/libluajit.a: run toolchain/build_luajit_xsdk.sh first")
endif()

# main.c first: an object before main.c in the link makes elf2xex fail ("section .init overlaps
# the PE headers"). l360_gfx.c uses stb_image and stb_truetype from third_party/stb.
add_executable(game main.c l360_gfx.c l360_particles.c l360_sys.c l360_audio.c)
set_target_properties(game PROPERTIES C_STANDARD 17 C_EXTENSIONS ON)
target_compile_options(game PRIVATE -Wall -Wextra -Werror)
target_include_directories(game PRIVATE "${LUAJIT}" "${CMAKE_CURRENT_SOURCE_DIR}/third_party/stb")
target_link_libraries(game PRIVATE "${LUAJIT}/libluajit.a")
# Release build: -DL360_RELEASE=ON keeps the log short (errors, summaries and [hitch]; see
# main.c). In game:\l360_gfx.txt, full_log turns the full log back on.
option(L360_RELEASE "Release build: short log" OFF)
if(L360_RELEASE)
	target_compile_definitions(game PRIVATE L360_SHORT_LOG=1)
endif()
# The Title ID separates the game's system saves and what Aurora remembers about it. Do not change
# a released game's Title ID: Aurora would treat it as another game.
xsdk_add_xex(game TITLE_ID ${GAME_TITLE_ID} NAME "${GAME_NAME}")
