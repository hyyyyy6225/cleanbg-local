# =============================================================================
#  check-ps1-syntax.ps1  -  parse every .ps1 in this repo with PowerShell 5.1
#
#  Why: a Chinese .ps1 saved as UTF-8 WITHOUT a BOM is decoded as GBK by
#  PowerShell 5.1, which breaks the whole script (the "silently did nothing
#  but still printed OK" bug). This script reports the BOM state and counts
#  parser errors, so both are always visible.
#
#  Usage:  powershell -ExecutionPolicy Bypass -File tools\check-ps1-syntax.ps1
#  Exit code: 0 = all good, 1 = at least one problem
# =============================================================================
[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = "Continue"
if (-not $Root) {
    # Default: the parent of this script's folder (= repo root).
    # Do NOT put $MyInvocation in a param() default - it is null at that point.
    $Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$repoRoot = (Resolve-Path $Root).Path
Write-Host ("Repo root: " + $repoRoot)
Write-Host ""

$bad = 0
$files = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\python\\|\\.git\\' }

foreach ($f in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $hasCjk = ($text -match '[\u3000-\u9fff]')
    $crlf = ([regex]::Matches($text, "`r`n")).Count
    $loneLf = ([regex]::Matches($text, "(?<!`r)`n")).Count

    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null

    $status = "OK"
    if ($errs.Count -gt 0) { $status = "SYNTAX-ERROR"; $bad++ }
    elseif ($hasCjk -and -not $hasBom) { $status = "MISSING-BOM"; $bad++ }

    $fmt = "  {0,-13} errors={1,-3} bom={2,-5} cjk={3,-5} crlf={4,-4} loneLF={5,-4} {6}"
    $line = $fmt -f $status, $errs.Count, $hasBom, $hasCjk, $crlf, $loneLf, $f.FullName.Replace($repoRoot, "")
    if ($status -eq "OK") { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }

    foreach ($e in $errs) {
        Write-Host ("        line " + $e.Extent.StartLineNumber + ": " + $e.Message) -ForegroundColor DarkYellow
    }
}

Write-Host ""
if ($bad -eq 0) {
    Write-Host ("All " + @($files).Count + " PowerShell script(s) look fine (BOM ok, 0 parser errors).") -ForegroundColor Green
    exit 0
} else {
    Write-Host ($bad.ToString() + " file(s) need attention: save them as UTF-8 WITH BOM.") -ForegroundColor Red
    exit 1
}
