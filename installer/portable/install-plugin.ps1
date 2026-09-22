<#
================================================================================
  「清空环境」· 便携版（全套已内置）安装脚本
--------------------------------------------------------------------------------
  这个版本里 ComfyUI、python 运行时、6 个模型全都是现成的，**不需要联网下载任何东西**。
  本脚本负责：
    1. 把插件装进 Photoshop，并把路径指向这个便携版所在位置
    2. 建桌面快捷方式（启动 / 关闭 ComfyUI）
    3. 检查 VC++ 运行库（缺的话用本包里的安装包装上，不需要联网）
    4. 启动一次后端做自检

  用法：双击同目录的「①双击我安装插件.bat」，或：
      powershell -ExecutionPolicy Bypass -File .\install-plugin.ps1
      powershell -ExecutionPolicy Bypass -File .\install-plugin.ps1 -PSPlugins "C:\Program Files\Adobe\Adobe Photoshop 2026\Plug-ins"

  ⚠ 如果之后把这个文件夹移动了位置（或换了盘符），重新双击一次本脚本即可（路径会重新指向）。
================================================================================
#>
[CmdletBinding()]
param(
    [string]$PSPlugins,
    [switch]$SkipSelfTest
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }
try { $here = (Resolve-Path $here).Path } catch {}
$logFile = Join-Path $here "安装日志.txt"

function Log {
    param([string]$m, [string]$color = "Gray")
    Write-Host $m -ForegroundColor $color
    try { Add-Content -Path $logFile -Value ("[" + (Get-Date).ToString("HH:mm:ss") + "] " + $m) -Encoding UTF8 } catch {}
}
function Banner {
    param([string]$m)
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    Write-Host ("  " + $m) -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor DarkCyan
    try { Add-Content -Path $logFile -Value ("`r`n" + ("=" * 72) + "`r`n  " + $m) -Encoding UTF8 } catch {}
}
function Ok   { param([string]$m) Log ("  [OK]   " + $m) "Green" }
function Warn { param([string]$m) Log ("  [注意] " + $m) "Yellow" }
function Bad  { param([string]$m) Log ("  [失败] " + $m) "Red" }

Log ("便携版插件安装开始 · " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Log ("本包位置: " + $here)

# ---------------------------------------------------------------- 管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Log ""
    Log "  需要管理员权限（要往 Photoshop 目录装插件）。" "Yellow"
    Log "  马上会弹出「用户帐户控制」窗口，请点【是】。" "Yellow"
    try {
        $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($PSPlugins) { $psArgs += @("-PSPlugins", "`"$PSPlugins`"") }
        Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Verb RunAs | Out-Null
        Log "  已在新的管理员窗口里继续，这个窗口可以关掉了。" "Green"
    } catch {
        Bad ("提权失败：" + $_.Exception.Message)
        Log "  请右键这个脚本 → 以管理员身份运行。" "Yellow"
    }
    Read-Host "`n按回车键退出"
    exit
}
Ok "已获得管理员权限"

# ---------------------------------------------------------------- 检查本包完整性
Banner "检查便携版文件"
$need = @(
    @("python\python.exe",                                             "python 运行时"),
    @("ComfyUI\main.py",                                               "ComfyUI 本体"),
    @("ComfyUI\models\unet\flux-2-klein-9b-fp8.safetensors",           "主模型 8.8GB"),
    @("ComfyUI\models\clip\qwen_3_8b_fp8mixed.safetensors",            "文本编码器 8.1GB"),
    @("ComfyUI\models\vae\flux2-vae.safetensors",                      "VAE"),
    @("ComfyUI\models\upscale_models\4x-UltraSharp.pth",               "放大模型"),
    @("ComfyUI\models\loras\F2K9B_ObjectRemover.safetensors",          "移除 LoRA"),
    @("ComfyUI\models\BiRefNet\General.safetensors",                   "抠人模型"),
    @("ComfyUI\custom_nodes\comfyui-KJNodes",                          "节点 KJNodes"),
    @("ComfyUI\custom_nodes\ComfyUI_BiRefNet_ll",                      "节点 BiRefNet"),
    @("ComfyUI\custom_nodes\Comfyui-PainterFluxImageEdit",             "节点 PainterFlux"),
    @("ComfyUI\custom_nodes\cleanbg_control",                          "节点 cleanbg_control")
)
$missing = 0
foreach ($n in $need) {
    if (Test-Path (Join-Path $here $n[0])) { Ok ($n[1] + " 在") }
    else { Bad ($n[1] + " 缺失：" + $n[0]); $missing++ }
}
if ($missing -gt 0) {
    Warn "包不完整（缺 $missing 项）。如果这个文件夹是从 U 盘拷过来的，请确认复制完整。"
}
foreach ($f in @("start_comfy.bat", "stop_comfy.bat", "comfy_watchdog.vbs")) {
    $s = Join-Path $here $f
    if (-not (Test-Path $s)) {
        $alt = Join-Path $here ("2-后端脚本\" + $f)
        if (Test-Path $alt) { Copy-Item $alt $s -Force }
    }
}

# ---------------------------------------------------------------- VC++ 运行库
Banner "检查 VC++ 运行库"
$vcKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
$vcInstalled = (Test-Path $vcKey) -and ((Get-ItemProperty $vcKey -ErrorAction SilentlyContinue).Installed -eq 1)
if ($vcInstalled) {
    Ok "已安装"
} else {
    $vc = Get-ChildItem $here -Recurse -Filter "vc_redist.x64.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vc) {
        Log "  未安装，用本包自带的运行库静默安装（约 1 分钟）…"
        $p = Start-Process -FilePath $vc.FullName -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
        Log ("  安装程序返回码: " + $p.ExitCode)
        Ok "VC++ 运行库安装完成"
    } else {
        Warn "未安装且包里没有 vc_redist.x64.exe。如果后面 ComfyUI 起不来，请联网装一下微软 VC++ 运行库。"
    }
}

# ---------------------------------------------------------------- 找 Photoshop
Banner "安装 Photoshop 插件"
function Get-PluginsFromExe {
    param([string]$Exe)
    if (-not $Exe) { return $null }
    $dir = Split-Path -Parent (([string]$Exe).Trim('"', ' '))
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    foreach ($n in @('Plug-ins', 'Plug-Ins', 'Plugins')) {
        $p = Join-Path $dir $n
        if (Test-Path $p) { return $p }
    }
    return $null
}
function Find-PSPlugins {
    # 从准到糙：①运行中的 PS ②App Paths ③Adobe 注册表 ④卸载项 ⑤扫盘 ⑥老位置
    $found = @()
    foreach ($proc in (Get-Process -Name Photoshop -ErrorAction SilentlyContinue)) {
        try { $r = Get-PluginsFromExe $proc.Path; if ($r) { $found += $r } } catch {}
    }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Photoshop.exe',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Photoshop.exe')) {
        $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
        if ($v) { $r = Get-PluginsFromExe $v; if ($r) { $found += $r } }
    }
    foreach ($sub in (Get-ChildItem -Path 'HKLM:\SOFTWARE\Adobe\Photoshop' -ErrorAction SilentlyContinue)) {
        foreach ($n in @('PluginPath', 'PluginsPath', 'ApplicationPath')) {
            $v = (Get-ItemProperty -Path $sub.PSPath -Name $n -ErrorAction SilentlyContinue).$n
            if (-not $v) { continue }
            foreach ($one in @($v)) {
                $one = ([string]$one).Trim().TrimEnd('\')
                if (-not $one) { continue }
                if ($one -match '(?i)plug-?ins$') { if (Test-Path $one) { $found += $one } }
                else { $r = Get-PluginsFromExe (Join-Path $one 'Photoshop.exe'); if ($r) { $found += $r } }
            }
        }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-ItemProperty -Path ($root + '\*') -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Photoshop*' -and $_.InstallLocation } |
            ForEach-Object { $r = Get-PluginsFromExe (Join-Path $_.InstallLocation 'Photoshop.exe'); if ($r) { $found += $r } }
    }
    $drives = @()
    try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object { $_.DeviceID + '\' }) } catch {}
    if ($drives.Count -eq 0) { $drives = @('C:\', 'D:\', 'E:\', 'F:\', 'G:\') }
    foreach ($root in $drives) {
        foreach ($d in (Get-ChildItem -Path ($root + 'Adobe Photoshop*') -Directory -ErrorAction SilentlyContinue)) {
            $r = Get-PluginsFromExe (Join-Path $d.FullName 'Photoshop.exe'); if ($r) { $found += $r }
            foreach ($d2 in (Get-ChildItem -Path (Join-Path $d.FullName 'Adobe Photoshop*') -Directory -ErrorAction SilentlyContinue)) {
                $r2 = Get-PluginsFromExe (Join-Path $d2.FullName 'Photoshop.exe'); if ($r2) { $found += $r2 }
            }
        }
        foreach ($base in @('Program Files\Adobe', 'Program Files (x86)\Adobe', 'Adobe')) {
            $b = Join-Path $root $base
            if (-not (Test-Path $b)) { continue }
            $found += Get-ChildItem -Path $b -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like 'Adobe Photoshop*' } |
                      ForEach-Object { foreach ($n in @('Plug-ins', 'Plug-Ins')) { $p = Join-Path $_.FullName $n; if (Test-Path $p) { $p } } }
        }
    }
    return @($found | Where-Object { $_ } | Sort-Object -Unique)
}
if (-not ($PSPlugins -and (Test-Path $PSPlugins))) {
    $cands = Find-PSPlugins
    if ($cands.Count -ge 1) {
        $PSPlugins = $cands[0]
        Ok ("找到 Photoshop 插件目录：" + $PSPlugins)
        if ($cands.Count -gt 1) { Warn ("还发现：" + ($cands[1..($cands.Count-1)] -join " | ")) }
    } else {
        $PSPlugins = $null
    }
}

if ($PSPlugins) {
    $srcPlugin = Join-Path $here "插件\cleanbg"
    if (-not (Test-Path $srcPlugin)) { $srcPlugin = Join-Path $here "1-插件本体\cleanbg" }
    if (Test-Path $srcPlugin) {
        $dstPlugin = Join-Path $PSPlugins "cleanbg"
        if (Test-Path $dstPlugin) { Remove-Item $dstPlugin -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item $srcPlugin $dstPlugin -Recurse -Force

        # 把插件里的后端路径指向本便携版（新老两种格式都兼容；写完必须读回校验，不能"报成功其实没改"）
        $mainJs = Join-Path $dstPlugin "main.js"
        $fwd = ($here -replace '\\', '/')
        $raw = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8)
        $hits = 0
        # 新格式：一个常量 COMFY_DIR_DEFAULT（面板里也能改，改完永久记住）
        $new1 = 'const COMFY_DIR_DEFAULT = "' + $fwd + '";'
        $tmp = [regex]::Replace($raw, 'const COMFY_DIR_DEFAULT\s*=\s*"[^"]*"\s*;', $new1)
        if ($tmp -ne $raw) { $hits++; $raw = $tmp }
        # 老格式：4 个常量分开写的老插件
        foreach ($p in @(
            @('COMFY_ROOT',     $fwd + '/ComfyUI'),
            @('COMFY_START',    $fwd + '/start_comfy.bat'),
            @('COMFY_STOP',     $fwd + '/stop_comfy.bat'),
            @('COMFY_WATCHDOG', $fwd + '/comfy_watchdog.vbs')
        )) {
            $before = $raw
            $raw = [regex]::Replace($raw, 'const ' + $p[0] + '\s*=\s*"[^"]*"\s*;', 'const ' + $p[0] + ' = "' + $p[1] + '";')
            if ($raw -ne $before) { $hits++ }
        }
        [System.IO.File]::WriteAllText($mainJs, $raw, (New-Object System.Text.UTF8Encoding($false)))

        # ---- 读回校验：真的从磁盘读回来了才算成功 ----
        $back = ""
        try { $back = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8) } catch {}
        $wroteOk = $false
        if ($back -match ('COMFY_DIR_DEFAULT\s*=\s*"' + [regex]::Escape($fwd) + '"')) { $wroteOk = $true }
        elseif ($back -match ('COMFY_ROOT\s*=\s*"' + [regex]::Escape($fwd) + '/ComfyUI"')) { $wroteOk = $true }

        if (-not (Test-Path $mainJs)) {
            Bad ("插件没写进去：" + $mainJs + " —— 请把这句话截图发给插件作者")
        } elseif ($hits -eq 0) {
            Warn "插件里的路径常量没匹配到（版本可能不一样）。不影响使用：新版插件会自己找后端目录。"
        } elseif ($wroteOk) {
            Ok ("插件已装到 " + $dstPlugin)
            Ok ("路径已指向 " + $fwd + "（已读回校验通过）")
            Log "  （就算这段改写失败，插件运行时也会自己找后端目录；面板里也能手动改）" "DarkGray"
        } else {
            Bad "路径改写没生效！请把这句话连同上面的日志发给插件作者。"
        }
        Log "  （如果以后移动了这个文件夹，重新双击一次本脚本即可；新版插件也能自己找到）" "DarkGray"
    } else {
        Bad "本包里没找到插件（插件\cleanbg 或 1-插件本体\cleanbg）"
    }
} else {
    Warn "没找到 Photoshop。请手动把「插件\cleanbg」整个文件夹复制到 Photoshop 的 Plug-ins 里，"
    Warn "然后手动改插件里 main.js 开头的 4 个路径（COMFY_ROOT / COMFY_START / COMFY_STOP / COMFY_WATCHDOG）。"
}

# ---------------------------------------------------------------- 快捷方式
Banner "创建桌面快捷方式"
try {
    $ws = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath("Desktop")
    $l1 = $ws.CreateShortcut((Join-Path $desk "启动 ComfyUI.lnk"))
    $l1.TargetPath = Join-Path $here "start_comfy.bat"
    $l1.WorkingDirectory = $here
    $l1.Description = "启动本地 AI 后端（清空环境插件用）"
    $l1.Save()
    Ok "桌面：启动 ComfyUI"
    $l2 = $ws.CreateShortcut((Join-Path $desk "关闭 ComfyUI.lnk"))
    $l2.TargetPath = Join-Path $here "stop_comfy.bat"
    $l2.WorkingDirectory = $here
    $l2.Save()
    Ok "桌面：关闭 ComfyUI"
} catch {
    Warn ("快捷方式创建失败：" + $_.Exception.Message)
}

# ---------------------------------------------------------------- 自检
if (-not $SkipSelfTest) {
    Banner "启动一次后端做自检（首次约 1 分钟）"
    try {
        Start-Process -FilePath (Join-Path $here "start_comfy.bat") -WorkingDirectory $here -WindowStyle Minimized | Out-Null
        $ping = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 3
            try {
                $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/cleanbg/ping" -TimeoutSec 4 -UseBasicParsing
                if ($r.StatusCode -eq 200) { $ping = $true; break }
            } catch { }
            if ($i % 5 -eq 4) { Log ("  等待后端启动… " + (($i + 1) * 3) + " 秒") }
        }
        if ($ping) {
            Ok "后端启动成功，关闭接口正常"
            Log "  可以打开 Photoshop 开始用了。" "Green"
        } else {
            Warn "后端还没就绪。稍后双击桌面「启动 ComfyUI」，看到命令行窗口出现 server started 就好了。"
        }
    } catch {
        Warn ("自检失败：" + $_.Exception.Message)
    }
}

Banner "安装完成"
Log ""
Log "接下来：" "Cyan"
Log "  1. 重新启动 Photoshop（插件必须重启才加载）" "Cyan"
Log "  2. 菜单【增效工具 / 插件】→【清空环境】" "Cyan"
Log "  3. 面板里点【启动 ComfyUI】（或双击桌面快捷方式），等状态变成「已就绪」" "Cyan"
Log "  4. 点【▶ 清空环境】开始清场" "Cyan"
Log ""
Log ("本包位置 : " + $here)
if ($PSPlugins) { Log ("插件目录 : " + (Join-Path $PSPlugins "cleanbg")) }
Log ("安装日志 : " + $logFile)
Log ""
Log "这个版本不需要联网下载任何东西；全程离线可用。" "Green"
Log ""
Read-Host "按回车键关闭这个窗口"
