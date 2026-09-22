# =====================================================================
#   「清空环境」一键卸载工具        cleanbg-uninstall.ps1
#
#   做什么：
#     ① 清点装了哪些东西（插件 / 快捷方式 / 后端 / 安装包残留）
#     ② 关掉正在运行的 ComfyUI
#     ③ 卸载 Photoshop 插件（会先备份到桌面）
#     ④ 删掉桌面上的「启动/关闭 ComfyUI」快捷方式
#     ⑤ 可选：清掉插件的设置缓存
#     ⑥ 后端 ComfyUI + 模型（20~45 GB）→【逐个确认后才删】
#     ⑦ 可选：清掉安装包解压目录里的「_下载缓存」
#
#   ⚠️ 安全设计（重要）：
#     · 只删「确认识别为清空环境装的」后端：
#         - 便携版整包指纹：根目录同时有 install-plugin.ps1 和 插件\cleanbg\main.js
#         - 自动安装包指纹：根目录有 cleanbg-install.json（2.6 起安装时会写）
#         - 后端三件套（start_comfy.bat + stop_comfy.bat + comfy_watchdog.vbs）
#           且含自研节点 ComfyUI\custom_nodes\cleanbg_control 且没有第三方启动器
#         - 桌面上我们建的「启动/关闭 ComfyUI」快捷方式指向它
#     · 其它含 start_comfy.bat 的目录（比如你自己常用的绘世/秋葉版 ComfyUI）
#       **只列出来、绝不删**。
#     · 桌面上不是我们建的 ComfyUI 快捷方式，也不会删。
#     · 每一处删除都会打印路径和大小，并要求你按键确认。
#
#   用法：双击同目录的「①双击我卸载.bat」
#   参数：-DryRun    只检查、只打印，不关进程、不删任何文件（先看看会删什么）
#         -NoPause   不等待按键（供自动测试用，普通用户不用加）
#         -NoElevate 不请求管理员权限（供自动测试用）
# =====================================================================
param([switch]$DryRun, [switch]$NoPause, [switch]$NoElevate)

$ErrorActionPreference = "Continue"

$PluginName   = "cleanbg"
$UxpPluginId  = "cleanbg-local-panel"
$MarkerFile   = "cleanbg-install.json"
$DesktopDir   = [Environment]::GetFolderPath('Desktop')
$WorkRoot     = Join-Path $DesktopDir "cleanbg-卸载备份"
$LogFile      = Join-Path $DesktopDir "cleanbg-卸载日志.txt"
$Here         = Split-Path -Parent $MyInvocation.MyCommand.Path

function To-File { param([string]$m)
    try { Add-Content -LiteralPath $LogFile -Value ("[" + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + "] " + $m) -Encoding UTF8 } catch {}
}
function Say { param([string]$m, [string]$color = "Gray")
    try { Write-Host $m -ForegroundColor $color } catch { Write-Host $m }
    To-File $m
}
function Head($t) { Write-Host ""; Say ("==== " + $t + " ====") "Cyan" }
function Ok($t)   { Say ("  [OK]   " + $t) "Green" }
function Note($t) { Say ("  [注意] " + $t) "Yellow" }
function Bad($t)  { Say ("  [失败] " + $t) "Red" }
function Ask { param([string]$q)
    if ($NoPause) { return "" }
    try { return (Read-Host $q) } catch { return "" }
}
function Pause-Here { param([string]$q)
    if ($NoPause) { return }
    try { Read-Host $q | Out-Null } catch {}
}
function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-DirGB {
    param([string]$dir)
    # 优先用 robocopy /L 统计（比 PowerShell 递归快几十倍，机械盘上更明显）
    $rc = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    if (Test-Path $rc) {
        try {
            $dummy = Join-Path $env:TEMP '_cleanbg_size_probe_'
            $out = (& $rc $dir $dummy /L /E /BYTES /NFL /NDL /NP 2>$null) -join "`n"
            $m = [regex]::Match($out, '(?m)^\s*Bytes\s*:\s*([0-9\.]+)')
            if ($m.Success) { return [math]::Round([double]$m.Groups[1].Value / 1GB, 2) }
        } catch {}
    }
    try {
        $s = Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
        return [math]::Round($s.Sum / 1GB, 2)
    } catch { return 0 }
}

# ---------------------------------------------------------------- 找 Photoshop
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
    $out = @()
    foreach ($proc in (Get-Process -Name Photoshop -ErrorAction SilentlyContinue)) {
        try { $r = Get-PluginsFromExe $proc.Path; if ($r) { $out += $r } } catch {}
    }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Photoshop.exe',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Photoshop.exe')) {
        $v = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
        if ($v) { $r = Get-PluginsFromExe $v; if ($r) { $out += $r } }
    }
    foreach ($sub in (Get-ChildItem -Path 'HKLM:\SOFTWARE\Adobe\Photoshop' -ErrorAction SilentlyContinue)) {
        foreach ($n in @('PluginPath', 'PluginsPath', 'ApplicationPath')) {
            $v = (Get-ItemProperty -Path $sub.PSPath -Name $n -ErrorAction SilentlyContinue).$n
            if (-not $v) { continue }
            foreach ($one in @($v)) {
                $one = ([string]$one).Trim().TrimEnd('\')
                if (-not $one) { continue }
                if ($one -match '(?i)plug-?ins$') { if (Test-Path $one) { $out += $one } }
                else { $r = Get-PluginsFromExe (Join-Path $one 'Photoshop.exe'); if ($r) { $out += $r } }
            }
        }
    }
    foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
        Get-ItemProperty -Path ($root + '\*') -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Photoshop*' -and $_.InstallLocation } |
            ForEach-Object { $r = Get-PluginsFromExe (Join-Path $_.InstallLocation 'Photoshop.exe'); if ($r) { $out += $r } }
    }
    $drives = @()
    try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object { $_.DeviceID + '\' }) } catch {}
    if ($drives.Count -eq 0) { $drives = @('C:\', 'D:\', 'E:\', 'F:\', 'G:\') }
    foreach ($root in $drives) {
        foreach ($d in (Get-ChildItem -Path ($root + 'Adobe Photoshop*') -Directory -ErrorAction SilentlyContinue)) {
            $r = Get-PluginsFromExe (Join-Path $d.FullName 'Photoshop.exe'); if ($r) { $out += $r }
            foreach ($d2 in (Get-ChildItem -Path (Join-Path $d.FullName 'Adobe Photoshop*') -Directory -ErrorAction SilentlyContinue)) {
                $r2 = Get-PluginsFromExe (Join-Path $d2.FullName 'Photoshop.exe'); if ($r2) { $out += $r2 }
            }
        }
        foreach ($base in @('Program Files\Adobe', 'Program Files (x86)\Adobe', 'Adobe')) {
            $b = Join-Path $root $base
            if (-not (Test-Path $b)) { continue }
            $out += Get-ChildItem -Path $b -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'Adobe Photoshop*' } |
                    ForEach-Object { foreach ($n in @('Plug-ins', 'Plug-Ins')) { $p = Join-Path $_.FullName $n; if (Test-Path $p) { $p } } }
        }
    }
    return @($out | Where-Object { $_ } | Sort-Object -Unique)
}

# ---------------------------------------------------------------- 识别"是不是我们装的后端"
function Test-HasOtherLauncher {   # 绘世/秋葉等第三方启动器的痕迹
    param([string]$dir)
    foreach ($n in @('绘世启动器.exe', 'A绘世启动器.exe', '.launcher', 'bilibili@秋葉aaaki.txt', '秋葉aaaki.txt', 'A启动器.exe')) {
        if (Test-Path (Join-Path $dir $n)) { return $true }
    }
    return $false
}
function Test-OurPortable {   # 便携版整包
    param([string]$dir)
    return ((Test-Path (Join-Path $dir 'install-plugin.ps1')) -and (Test-Path (Join-Path $dir "插件\$PluginName\main.js")))
}
function Test-OurAuto {       # 自动安装包装的（或桌面快捷方式指向的）
    param([string]$dir)
    $key = $dir.TrimEnd('\')
    if (Test-Path (Join-Path $dir $MarkerFile)) { return $true }        # 2.6 起会写标记文件
    if (-not (Test-Path (Join-Path $dir 'ComfyUI\main.py'))) { return $false }
    if (Test-HasOtherLauncher $dir) { return $false }                   # 绘世/秋葉版一律不当成我们的
    if (Test-Path (Join-Path $dir 'ComfyUI\custom_nodes\cleanbg_control')) {
        $trio = (Test-Path (Join-Path $dir 'start_comfy.bat')) -and
                (Test-Path (Join-Path $dir 'stop_comfy.bat')) -and
                (Test-Path (Join-Path $dir 'comfy_watchdog.vbs'))
        if ($trio) { return $true }
    }
    if ($script:ShortcutDirs -contains $key) {
        if (Test-Path (Join-Path $dir 'start_comfy.bat')) { return $true }   # 我们建的桌面快捷方式指着它
    }
    return $false
}

Write-Host ""
Say "################################################" "Cyan"
Say "#   清空环境 · 一键卸载                        #" "Cyan"
Say "#   插件会被卸载；后端(ComfyUI+模型)要你确认才删 #" "Cyan"
Say "################################################" "Cyan"
if ($DryRun) { Say "（预演模式：只看会删什么，不动任何东西）" "Yellow" }
To-File ("---- 开始卸载" + $(if ($DryRun) { "（预演）" } else { "" }) + " ----")

# ---------------------------------------------------------------- 管理员权限
if ((-not $DryRun) -and (-not $NoElevate) -and (-not (Test-Admin))) {
    Write-Host ""
    Say "  需要管理员权限（要删 Program Files 里的插件和后端目录）" "Yellow"
    Say "  正在重新打开：会弹一个窗口，请点【是】" "Yellow"
    To-File "请求管理员权限"
    $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($NoPause) { $psArgs += "-NoPause" }
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Verb RunAs | Out-Null
    } catch {
        Bad ("提权失败：" + $_.Exception.Message)
        Say "  请右键 ①双击我卸载.bat → 以管理员身份运行" "Yellow"
        Pause-Here "`n按回车键退出"
        exit 1
    }
    exit 0
}

# ---------------------------------------------------------------- 第 1 步：清点
Head "第 1 步 · 清点装了什么"

# 1a 插件
$pluginDirs = @()
foreach ($pl in (Find-PSPlugins)) {
    $p = Join-Path $pl $PluginName
    if (Test-Path (Join-Path $p 'main.js')) { $pluginDirs += $p }
}
# 兜底：按常见结构浅层扫一下（很快，不做全盘递归）
foreach ($root in @('C:\', 'D:\', 'E:\', 'F:\', 'G:\')) {
    if (-not (Test-Path $root)) { continue }
    foreach ($pat in @('*\Plug-ins', '*\Plug-Ins', '*\*\Plug-ins', '*\*\Plug-Ins', '*Adobe Photoshop*\Plug-ins')) {
        foreach ($pl in (Get-ChildItem -Path ($root + $pat) -Directory -Force -ErrorAction SilentlyContinue)) {
            $p = Join-Path $pl.FullName $PluginName
            if (Test-Path (Join-Path $p 'main.js')) { $pluginDirs += $p }
        }
    }
}
$pluginDirs = @($pluginDirs | Sort-Object -Unique)
if ($pluginDirs.Count -eq 0) { Note "没找到已安装的插件（可能已经卸过了）" } else {
    foreach ($p in $pluginDirs) { Ok ("插件：" + $p) }
}

# 1b 桌面快捷方式（本机 + 公共 + 其它用户的桌面都看一眼）
$allLnks = @()
$deskCands = @($DesktopDir, "$env:PUBLIC\Desktop")
try { $deskCands += @(Get-ChildItem -Path 'C:\Users\*' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'Desktop' }) } catch {}
foreach ($d in ($deskCands | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    Get-ChildItem -LiteralPath $d -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'ComfyUI' } | ForEach-Object { $allLnks += $_.FullName }
}
$allLnks = @($allLnks | Sort-Object -Unique)

$ws = $null
try { $ws = New-Object -ComObject WScript.Shell } catch {}
$ourLnks = @()        # 我们建的（指向 start/stop_comfy.bat 且名字就是「启动/关闭 ComfyUI」）
$otherLnks = @()      # 你自己建的（只提示）
$script:ShortcutDirs = @()
$lnkDirs = @()
foreach ($l in $allLnks) {
    $name = Split-Path $l -Leaf
    $tgt = ""
    if ($ws) { try { $tgt = ([string]$ws.CreateShortcut($l).TargetPath) } catch {} }
    if ($tgt) {
        $d0 = Split-Path -Parent $tgt
        if ($d0) { $lnkDirs += $d0.TrimEnd('\'); $script:ShortcutDirs += $d0.TrimEnd('\') }
    }
    $base = Split-Path $tgt -Leaf
    if (($base -ieq 'start_comfy.bat' -or $base -ieq 'stop_comfy.bat') -and ($name -match '^\s*(启动|关闭)\s*ComfyUI\.lnk$')) {
        $ourLnks += $l
    } else {
        $otherLnks += $l + "  →  " + $(if ($tgt) { $tgt } else { "（读不到目标）" })
    }
}
$script:ShortcutDirs = @($script:ShortcutDirs | Sort-Object -Unique)
if ($ourLnks.Count -eq 0) { Note "桌面没有本工具建的 ComfyUI 快捷方式" } else { foreach ($l in $ourLnks) { Ok ("快捷方式：" + $l) } }
if ($otherLnks.Count -gt 0) {
    foreach ($l in $otherLnks) { Say ("      （保留，不是我们建的）" + $l) "DarkGray" }
}

# 1c 后端候选（快：默认安装位置 + 快捷方式指向 + 各盘根目录里名字像的目录）
$oursBackends = @()   # 确定是我们的（会问要不要删）
$otherBatDirs = @()   # 只是"也含 start_comfy.bat"（绝不删，只提示）
$candDirs = @()
foreach ($p in @('D:\ComfyUI', 'C:\ComfyUI', 'E:\ComfyUI', 'F:\ComfyUI', 'G:\ComfyUI')) {
    if (Test-Path (Join-Path $p 'start_comfy.bat')) { $candDirs += $p }
}
foreach ($d in $lnkDirs) { if (Test-Path (Join-Path $d 'start_comfy.bat')) { $candDirs += $d } }
foreach ($root in @('C:\', 'D:\', 'E:\', 'F:\', 'G:\')) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem -Path ($root + '*') -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)comfy|清空' } | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName 'start_comfy.bat')) { $candDirs += $_.FullName }
        }
}
$candDirs = @($candDirs | Sort-Object -Unique)
foreach ($dir in $candDirs) {
    if ((Test-OurPortable $dir) -or (Test-OurAuto $dir)) { $oursBackends += $dir }
    elseif (Test-Path (Join-Path $dir 'ComfyUI\main.py')) { $otherBatDirs += $dir }
}
$oursBackends = @($oursBackends | Sort-Object -Unique)
$otherBatDirs = @($otherBatDirs | Sort-Object -Unique)

Write-Host ""
Say "  后端（大件，会先问你）：" "White"
if ($oursBackends.Count -eq 0) { Note "没找到「清空环境」装的后端" }
foreach ($d in $oursBackends) {
    $kind = if (Test-OurPortable $d) { "便携版整包" } else { "自动安装版" }
    Ok ("$kind ：" + $d + "   （" + (Get-DirGB $d) + " GB）")
}
if ($otherBatDirs.Count -gt 0) {
    Write-Host ""
    Note "下面这些目录也含 start_comfy.bat，但**不像**清空环境装的（很可能是你自己常用的 ComfyUI）—— 本工具不会碰它们："
    foreach ($d in $otherBatDirs) { Say ("      " + $d + "   " + (Get-DirGB $d) + " GB") "DarkGray" }
}

# 1d 安装包残留（_下载缓存：7zr.exe 是它的指纹）
$script:cacheDirs = @()
$probe = @('C:\', 'D:\', 'E:\', 'F:\', 'G:\') + @("$env:USERPROFILE\Desktop", "$env:USERPROFILE\Downloads", "$env:PUBLIC\Desktop")
function Find-CacheDir { param([string]$dir, [int]$depth)
    if ($depth -gt 3) { return }
    $subs = @()
    try { $subs = Get-ChildItem -Path (Join-Path $dir '*') -Directory -Force -ErrorAction SilentlyContinue } catch {}
    foreach ($s in $subs) {
        if ($s.Name -eq '_下载缓存') {
            if (Test-Path (Join-Path $s.FullName '7zr.exe')) { $script:cacheDirs += $s.FullName }   # 7zr.exe 是我们的下载器指纹
            continue
        }
        if ($depth -lt 3 -and $s.Name -match '(?i)下载|download|桌面|desktop|idm|解压|清空|cleanbg|comfy|安装|工具|插件|temp|tmp') {
            Find-CacheDir $s.FullName ($depth + 1)
        }
    }
}
foreach ($root in ($probe | Sort-Object -Unique)) {
    if (-not (Test-Path $root)) { continue }
    Find-CacheDir $root 1
}
$cacheDirs = @($cacheDirs | Sort-Object -Unique)
if ($cacheDirs.Count -gt 0) {
    Write-Host ""
    Say "  安装包解压目录里的下载缓存（可选，删了不影响使用）：" "White"
    foreach ($d in $cacheDirs) { Say ("      " + $d + "   " + (Get-DirGB $d) + " GB") "DarkGray" }
}

Write-Host ""
Say "  ── 将要做的操作 ──" "White"
Say ("   1. 关掉正在运行的 ComfyUI") "Gray"
Say ("   2. 卸载插件：" + $pluginDirs.Count + " 个（先备份到桌面  cleanbg-卸载备份\）") "Gray"
Say ("   3. 删快捷方式：" + $ourLnks.Count + " 个") "Gray"
Say ("   4. 设置缓存 / 安装包残留：各问你一次（默认保留）") "Gray"
Say ("   5. 后端：" + $oursBackends.Count + " 个 —— 逐个问你，删之前还会再显示一次大小") "Gray"
if (-not $DryRun) {
    $go = Ask "`n  确认开始卸载吗？（输入 y 继续，其它键取消）"
    if ($go -notmatch '^(y|Y)$') { Note "已取消，什么都没做。"; Pause-Here "`n按回车键退出"; exit 0 }
}

# ---------------------------------------------------------------- 第 2 步：关后端
Head "第 2 步 · 关掉正在运行的 ComfyUI"
if ($DryRun) { Note "预演：不关进程" } else {
    try {
        Invoke-WebRequest -Uri 'http://127.0.0.1:8188/cleanbg/shutdown' -Method POST -TimeoutSec 6 -UseBasicParsing -ErrorAction SilentlyContinue | Out-Null
        Ok "已向本地后端发送关闭指令（如果它在跑）"
    } catch {}
    Start-Sleep -Seconds 3
    $killed = 0
    if ($oursBackends.Count -gt 0) {
        foreach ($pr in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^(python|pythonw|wscript|cscript)\.exe$' })) {
            $cl = "$($pr.CommandLine)"
            foreach ($d in $oursBackends) {
                if ($cl -like "*$d*") { try { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch {}; break }
            }
        }
    }
    if ($killed -gt 0) { Ok ("关掉了 " + $killed + " 个后端进程") } else { Ok "没有后端进程在跑（或不需要关）" }
    Start-Sleep -Seconds 2
}

# ---------------------------------------------------------------- 第 3 步：卸载插件
Head "第 3 步 · 卸载 Photoshop 插件"
if ($pluginDirs.Count -eq 0) { Note "跳过（没找到插件）" } elseif ($DryRun) {
    foreach ($p in $pluginDirs) { Note ("预演：会备份并删除 " + $p) }
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bakDir = Join-Path $WorkRoot $stamp
    $notePath = Join-Path $bakDir "怎么恢复.txt"
    foreach ($p in $pluginDirs) {
        $psDirName = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $p))
        $target = Join-Path $bakDir ($psDirName + "_" + $PluginName)
        try {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Copy-Item -LiteralPath $p -Destination $target -Recurse -Force -ErrorAction Stop
            Ok ("已备份到：" + (Join-Path $target $PluginName))
            $note = "把这里的 cleanbg 文件夹整个拷回下面这个位置，就能恢复插件：`r`n`r`n" +
                    (Split-Path -Parent $p) + "`r`n`r`n拷贝之后重启 Photoshop 即可。`r`n"
            try { [System.IO.File]::WriteAllText($notePath, $note, (New-Object System.Text.UTF8Encoding($true))) } catch {}
        } catch { Note ("备份失败（继续删除）：" + $_.Exception.Message) }
        try {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            if (Test-Path $p) { Bad ("没删掉：" + $p + "  （可能 Photoshop 正开着 → 关掉 PS 再跑一次）") } else { Ok ("已删除：" + $p) }
        } catch { Bad ("删除失败：" + $p + " → " + $_.Exception.Message + "  （右键本 bat → 以管理员身份运行 再试）") }
    }
}

# ---------------------------------------------------------------- 第 4 步：快捷方式
Head "第 4 步 · 删除桌面快捷方式"
if ($ourLnks.Count -eq 0) { Note "跳过（没有我们建的快捷方式）" } elseif ($DryRun) {
    foreach ($l in $ourLnks) { Note ("预演：会删除 " + $l) }
} else {
    foreach ($l in $ourLnks) {
        try { Remove-Item -LiteralPath $l -Force -ErrorAction Stop; Ok ("已删除：" + (Split-Path $l -Leaf)) } catch { Bad ("删不掉：" + $l) }
    }
}

# ---------------------------------------------------------------- 第 5 步：插件设置缓存
Head "第 5 步 · 插件的设置缓存（可选）"
$uxpDirs = @()
foreach ($v in @('26', '27', '28', '29', '30', '31')) {
    $p = "$env:APPDATA\Adobe\UXP\PluginsStorage\PHSP\$v\External\$UxpPluginId"
    if (Test-Path $p) { $uxpDirs += $p }
}
if ($uxpDirs.Count -eq 0) { Note "没有残留设置" } elseif ($DryRun) { foreach ($d in $uxpDirs) { Note ("预演：会删除 " + $d) } } else {
    $a = Ask "  要不要也清掉插件的设置/缓存（只删 cleanbg 自己的，不影响其它插件）？输入 y 清理，其它键保留"
    if ($a -match '^(y|Y)$') {
        foreach ($d in $uxpDirs) { try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; Ok ("已清理：" + $d) } catch { Bad ("清不掉：" + $d) } }
    } else { Note "保留（插件设置还在，以后重装不用重新配）" }
}

# ---------------------------------------------------------------- 第 6 步：后端
Head "第 6 步 · 后端 ComfyUI + 模型（逐个确认）"
if ($oursBackends.Count -eq 0) {
    Note "没有需要删的（清空环境装的）后端"
    if ($otherBatDirs.Count -gt 0) { Note "（上面列的那些是你自己的 ComfyUI，本工具不会删；以后想删请自己手动删）" }
} else {
    foreach ($d in $oursBackends) {
        $gb = Get-DirGB $d
        Write-Host ""
        Say ("  后端目录：" + $d) "White"
        Say ("  占用：" + $gb + " GB") "White"
        Note "删掉后模型要重新下载才能恢复；这一步没有备份（太大）"
        if ($DryRun) { Note "预演：不会删（真跑时这里会问你）"; continue }
        $a = Ask "  输入 y 删除这个后端，其它键=保留"
        if ($a -match '^(y|Y)$') {
            try {
                Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop
                if (Test-Path $d) { Bad ("没删干净：" + $d) } else { Ok ("已删除：" + $d + "（释放约 " + $gb + " GB）") }
            } catch { Bad ("删除失败：" + $_.Exception.Message + "  （可能还有进程占用 → 重启电脑后再跑一次）") }
        } else { Note "保留：" + $d }
    }
}

# ---------------------------------------------------------------- 第 7 步：安装包残留
Head "第 7 步 · 安装包解压目录里的下载缓存（可选）"
if ($cacheDirs.Count -eq 0) { Note "没有找到" } elseif ($DryRun) { foreach ($d in $cacheDirs) { Note ("预演：会删除 " + $d) } } else {
    $a = Ask "  要不要顺手清掉这些下载缓存（安装时下载用的，删了不影响已装好的程序）？输入 y 清理，其它键保留"
    if ($a -match '^(y|Y)$') {
        foreach ($d in $cacheDirs) {
            $gb = Get-DirGB $d
            try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; Ok ("已清理：" + $d + "（释放约 " + $gb + " GB）") } catch { Bad ("清不掉：" + $d) }
        }
    } else { Note "保留（想清可以自己删掉这些 _下载缓存 文件夹）" }
}

# ---------------------------------------------------------------- 第 8 步：复核
Head "第 8 步 · 复核"
$left = @()
foreach ($pl in (Find-PSPlugins)) { $p = Join-Path $pl $PluginName; if (Test-Path (Join-Path $p 'main.js')) { $left += $p } }
if ($left.Count -eq 0) { Ok "插件已卸载干净" } else { Note ("还有 " + $left.Count + " 个插件目录没删掉：" + ($left -join ' ; ')) }
foreach ($l in $ourLnks) { if (Test-Path -LiteralPath $l) { Note ("快捷方式还在：" + $l) } }
foreach ($d in $oursBackends) { if (Test-Path $d) { Note ("后端还在：" + $d) } }
foreach ($d in ($cacheDirs + $uxpDirs)) { if (Test-Path $d) { Note ("还在：" + $d) } }

Write-Host ""
Say "================================================" "Green"
if ($DryRun) { Say " 预演结束（什么都没删）" "Green" }
else {
    Say " 卸载完成！" "Green"
    Say "   · 插件备份在桌面：cleanbg-卸载备份\" "Green"
    Say "   · 日志：桌面\cleanbg-卸载日志.txt" "Green"
    Say "   · 想重装：重新跑「全自动安装包」或把备份的 cleanbg 放回 Plug-ins" "Green"
}
Say "================================================" "Green"
To-File "---- 结束 ----"
Pause-Here "`n按回车键关闭这个窗口"
