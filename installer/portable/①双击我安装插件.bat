@echo off
rem ================================================================
rem  cleanbg portable edition - install the Photoshop plugin
rem  Double-click this file. It only runs install-plugin.ps1.
rem  Keep this file ASCII-only (Chinese characters break .bat).
rem ================================================================
cd /d "%~dp0"
title cleanbg portable installer

echo.
echo   ============================================================
echo    "Clear Environment" plugin  -  PORTABLE edition
echo   ============================================================
echo.
echo    Everything is already included (ComfyUI + all models).
echo    No internet download is needed.
echo.
echo    This will:
echo      1. install the plugin into Photoshop
echo      2. point the plugin to this folder
echo      3. create desktop shortcuts
echo      4. check the VC++ runtime (offline installer included)
echo      5. start the backend once to self-test
echo.
echo    A Windows permission window may pop up - please click [Yes].
echo   ------------------------------------------------------------
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem --- Safety net ---------------------------------------------------------
rem A UTF-8 .ps1 WITHOUT a byte-order mark is decoded as GBK by PowerShell
rem 5.1. The Chinese comments then break the whole script (silently), so the
rem install may "look fine" while nothing was really changed. Make sure the
rem BOM is there before running the script.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$f=Join-Path '%~dp0' 'install-plugin.ps1'; $b=[IO.File]::ReadAllBytes($f); if (-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)) { [IO.File]::WriteAllBytes($f, [byte[]]((239,187,191) + $b)); Write-Host '  [i] script had no UTF-8 BOM - added it.' }; & '%PS%' -NoProfile -ExecutionPolicy Bypass -File $f"

echo.
echo   Done. You can close this window.
pause >nul
