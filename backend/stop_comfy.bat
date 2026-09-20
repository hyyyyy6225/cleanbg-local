@echo off
rem ================================================================
rem  Stop the local ComfyUI backend and release VRAM.
rem  Put this file in the same folder as start_comfy.bat.
rem  Keep this file ASCII-only.
rem ================================================================
title Stopping ComfyUI ...
setlocal enabledelayedexpansion

rem 1) graceful shutdown through the plugin endpoint (cleanest, frees VRAM)
%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "try { Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8188/cleanbg/shutdown' -TimeoutSec 4 | Out-Null; Start-Sleep -Milliseconds 1200 } catch { }" >nul 2>&1

rem 2) fallback: kill whatever is listening on port 8188
set FOUND=0
for /f "tokens=5" %%p in ('%SystemRoot%\System32\netstat.exe -ano ^| %SystemRoot%\System32\findstr.exe ":8188" ^| %SystemRoot%\System32\findstr.exe "LISTENING"') do (
    %SystemRoot%\System32\taskkill.exe /F /PID %%p >nul 2>&1
    set FOUND=1
)
if "!FOUND!"=="1" (echo ComfyUI stopped, VRAM released.) else (echo ComfyUI is not running.)
%SystemRoot%\System32\timeout.exe /t 2 >nul
