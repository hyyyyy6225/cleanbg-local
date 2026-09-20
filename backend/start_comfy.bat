@echo off
rem ================================================================
rem  Start the local ComfyUI backend for the "cleanbg" PS plugin.
rem  Put this file in your ComfyUI ROOT folder, i.e. the folder that
rem  contains "python\" (or python_embeded\) and "ComfyUI\".
rem  It figures out its own location, so no path editing is needed.
rem  Keep this file ASCII-only: cmd reads .bat as ANSI/GBK.
rem ================================================================
setlocal
cd /d "%~dp0"
title ComfyUI (cleanbg backend)
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set "PATH=%~dp0python;%~dp0python\Scripts;%~dp0git\bin;%~dp0git\usr\bin;%PATH%"

rem --- find python and ComfyUI/main.py ---
set "PYEXE="
if exist "%~dp0python\python.exe"          set "PYEXE=%~dp0python\python.exe"
if not defined PYEXE if exist "%~dp0python_embeded\python.exe" set "PYEXE=%~dp0python_embeded\python.exe"
if not defined PYEXE if exist "%~dp0..\python\python.exe"      set "PYEXE=%~dp0..\python\python.exe"
if not defined PYEXE if exist "%~dp0..\python_embeded\python.exe" set "PYEXE=%~dp0..\python_embeded\python.exe"

set "MAINPY="
if exist "%~dp0ComfyUI\main.py"  set "MAINPY=%~dp0ComfyUI\main.py"
if not defined MAINPY if exist "%~dp0..\ComfyUI\main.py" set "MAINPY=%~dp0..\ComfyUI\main.py"

if not defined PYEXE (
    echo.
    echo   [ERROR] python.exe not found.
    echo   Put this .bat in your ComfyUI root folder ^(the one with "python" and "ComfyUI" inside^).
    echo.
    pause
    exit /b 1
)
if not defined MAINPY (
    echo.
    echo   [ERROR] ComfyUI\main.py not found.
    echo   Put this .bat in your ComfyUI root folder ^(the one with "python" and "ComfyUI" inside^).
    echo.
    pause
    exit /b 1
)

rem --- arm the watchdog only if Photoshop is already running ---
%SystemRoot%\System32\tasklist.exe /FI "IMAGENAME eq Photoshop.exe" 2>nul | %SystemRoot%\System32\findstr.exe /I "Photoshop.exe" >nul && (
    start "" /min wscript.exe "%~dp0comfy_watchdog.vbs"
)

echo.
echo   ComfyUI is starting (first load takes about 1 minute) ...
echo   It closes automatically when Photoshop exits,
echo   or double-click stop_comfy.bat to close it now.
echo.
echo   python : %PYEXE%
echo   server : %MAINPY%
echo.

"%PYEXE%" -s "%MAINPY%" --port 8188 --disable-auto-launch --windows-standalone-build

echo.
echo   ComfyUI exited.
%SystemRoot%\System32\timeout.exe /t 3 >nul
