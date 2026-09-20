@echo off
rem ================================================================
rem  cleanbg plugin UPDATE patch  -  launcher
rem  Double-click this file. It only runs update-plugin.ps1.
rem  Keep this file ASCII-only (Chinese characters break .bat).
rem ================================================================
cd /d "%~dp0"
title cleanbg plugin update

echo.
echo   ============================================================
echo    "Clear Environment" plugin  -  UPDATE patch (v4)
echo   ============================================================
echo.
echo    What it does:
echo      1. find the installed plugin inside Photoshop
echo      2. replace it with the new version (old files become *.bak)
echo      3. write the backend folder path into the plugin
echo.
echo    It needs admin rights - click [Yes] on the Windows prompt.
echo    After it finishes: quit Photoshop completely and start it again.
echo   ------------------------------------------------------------
echo.

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

rem --- Safety net ---------------------------------------------------------
rem A UTF-8 .ps1 WITHOUT a byte-order mark is decoded as GBK by PowerShell
rem 5.1, and the Chinese comments then break the whole script silently.
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$f=Join-Path '%~dp0' 'update-plugin.ps1'; $b=[IO.File]::ReadAllBytes($f); if (-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)) { [IO.File]::WriteAllBytes($f, ([byte[]]((239,187,191) + $b))); Write-Host '  [i] script had no UTF-8 BOM - added it.' }; & '%PS%' -NoProfile -ExecutionPolicy Bypass -File $f"

echo.
echo   Done. You can close this window.
pause >nul
