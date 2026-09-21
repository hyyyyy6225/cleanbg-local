@echo off
rem =====================================================================
rem  cleanbg - convenience launcher (repo root)
rem
rem  For users who ALREADY installed the plugin and only want to update it.
rem  This file only forwards to installer\patch\ so you do not have to dig
rem  through the sub-folders.
rem
rem  NOTE: keep this file ASCII-only. Chinese text inside a .bat file is
rem  decoded with the GBK code page by cmd.exe and would break paths.
rem =====================================================================
setlocal
set "TARGET_DIR=%~dp0installer\patch"

if not exist "%TARGET_DIR%" (
    echo.
    echo   [X] Cannot find: "%TARGET_DIR%"
    echo       Please extract the WHOLE zip and keep the folder structure.
    echo.
    pause
    exit /b 1
)

set "FOUND="
for %%F in ("%TARGET_DIR%\*.bat") do if not defined FOUND set "FOUND=%%~fF"

if not defined FOUND (
    echo.
    echo   [X] No launcher found inside "%TARGET_DIR%".
    echo.
    pause
    exit /b 1
)

call "%FOUND%"
endlocal
