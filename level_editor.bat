@echo off
rem Opens the level editor (tools\level_editor) with LOVE 11.x. Drag a .lvl file onto this
rem script, or double-click it and type the path (a new file starts a new level).
rem   level_editor.bat levels\world.lvl [--root <game folder>] [--cell 20x12] [--tile 16]
rem Reference: docs\LEVEL_EDITOR.md. It does not update the repository: run_pc.bat does.
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
title 360PC-Engine: level editor

set "LOVE="
if exist "%ProgramFiles%\LOVE\love.exe" set "LOVE=%ProgramFiles%\LOVE\love.exe"
if not defined LOVE if exist "%ProgramFiles(x86)%\LOVE\love.exe" set "LOVE=%ProgramFiles(x86)%\LOVE\love.exe"
if not defined LOVE for /f "delims=" %%P in ('where love.exe 2^>nul') do if not defined LOVE set "LOVE=%%P"
if not defined LOVE (
    echo [love] LOVE was not found in "%ProgramFiles%\LOVE" nor on the PATH.
    echo [love] Install LOVE 11.5 ^(64-bit installer^) from https://love2d.org and run this again.
    start "" "https://love2d.org"
    pause & exit /b 1
)

if "%~1"=="" (
    set "FILE="
    set /p "FILE=Level file to open or create [Enter = levels\world.lvl]: "
    if not defined FILE set "FILE=levels\world.lvl"
    start "" "!LOVE!" "tools\level_editor" "!FILE!"
) else (
    start "" "!LOVE!" "tools\level_editor" %*
)
exit /b 0
