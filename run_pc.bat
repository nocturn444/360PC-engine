@echo off
rem Double-click: update the repository (git pull), then open a game on the PC with LOVE 11.x.
rem The same safe update as deploy_console.bat: local changes are never touched.
rem
rem The branch to follow. A pull can change this file, so it runs from a copy in %TEMP%.
setlocal EnableExtensions EnableDelayedExpansion
set "BRANCH=claude/project-thread-e7o1dl"
set "DEFAULT_GAME=rooms"

if /i not "%~1"=="--from-temp" (
    set "COPY=%TEMP%\360pc_run_pc.bat"
    copy /y "%~f0" "!COPY!" >nul || (echo Could not copy the script to %TEMP%. & pause & exit /b 1)
    call "!COPY!" --from-temp "%~dp0"
    exit /b !errorlevel!
)
set "REPO=%~2"
cd /d "%REPO%" || (echo Cannot open %REPO% & pause & exit /b 1)
title 360PC-Engine: run on the PC
echo === 360PC-Engine: run on the PC ===
echo Repository: %CD%
echo.

rem ---------------------------------------------------------------- 1. git pull
where git >nul 2>nul || (
    echo [git] Git is not installed or not on the PATH: https://git-scm.com/download/win
    echo [git] Skipping the update.
    goto :love
)
set "DIRTY="
for /f "delims=" %%L in ('git status --porcelain --untracked-files=no 2^>nul') do set "DIRTY=1"
if defined DIRTY (
    echo [git] You have local changes that are not committed:
    git status --short --untracked-files=no
    echo.
    echo [git] They are NOT touched. Updating could mix them with new code, so the update is skipped.
    choice /c YN /n /m "[git] Continue without updating? (Y = yes, N = exit) "
    if errorlevel 2 exit /b 1
    goto :love
)
for /f "delims=" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURRENT=%%B"
echo [git] Fetching %BRANCH% ...
git fetch origin %BRANCH% || goto :git_failed
if /i not "!CURRENT!"=="%BRANCH%" (
    echo [git] Switching from !CURRENT! to %BRANCH% ...
    git checkout %BRANCH% || goto :git_failed
)
git pull --ff-only origin %BRANCH% || goto :git_failed
echo [git] Up to date: & git log -1 --format="       %%h %%s"
echo.
goto :love

:git_failed
echo.
echo [git] The update failed (see above). Nothing was deleted.
choice /c YN /n /m "[git] Continue with the code you have? (Y = yes, N = exit) "
if errorlevel 2 exit /b 1

rem ---------------------------------------------------------------- 2. find LOVE
:love
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
echo [love] !LOVE!
echo.

rem ---------------------------------------------------------------- 3. pick the game
echo Games:
set /a N=0
set "DEFAULT_N="
for /d %%G in (examples\* template) do (
    if exist "%%G\main.lua" (
        set /a N+=1
        set "GAME_!N!=%%G"
        if /i "%%~nxG"=="%DEFAULT_GAME%" set "DEFAULT_N=!N!"
        echo   !N!. %%G
    )
)
if not defined DEFAULT_N set "DEFAULT_N=1"
set "PICK="
set /p "PICK=Number of the game [Enter = !DEFAULT_N!]: "
if not defined PICK set "PICK=!DEFAULT_N!"
set "GAME=!GAME_%PICK%!"
if not defined GAME (echo No game number %PICK%. & pause & exit /b 1)
echo.

rem ---------------------------------------------------------------- 4. run
rem Started from the repository root so the game finds engine\ and lib\. LOVE shows its own
rem error screen if the game fails, so this window can close.
echo [love] Opening !GAME! ...
start "" "!LOVE!" "!GAME!"
exit /b 0
