' ===================================================================
'  comfy_watchdog.vbs
'  Purpose: shut down the local ComfyUI backend automatically when
'  Photoshop exits. Started hidden by start_comfy.bat or by the
'  "cleanbg" Photoshop plugin. No window, very low footprint.
'  It finds stop_comfy.bat next to itself, so no path editing needed.
'  NOTE: keep this file ASCII-only (wscript reads it as ANSI/GBK).
' ===================================================================
Option Explicit

Dim TARGET
TARGET = "photoshop.exe"          ' process to watch

Dim fso, here, wmi, p, col, n, seen, waits, maxWait, sh
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

Set wmi = GetObject("winmgmts:\\.\root\cimv2")

' --- avoid duplicates: quit if another watchdog is already running ---
n = 0
For Each p In wmi.ExecQuery("SELECT CommandLine FROM Win32_Process WHERE Name='wscript.exe'")
    If Not IsNull(p.CommandLine) Then
        If InStr(LCase(p.CommandLine), "comfy_watchdog.vbs") > 0 Then n = n + 1
    End If
Next
If n > 1 Then WScript.Quit

' --- wait until the target appears, then until it exits ---
seen = False
waits = 0
maxWait = 360                      ' give up after ~30 minutes if target never appears

Do
    Set col = wmi.ExecQuery("SELECT ProcessId FROM Win32_Process WHERE Name='" & TARGET & "'")
    If col.Count > 0 Then
        seen = True
    Else
        If seen Then Exit Do
    End If
    WScript.Sleep 5000
    waits = waits + 1
    If (Not seen) And (waits > maxWait) Then WScript.Quit
Loop

' --- target is gone: stop the backend (hidden) ---
Set sh = CreateObject("WScript.Shell")
If fso.FileExists(here & "\stop_comfy.bat") Then
    sh.Run """" & here & "\stop_comfy.bat""", 0, False
End If
