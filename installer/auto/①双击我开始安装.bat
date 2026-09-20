@echo off
rem ================================================================
rem  cleanbg auto-installer launcher
rem  Double-click this file. It only starts install.ps1.
rem  Keep this file ASCII-only (Chinese characters break .bat).
rem ================================================================
cd /d "%~dp0"
title cleanbg auto installer

echo.
echo   ============================================================
echo    "Clear Environment" Photoshop plugin - automatic installer
echo   ============================================================
echo.
echo    What it does:
echo      1. install the VC++ runtime (if missing)
echo      2. download + unpack ComfyUI portable  (~1.8 GB)
echo      3. download 6 AI models                (~18.2 GB)
echo      4. install the custom nodes
echo      5. install the Photoshop plugin
echo      6. create desktop shortcuts and self-test
echo.
echo    Total download is about 20 GB. You can leave it running.
echo    If a Windows permission window pops up, please click [Yes].
echo.
echo   ------------------------------------------------------------
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem --- Safety net ---------------------------------------------------------
rem A UTF-8 .ps1 WITHOUT a byte-order mark is decoded as GBK by PowerShell
rem 5.1. The Chinese comments then break the whole script (silently), so the
rem install may "look fine" while nothing was really changed. Make sure the
rem BOM is there before running the script.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$f=Join-Path '%~dp0' 'install.ps1'; $b=[IO.File]::ReadAllBytes($f); if (-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)) { [IO.File]::WriteAllBytes($f, ([byte[]]((239,187,191) + $b))); Write-Host '  [i] script had no UTF-8 BOM - added it.' }; & '%PS%' -NoProfile -ExecutionPolicy Bypass -File $f"

echo.
echo   The installer window has closed. You can close this window too.
pause >nul
