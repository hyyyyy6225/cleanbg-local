@echo off
rem =====================================================================
rem  "Clear Environment" plugin - uninstall launcher
rem
rem  It only (1) makes sure cleanbg-uninstall.ps1 has a UTF-8 BOM,
rem  (2) runs it.
rem
rem  NOTE: keep this file ASCII-only (cmd.exe decodes .bat with GBK).
rem
rem  Preview mode (change nothing, just show what would be removed):
rem    run this file with the argument  -DryRun
rem =====================================================================
setlocal
cd /d "%~dp0"
title Clear Environment - uninstall

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if not exist "%~dp0cleanbg-uninstall.ps1" (
    echo.
    echo   [X] "cleanbg-uninstall.ps1" was not found next to this file.
    echo       Both files must stay in the same folder.
    echo.
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "$f=Join-Path '%~dp0' 'cleanbg-uninstall.ps1'; $b=[IO.File]::ReadAllBytes($f); if (-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)) { [IO.File]::WriteAllBytes($f, ([byte[]]((239,187,191) + $b))); Write-Host '  [i] added the missing UTF-8 BOM to cleanbg-uninstall.ps1' }; & '%PS%' -NoProfile -ExecutionPolicy Bypass -File $f %*"

endlocal
