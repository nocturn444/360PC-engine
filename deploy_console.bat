@echo off
rem Double-click: update the repository (git pull), then build, package and upload a game to the
rem Xbox 360 over FTP with tools\deploy.py. Settings: deploy.local.ini (docs\DEPLOY.md).
rem
rem The branch to follow. A pull can change this file, so it runs from a copy in %TEMP%.
setlocal EnableExtensions EnableDelayedExpansion
set "BRANCH=main"
set "DEFAULT_GAME=rooms"

if /i not "%~1"=="--from-temp" (
    set "COPY=%TEMP%\360pc_deploy_console.bat"
    copy /y "%~f0" "!COPY!" >nul || (echo Could not copy the script to %TEMP%. & pause & exit /b 1)
    call "!COPY!" --from-temp "%~dp0"
    exit /b !errorlevel!
)
set "REPO=%~2"
cd /d "%REPO%" || (echo Cannot open %REPO% & pause & exit /b 1)
title 360PC-Engine: deploy to the console
echo === 360PC-Engine: deploy to the console ===
echo Repository: %CD%
echo.

rem ---------------------------------------------------------------- 1. git pull
where git >nul 2>nul || (
    echo [git] Git is not installed or not on the PATH: https://git-scm.com/download/win
    echo [git] Skipping the update.
    goto :python
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
    goto :python
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
goto :python

:git_failed
echo.
echo [git] The update failed (see above). Nothing was deleted.
choice /c YN /n /m "[git] Continue with the code you have? (Y = yes, N = exit) "
if errorlevel 2 exit /b 1

rem ---------------------------------------------------------------- 2. Python
:python
set "PY="
py -3 -c "import sys" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import sys" >nul 2>nul && set "PY=python"
if not defined PY (
    echo [python] Python 3 is not installed: https://www.python.org/downloads/
    echo [python] Tick "Add python.exe to PATH" in the installer, then run this again.
    pause & exit /b 1
)

rem ---------------------------------------------------------------- 3. local settings
if not exist "deploy.local.ini" (
    copy /y "tools\deploy.example.ini" "deploy.local.ini" >nul
    echo [config] Created deploy.local.ini from the example. It opens now in Notepad:
    echo [config] set the console's IP under [console] host, save, close Notepad and run this again.
    echo [config] It stays on this PC only: it is never committed or uploaded to the console.
    start "" notepad "deploy.local.ini"
    pause & exit /b 0
)

rem ---------------------------------------------------------------- 4. pick the game
echo Games:
set /a N=0
set "DEFAULT_N="
for /d %%G in (examples\* template) do (
    if exist "%%G\game.lua" (
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

rem ---------------------------------------------------------------- 5. deploy
echo [deploy] %PY% tools\deploy.py !GAME!
echo.
%PY% tools\deploy.py "!GAME!"
set "RESULT=!errorlevel!"
echo.
if "!RESULT!"=="0" (
    echo === Done. Open the game from Aurora, or check default.log in its folder if it fails. ===
) else (
    echo === Something failed: the message above says which step. Nothing on the console was deleted. ===
)
pause
exit /b !RESULT!
