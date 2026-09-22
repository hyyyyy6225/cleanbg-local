<#
================================================================================
  「清空环境」Photoshop 插件 · 全自动安装脚本
--------------------------------------------------------------------------------
  这个脚本会自动完成：
    1. 检查电脑环境（显卡 / 内存 / 磁盘 / Photoshop）
    2. 安装 VC++ 运行库（缺的话）
    3. 下载并解压 ComfyUI 官方便携版（约 1.8 GB）
    4. 下载 6 个 AI 模型（约 18.2 GB，国内 ModelScope / hf-mirror 直连；其中 5 个走作者自建的魔搭镜像（固定 v2 版本），主模型走魔搭官方仓库）
    5. 安装 3 个自定义节点 + 关掉后端的小节点
    6. 把插件装进 Photoshop，并把路径改好
    7. 建桌面快捷方式，最后启动一次后端做自检

  用法（不会操作的话，直接双击同目录的「①双击我开始安装.bat」即可）：
      powershell -ExecutionPolicy Bypass -File .\install.ps1
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallDir "E:\ComfyUI"
      powershell -ExecutionPolicy Bypass -File .\install.ps1 -CheckOnly     # 只测下载源，不装

  可以重复运行：已经装好的步骤会自动跳过（下载中断了，再双击一次会接着下）。
  全程日志写在同目录的「安装日志.txt」里，出问题把它发给帮你装的人。
================================================================================
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$SkipModels,
    [switch]$CheckOnly
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }
try { $here = (Resolve-Path $here).Path } catch {}
$logFile = Join-Path $here "安装日志.txt"
$stage   = Join-Path $here "_下载缓存"

# ------------------------------------------------------------------ 素材定位
# 本脚本有两种被使用的布局，两种都要能跑：
#   ① 安装包布局：素材就在本脚本旁边（1-插件本体\ / 2-后端脚本\ / 3-自定义节点\）
#   ② 仓库布局  ：从 GitHub 下载仓库 ZIP 解压后直接双击（素材在仓库根：plugin\ / backend\ / custom_nodes\）
# Resolve-Asset 依次尝试上面两套路径，谁存在就用谁。$here\..\.. = 仓库根。
$assetRoots = @()
foreach ($r in @($here, (Join-Path $here ".."), (Join-Path $here "..\.."))) {
    try { $assetRoots += (Resolve-Path -LiteralPath $r -ErrorAction Stop).Path } catch {}
}
function Resolve-Asset {
    param([string[]]$Rel)
    # 注意：循环变量必须用与参数不同的名字。PowerShell 变量大小写不敏感，
    # 若写成 foreach ($rel in $Rel) 就是"自己遍历自己"，元素会变成 String[] 而不是字符串。
    foreach ($cand in $Rel) {
        foreach ($root in $assetRoots) {
            $p = Join-Path $root $cand
            if (Test-Path -LiteralPath $p) { return $p }
        }
    }
    return $null
}

# ------------------------------------------------------------------ 输出/日志
function Log {
    param([string]$m, [string]$color = "Gray")
    $t = (Get-Date).ToString("HH:mm:ss")
    $line = "[$t] $m"
    try { Write-Host $m -ForegroundColor $color } catch { Write-Host $m }
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}
function Banner {
    param([string]$m)
    Write-Host ""
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
    Write-Host ("  " + $m) -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkCyan
    try { Add-Content -Path $logFile -Value ("`r`n" + ("=" * 74) + "`r`n  " + $m) -Encoding UTF8 } catch {}
}
function Step {
    param([int]$n, [int]$total, [string]$m)
    Banner ("第 $n / $total 步 · $m")
}
function Ok   { param([string]$m) Log ("  [OK]   " + $m) "Green" }
function Warn { param([string]$m) Log ("  [注意] " + $m) "Yellow" }
function Bad  { param([string]$m) Log ("  [失败] " + $m) "Red" }

Log ("安装开始 · " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Log ("脚本目录: " + $here)
Log ("系统: " + [System.Environment]::OSVersion.VersionString + "  PowerShell " + $PSVersionTable.PSVersion.ToString())

# ------------------------------------------------------------------ 管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $CheckOnly) {
    Log ""
    Log "  需要管理员权限（要往 Photoshop 目录装插件、可能还要装运行库）。" "Yellow"
    Log "  稍后会弹出一个「用户帐户控制」窗口，请点【是】。" "Yellow"
    try {
        $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($InstallDir) { $psArgs += @("-InstallDir", "`"$InstallDir`"") }
        Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Verb RunAs | Out-Null
        Log "  已在新的管理员窗口里继续，这个窗口可以关掉了。" "Green"
    } catch {
        Bad ("提权失败：" + $_.Exception.Message)
        Log "  请右键这个脚本 → 以管理员身份运行。" "Yellow"
    }
    Read-Host "`n按回车键退出"
    exit
}
if ($isAdmin) { Ok "已获得管理员权限" }

# ------------------------------------------------------------------ 下载工具
$curl = Join-Path $env:SystemRoot "System32\curl.exe"
if (-not (Test-Path $curl)) { $curl = "curl.exe" }
Ok ("下载工具: " + $curl)

function Test-Url {
    param([string]$url)
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "Mozilla/5.0"
        $req.Method = "HEAD"
        $req.AllowAutoRedirect = $true
        $req.Timeout = 30000
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -ge 200 -and $code -lt 400)
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { return ([int]$_.Exception.Response.StatusCode -lt 400) }
        return $false
    } catch { return $false }
}

# 多镜像依次尝试，支持断点续传
function Get-BigFile {
    param([string[]]$urls, [string]$dest, [int64]$expect, [string]$name)

    function Test-Got { (Test-Path $dest) -and ((Get-Item $dest).Length -ge ($expect - 1048576)) }

    if (Test-Got) {
        Ok ("$name 已存在，跳过下载")
        return $true
    }
    foreach ($u in $urls) {
        Log ("  下载 $name  ← " + ($u -replace '^https?://([^/]+)/.*$', '$1'))

        # 方式一：curl（支持断点续传，有进度条）
        try {
            & $curl --progress-bar -L -C - --retry 5 --retry-delay 3 -m 21600 -H "User-Agent: Mozilla/5.0" -o $dest $u
        } catch { }
        if (Test-Got) {
            Ok ("$name 下载完成 (" + [math]::Round((Get-Item $dest).Length / 1MB, 1) + " MB)")
            return $true
        }

        # 方式二：BITS（Windows 自带，很稳，但没有进度条）
        try {
            if (Test-Path $dest) { Remove-Item $dest -Force -ErrorAction SilentlyContinue }
            Import-Module BitsTransfer -ErrorAction SilentlyContinue
            Start-BitsTransfer -Source $u -Destination $dest -Priority Foreground -RetryInterval 10 -RetryTimeout 3600 -ErrorAction Stop
        } catch { }
        if (Test-Got) {
            Ok ("$name 下载完成 (" + [math]::Round((Get-Item $dest).Length / 1MB, 1) + " MB)")
            return $true
        }
        Warn "这个源没成功，换下一个（已下部分会保留，下次接着下）"
    }
    Bad "$name 所有下载源都失败了"
    return $false
}

# ------------------------------------------------------------------ 第 1 步：环境检查
Step 1 8 "检查电脑环境"
$ok = $true

$os = [System.Environment]::OSVersion.Version
Log ("  Windows 版本: " + $os.Major + "." + $os.Minor + " (build " + $os.Build + ")")
if ($os.Major -lt 10) { Bad "需要 Windows 10 或更高版本"; $ok = $false } else { Ok "系统版本可以" }

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Log ("  内存: $ramGB GB")
if ($ramGB -lt 16) { Warn ("内存只有 " + $ramGB + " GB，低于实测下限（16 GB），可能跑不动；建议加到 16 GB 以上") } else { Ok ("内存 " + $ramGB + " GB，够用") }

$gpu = "未知"
try {
    $smiPaths = @(
        (Join-Path $env:SystemRoot "System32\nvidia-smi.exe"),
        "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    )
    $smi = $smiPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($smi) {
        $out = & $smi --query-gpu=name,memory.total --format=csv,noheader 2>$null
        if ($out) { $gpu = ($out | Select-Object -First 1).ToString().Trim() }
    }
    if ($gpu -eq "未知") {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vc) {
            $gpu = $vc.Name
            if ($vc.AdapterRAM) { $gpu += "  (显存约 " + [math]::Round($vc.AdapterRAM / 1GB, 1) + " GB)" }
        }
    }
} catch { }
if ($gpu -eq "未知") {
    Warn "没找到 NVIDIA 显卡驱动（nvidia-smi）。如果是 N 卡，请先装最新显卡驱动；A 卡/集显跑得动但很慢。"
} else {
    Log ("  显卡: " + $gpu)
    if ($gpu -match "(\d+)\s*MiB") {
        $vram = [int]$Matches[1] / 1024
        if ($vram -lt 8) { Warn ("显存约 " + [math]::Round($vram, 1) + " GB，低于实测下限（8 GB），可能跑不动；可先装，运行时把生成规模选「快」") }
elseif ($vram -lt 12) { Warn ("显存约 " + [math]::Round($vram, 1) + " GB —— 能跑但慢：请把生成规模选「快（1.8MP）」+ 4 步") }
        else { Ok ("显存约 " + [math]::Round($vram, 1) + " GB，够用") }
    }
}

# Photoshop 的 Plug-ins 目录
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
$psDirs = Find-PSPlugins
if ($psDirs.Count -eq 0) {
    Warn "没找到 Photoshop 的 Plug-ins 目录 —— 插件部分会跳过，装完请把 1-插件本体\cleanbg 手动复制到 Photoshop 的 Plug-ins 里"
} else {
    $PSPlugins = $psDirs[0]
    Ok ("Photoshop 插件目录: " + $PSPlugins)
    if ($psDirs.Count -gt 1) { Warn ("还发现其它版本：" + ($psDirs[1..($psDirs.Count-1)] -join " | ")) }
}

# VC++ 运行库
$vcKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
$vcInstalled = (Test-Path $vcKey) -and ((Get-ItemProperty $vcKey -ErrorAction SilentlyContinue).Installed -eq 1)
if ($vcInstalled) { Ok "VC++ 运行库已安装" } else { Warn "VC++ 运行库缺失，第 2 步会装上" }

# ------------------------------------------------------------------ 第 2 步：VC++ 运行库
Step 2 8 "安装 VC++ 运行库（AI 推理必需）"
if ($CheckOnly) {
    Ok "自检模式，跳过"
} elseif ($vcInstalled) {
    Ok "已安装，跳过"
} else {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $vc = Join-Path $stage "vc_redist.x64.exe"
    if (Get-BigFile -urls @("https://aka.ms/vs/17/release/vc_redist.x64.exe") -dest $vc -expect 20000000 -name "VC++ 运行库") {
        Log "  静默安装中（约 1 分钟）…"
        $p = Start-Process -FilePath $vc -ArgumentList "/install", "/quiet", "/norestart" -Wait -PassThru
        Log ("  安装程序返回码: " + $p.ExitCode)
        Ok "VC++ 运行库安装完成"
    } else {
        Warn "VC++ 运行库没装上。如果后面 ComfyUI 起不来，请手动运行：" + $vc
    }
}

# ------------------------------------------------------------------ 下载源定义
$MS_UNET = "https://modelscope.cn/api/v1/models/black-forest-labs/FLUX.2-klein-9b-fp8/repo?Revision=master&FilePath=flux-2-klein-9b-fp8.safetensors"
$MS_CLIP = "https://modelscope.cn/api/v1/models/Comfy-Org/flux2-klein-9B/repo?Revision=master&FilePath=split_files%2Ftext_encoders%2Fqwen_3_8b_fp8mixed.safetensors"
$MS_VAE  = "https://modelscope.cn/api/v1/models/Comfy-Org/flux2-klein-9B/repo?Revision=master&FilePath=split_files%2Fvae%2Fflux2-vae.safetensors"
$HF_VAE  = "https://hf-mirror.com/Comfy-Org/vae-text-encorder-for-flux-klein-4b/resolve/main/split_files/vae/flux2-vae.safetensors"
$HF_UP   = "https://hf-mirror.com/Kim2091/UltraSharp/resolve/main/4x-UltraSharp.pth"
$HF_LORA = "https://hf-mirror.com/prithivMLmods/FLUX.2-Klein-Object-Remover-Bbox/resolve/main/FLUX.2-Klein-Object-Remover-Bbox-5000.safetensors"
$HF_BIRE = "https://hf-mirror.com/ZhengPeng7/BiRefNet/resolve/main/model.safetensors"

# 作者自建镜像（魔搭，固定 v1 版本；比第三方镜像稳，出处见仓库 README）
$OWN_BASE = "https://modelscope.cn/api/v1/models/zdccy123/cleanbg-models/repo?Revision=v2&FilePath="
$OWN_UP   = $OWN_BASE + "upscale_models%2F4x-UltraSharp.pth"
$OWN_LORA = $OWN_BASE + "loras%2FF2K9B_ObjectRemover.safetensors"
$OWN_BIRE = $OWN_BASE + "BiRefNet%2FGeneral.safetensors"
$OWN_VAE  = $OWN_BASE + "vae%2Fflux2-vae.safetensors"
$OWN_CLIP = $OWN_BASE + "clip%2Fqwen_3_8b_fp8mixed.safetensors"
$OWN_UNET = $OWN_BASE + "unet%2Fflux-2-klein-9b-fp8.safetensors"
$PORTABLE_GH  = "https://github.com/Comfy-Org/ComfyUI/releases/download/v0.36.0/ComfyUI_windows_portable_nvidia.7z"
$PORTABLE_MIR = @(
    "https://gh-proxy.com/$PORTABLE_GH",
    "https://hk.gh-proxy.com/$PORTABLE_GH",
    "https://ghfast.top/$PORTABLE_GH",
    "https://ghproxy.net/$PORTABLE_GH",
    $PORTABLE_GH
)

# ---------------------------------------------------------------- 自定义节点包的下载源
# github.com 在国内经常连不上（curl 56 Connection reset / 28 Failed to connect），
# 所以每个节点包都按「GitHub 镜像 → 作者自建魔搭镜像 → 直连 GitHub」的顺序试。
$GH_MIRRORS = @(
    "https://gh-proxy.com/",
    "https://hk.gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/"
)
$OWN_NODES  = "https://modelscope.cn/api/v1/models/zdccy123/cleanbg-models/repo?Revision=master&FilePath=nodes%2F"
function Get-NodeUrls {
    param([string]$GhUrl, [string]$Mine)
    $list = @()
    foreach ($m in $GH_MIRRORS) { $list += ($m + $GhUrl) }
    if ($Mine) { $list += ($OWN_NODES + $Mine) }
    $list += $GhUrl
    return $list
}

if ($CheckOnly) {
    Step 0 1 "只测试下载源（不安装）"
    $tests = @(
        @("ComfyUI 便携版", $PORTABLE_MIR[0]),
        @("扩散模型 UNET",  $MS_UNET),
        @("文本编码器 CLIP(自建镜像)", $OWN_CLIP),
        @("VAE(自建镜像)",             $OWN_VAE),
        @("放大模型",        $OWN_UP),
        @("移除 LoRA",       $OWN_LORA),
        @("抠人 BiRefNet",   $OWN_BIRE),
        @("节点包(GitHub镜像)", "https://gh-proxy.com/https://github.com/kijai/ComfyUI-KJNodes/archive/refs/heads/main.zip"),
        @("节点包(魔搭自建)",   ($OWN_NODES + "ComfyUI-KJNodes.zip"))
    )
    foreach ($t in $tests) {
        if (Test-Url -url $t[1]) { Ok ($t[0] + " 下载源可用") } else { Bad ($t[0] + " 下载源不可用：" + $t[1]) }
    }
    Log ""
    Log ("自检完成，日志在：" + $logFile)
    return
}

# ------------------------------------------------------------------ 第 3 步：安装目录
Step 3 8 "选择安装目录"
if (-not $InstallDir) {
    if (Test-Path "D:\") { $InstallDir = "D:\ComfyUI" } else { $InstallDir = "C:\ComfyUI" }
}
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
# 写一个安装标记：卸载工具靠它认出「这是我们装的后端」（别删这个文件）
try {
    $mark = @{ tool = "cleanbg"; version = "2.6"; installedAt = (Get-Date).ToString("s"); installDir = $InstallDir } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $InstallDir "cleanbg-install.json"), $mark, (New-Object System.Text.UTF8Encoding($false)))
} catch {}
$drive = (Get-Item $InstallDir).PSDrive.Name + ":"
$freeGB = [math]::Round((Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB, 1)
Log ("  安装目录: $InstallDir")
Log ("  $drive 剩余空间: $freeGB GB")
if ($freeGB -lt 45) {
    Bad "空间不够（需要 45 GB 以上，模型就占 18 GB）"
    Log "  请清理磁盘后重新运行本脚本。" "Yellow"
    Read-Host "`n按回车键退出"
    exit 1
}
Ok "空间够用"

New-Item -ItemType Directory -Force -Path $stage | Out-Null

# ------------------------------------------------------------------ 第 4 步：ComfyUI 便携版
Step 4 8 "下载并解压 ComfyUI（约 1.8 GB）"
$sevenZip = Resolve-Asset @("7zr.exe")
if (-not $sevenZip) {
    $sevenZip = Join-Path $stage "7zr.exe"
    if (-not (Get-BigFile -urls (Get-NodeUrls -GhUrl "https://github.com/ip7z/7zip/releases/download/26.03/7zr.exe" -Mine "7zr.exe") -dest $sevenZip -expect 500000 -name "7zr.exe 解压工具")) {
        Bad "解压工具下载失败，无法继续"
        Read-Host "`n按回车键退出"; exit 1
    }
}

$mainPy = Join-Path $InstallDir "ComfyUI\main.py"
if (Test-Path $mainPy) {
    Ok "ComfyUI 已经装好了，跳过"
} else {
    $pkg = Join-Path $stage "ComfyUI_windows_portable_nvidia.7z"
    if (-not (Get-BigFile -urls $PORTABLE_MIR -dest $pkg -expect 1800000000 -name "ComfyUI 便携版")) {
        Bad "便携版下载失败。可以手机热点重试，或让给你插件的人把 U 盘里的 ComfyUI 拷过来"
        Read-Host "`n按回车键退出"; exit 1
    }
    Log "  解压中（1.8 GB，约 3-8 分钟，请别关窗口）…"
    $unpack = Join-Path $stage "_unpack"
    if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force -ErrorAction SilentlyContinue }
    & $sevenZip x $pkg "-o$unpack" -y | Out-Null
    $inner = Join-Path $unpack "ComfyUI_windows_portable"
    if (-not (Test-Path $inner)) { $inner = (Get-ChildItem $unpack -Directory | Select-Object -First 1).FullName }
    Log "  移动到安装目录…"
    Get-ChildItem $inner -Force | Move-Item -Destination $InstallDir -Force
    if (Test-Path $mainPy) {
        Ok "ComfyUI 安装完成: $InstallDir"
        Remove-Item $pkg -Force -ErrorAction SilentlyContinue
        Remove-Item $unpack -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Bad "解压结果不对，没找到 $mainPy"
        Read-Host "`n按回车键退出"; exit 1
    }
}

# ------------------------------------------------------------------ 第 5 步：模型
Step 5 8 "下载 AI 模型（约 18.2 GB —— 最久的一步，可以放着不管）"
$models = Join-Path $InstallDir "ComfyUI\models"
foreach ($d in @("unet","clip","vae","upscale_models","loras","BiRefNet")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $models $d) | Out-Null
}

if (-not $SkipModels) {
    # 小的先下（能快速看到进展）
    Get-BigFile -urls @($OWN_VAE, $MS_VAE, $HF_VAE) -dest (Join-Path $models "vae\flux2-vae.safetensors")        -expect 336211292 -name "VAE 模型 (313 MB)"    | Out-Null
    Get-BigFile -urls @($OWN_UP, $HF_UP)            -dest (Join-Path $models "upscale_models\4x-UltraSharp.pth") -expect 66961958  -name "放大模型 (62 MB)"     | Out-Null
    Get-BigFile -urls @($OWN_LORA, $HF_LORA)          -dest (Join-Path $models "loras\F2K9B_ObjectRemover.safetensors") -expect 87070328 -name "移除 LoRA (81 MB)" | Out-Null
    Get-BigFile -urls @($OWN_BIRE, $HF_BIRE)          -dest (Join-Path $models "BiRefNet\General.safetensors")     -expect 444473596 -name "抠人模型 (414 MB)"    | Out-Null
    # 大的后下
    Get-BigFile -urls @($OWN_CLIP, $MS_CLIP)          -dest (Join-Path $models "clip\qwen_3_8b_fp8mixed.safetensors") -expect 8664848742 -name "文本编码器 (8.07 GB)" | Out-Null
    Get-BigFile -urls @($OWN_UNET, $MS_UNET)          -dest (Join-Path $models "unet\flux-2-klein-9b-fp8.safetensors") -expect 9433061528 -name "主模型 (8.79 GB)"   | Out-Null

    # 包里自带的两个模型（如果有，就本地复制，省一次下载）
    $bundled = Resolve-Asset @("4-附加模型")
    if ($bundled) {
        foreach ($p in @(@("F2K9B_ObjectRemover.safetensors","loras"), @("General.safetensors","BiRefNet"))) {
            $src = Join-Path $bundled $p[0]
            $dst = Join-Path $models ($p[1] + "\" + $p[0])
            if ((Test-Path $src) -and -not ((Test-Path $dst) -and ((Get-Item $dst).Length -ge 1000000))) {
                Log ("  从安装包里复制 " + $p[0])
                Copy-Item $src $dst -Force
                Ok ($p[0] + " 已就位")
            }
        }
    }

    # 最终校验
    $need = @(
        @("unet\flux-2-klein-9b-fp8.safetensors", 9433061528, "主模型"),
        @("clip\qwen_3_8b_fp8mixed.safetensors",  8664848742, "文本编码器"),
        @("vae\flux2-vae.safetensors",             336211292, "VAE"),
        @("upscale_models\4x-UltraSharp.pth",       66961958, "放大模型"),
        @("loras\F2K9B_ObjectRemover.safetensors",  87070328, "移除 LoRA"),
        @("BiRefNet\General.safetensors",          444473596, "抠人模型")
    )
    $allOk = $true
    foreach ($n in $need) {
        $f = Join-Path $models $n[0]
        if ((Test-Path $f) -and ((Get-Item $f).Length -ge ($n[1] - 1048576))) { Ok ($n[2] + " 就位") }
        else { Bad ($n[2] + " 缺失或不完整：" + $f); $allOk = $false }
    }
    # ---- SHA256 完整性校验（4 个小模型全量校验；两个大模型只查大小，省时间）----
    $shaMap = @{
        "BiRefNet\General.safetensors" = "9ab37426bf4de0567af6b5d21b16151357149139362e6e8992021b8ce356a154"
        "clip\qwen_3_8b_fp8mixed.safetensors" = "be2e86b1dd68bcb6818acf159c5b038d37495496e0a7355734ae0c64edce144c"
        "loras\F2K9B_ObjectRemover.safetensors" = "d3b728e744b09ddf5ea20142f5e559162eabb243f3744298165a7de1ecf5f903"
        "unet\flux-2-klein-9b-fp8.safetensors" = "865ba09f5b4c3cbd3468a4bd3acb9fcb2f8740c54317482f0bcd4ed1d3655cee"
        "upscale_models\4x-UltraSharp.pth" = "a5812231fc936b42af08a5edba784195495d303d5b3248c24489ef0c4021fe01"
        "vae\flux2-vae.safetensors" = "868fe7b343cc8f3a19dbcfcafbc3d5f888802be3f89bd81b65b3621a066ce8f3"
    }
    $smallFiles = @("vae\flux2-vae.safetensors", "upscale_models\4x-UltraSharp.pth", "loras\F2K9B_ObjectRemover.safetensors", "BiRefNet\General.safetensors")
    foreach ($sf in $smallFiles) {
        $fp = Join-Path $models $sf
        if (-not (Test-Path $fp)) { continue }
        $real = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash.ToLower()
        if ($real -eq $shaMap[$sf]) { Ok ($sf + " SHA256 校验通过") }
        else {
            Bad ($sf + " SHA256 不匹配 —— 文件可能损坏或被换过，已删掉，再双击一次安装脚本会重下")
            Remove-Item -LiteralPath $fp -Force -ErrorAction SilentlyContinue
            $allOk = $false
        }
    }
    Log "  （两个大模型只校验文件大小：完整 SHA256 校验要多花几分钟，需要时可手动核对 docs\依赖清单.md）"

    if (-not $allOk) {
        Warn "有模型没下完。再双击一次安装脚本，会接着下没完成的部分。"
    }
} else {
    Warn "按参数要求跳过了模型下载"
}

# ------------------------------------------------------------------ 第 6 步：自定义节点
Step 6 8 "安装 ComfyUI 自定义节点"
$custom = Join-Path $InstallDir "ComfyUI\custom_nodes"
New-Item -ItemType Directory -Force -Path $custom | Out-Null

$nodes = @(
    @{ name="ComfyUI-KJNodes";              zip="https://github.com/kijai/ComfyUI-KJNodes/archive/refs/heads/main.zip";                    dir="comfyui-KJNodes";               pip=$true  },
    @{ name="ComfyUI_BiRefNet_ll";          zip="https://github.com/lldacing/ComfyUI_BiRefNet_ll/archive/refs/heads/main.zip";             dir="ComfyUI_BiRefNet_ll";           pip=$true  },
    @{ name="Comfyui-PainterFluxImageEdit"; zip="https://github.com/princepainter/Comfyui-PainterFluxImageEdit/archive/refs/heads/main.zip"; dir="Comfyui-PainterFluxImageEdit"; pip=$false },
    @{ name="ComfyUI_essentials";           zip="https://github.com/cubiq/ComfyUI_essentials/archive/refs/heads/main.zip";                 dir="ComfyUI_essentials";            pip=$true  },
    @{ name="RES4LYF";                      zip="https://github.com/ClownsharkBatwing/RES4LYF/archive/refs/heads/main.zip";                dir="RES4LYF";                       pip=$true  }
)

$pyEmbed = Join-Path $InstallDir "python_embeded\python.exe"
if (-not (Test-Path $pyEmbed)) { $pyEmbed = Join-Path $InstallDir "python\python.exe" }

foreach ($n in $nodes) {
    $target = Join-Path $custom $n.dir
    if (Test-Path $target) { Ok ($n.name + " 已安装，跳过"); continue }
    $zip = Join-Path $stage ($n.name + ".zip")
    $nodeUrls = Get-NodeUrls -GhUrl $n.zip -Mine ($n.name + ".zip")
    if (-not (Get-BigFile -urls $nodeUrls -dest $zip -expect 5000 -name ($n.name + " 节点包"))) { Bad ($n.name + " 下载失败"); continue }
    $tmp = Join-Path $stage ("x_" + $n.name)
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        # 关键：找出真正含代码的目录（不能取第一个，GitHub 压缩包第一个常是 .github）
        $inner = Get-ChildItem $tmp -Directory -Force | Where-Object { $_.Name -notmatch "^\\." } | Select-Object -First 1
        if (-not $inner) { throw "解压后没有找到代码目录" }
        Move-Item $inner.FullName $target -Force
        Ok ($n.name + " 已安装")
    } catch {
        Bad ($n.name + " 解压失败：" + $_.Exception.Message)
    }
}

# 关掉后端用的小节点（本包自带）
$ctrlSrc = Resolve-Asset @("3-自定义节点\cleanbg_control", "custom_nodes\cleanbg_control")
$ctrlDst = Join-Path $custom "cleanbg_control"
if ($ctrlSrc) {
    if (Test-Path $ctrlDst) { Remove-Item $ctrlDst -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item $ctrlSrc $ctrlDst -Recurse -Force
    Ok "cleanbg_control 已安装（提供一键关闭接口）"
} else {
    Warn "没找到 cleanbg_control（3-自定义节点\ 或 custom_nodes\），【关闭 ComfyUI】按钮会退化成跑脚本"
}

# pip 依赖
if (Test-Path $pyEmbed) {
    Log "  安装节点依赖（用清华镜像，约 2-5 分钟）…"
    & $pyEmbed -m pip install --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple 2>&1 | ForEach-Object { if ($_ -match "Successfully|ERROR") { Log ("    " + $_) } }
    foreach ($n in $nodes) {
        if (-not $n.pip) { continue }
        $req = Join-Path $custom ($n.dir + "\requirements.txt")
        if (Test-Path $req) {
            Log ("  安装 " + $n.name + " 的依赖…")
            & $pyEmbed -m pip install -r $req -i https://pypi.tuna.tsinghua.edu.cn/simple 2>&1 |
                ForEach-Object { if ($_ -match "Successfully installed|ERROR|No matching") { Log ("    " + $_) } }
        }
    }
    Ok "节点依赖处理完成"
} else {
    Warn "没找到便携版的 python.exe，节点依赖没装。若启动报缺模块，请把日志发出来。"
}

# ------------------------------------------------------------------ 第 7 步：后端脚本 + PS 插件
Step 7 8 "安装后端脚本和 Photoshop 插件"
$backendGot = 0
foreach ($f in @("start_comfy.bat", "stop_comfy.bat", "comfy_watchdog.vbs")) {
    $s = Resolve-Asset @(("2-后端脚本\" + $f), ("backend\" + $f))
    if ($s) { Copy-Item $s (Join-Path $InstallDir $f) -Force; $backendGot++ }
}
if ($backendGot -eq 3) {
    Ok "后端脚本已放到 $InstallDir"
} else {
    Warn ("后端脚本只找到 " + $backendGot + "/3 个 —— 桌面快捷方式可能无效，请把日志发给作者")
}

if ($PSPlugins) {
    $srcPlugin = Resolve-Asset @("1-插件本体\cleanbg", "插件\cleanbg", "plugin\cleanbg")
    $dstPlugin = Join-Path $PSPlugins "cleanbg"
    if ($srcPlugin) {
        if (Test-Path $dstPlugin) { Remove-Item $dstPlugin -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item $srcPlugin $dstPlugin -Recurse -Force
        # 把插件里的后端路径改成这台电脑的安装目录（新老两种格式都兼容；写完必须读回校验）
        $mainJs = Join-Path $dstPlugin "main.js"
        $fwd = ($InstallDir -replace '\\', '/')
        $raw = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8)
        $hits = 0
        $new1 = 'const COMFY_DIR_DEFAULT = "' + $fwd + '";'
        $tmp = [regex]::Replace($raw, 'const COMFY_DIR_DEFAULT\s*=\s*"[^"]*"\s*;', $new1)
        if ($tmp -ne $raw) { $hits++; $raw = $tmp }
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

        # 读回校验：真从磁盘读回来才算成功（曾经出现过"报成功其实没落盘"）
        $back = ""
        try { $back = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8) } catch {}
        $wroteOk = $false
        if ($back -match ('COMFY_DIR_DEFAULT\s*=\s*"' + [regex]::Escape($fwd) + '"')) { $wroteOk = $true }
        elseif ($back -match ('COMFY_ROOT\s*=\s*"' + [regex]::Escape($fwd) + '/ComfyUI"')) { $wroteOk = $true }
        if (-not (Test-Path $mainJs)) {
            Bad ("插件没写进去：" + $mainJs)
        } elseif ($hits -eq 0) {
            Warn "插件里的路径常量没匹配到（版本可能不一样）。不影响使用：新版插件会自己找后端目录。"
        } elseif ($wroteOk) {
            Ok ("插件已装到 " + $dstPlugin + "（路径已指向 " + $fwd + "，已读回校验）")
        } else {
            Bad "路径改写没生效！插件会退化成运行时自动查找后端目录（一般也能用），但请把日志发给作者。"
        }
    } else {
        Warn "没找到插件文件（1-插件本体\cleanbg 或 plugin\cleanbg）—— 请把日志发给作者"
    }
}

# ------------------------------------------------------------------ 第 8 步：快捷方式 + 自检
Step 8 8 "建快捷方式并做最后自检"
try {
    $ws = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath("Desktop")
    $lnk = $ws.CreateShortcut((Join-Path $desk "启动 ComfyUI.lnk"))
    $lnk.TargetPath = Join-Path $InstallDir "start_comfy.bat"
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Description = "启动本地 AI 后端（清空环境插件用）"
    $lnk.Save()
    Ok ("桌面快捷方式已创建：" + (Join-Path $desk "启动 ComfyUI.lnk"))

    $lnk2 = $ws.CreateShortcut((Join-Path $desk "关闭 ComfyUI.lnk"))
    $lnk2.TargetPath = Join-Path $InstallDir "stop_comfy.bat"
    $lnk2.WorkingDirectory = $InstallDir
    $lnk2.Save()
    Ok "桌面「关闭 ComfyUI」快捷方式已创建"
} catch {
    Warn ("快捷方式创建失败：" + $_.Exception.Message)
}

# 试着启动一次后端，确认能起来
# （先关掉可能还在运行的旧后端，否则新装的节点不会被加载）
try {
    Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 4 -UseBasicParsing | Out-Null
    Log "  检测到后端还在运行，先关掉它（新装的节点必须重启才生效）…"
    try { Invoke-WebRequest -Uri "http://127.0.0.1:8188/cleanbg/shutdown" -Method POST -TimeoutSec 8 -UseBasicParsing | Out-Null } catch { }
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        try { Invoke-WebRequest -Uri "http://127.0.0.1:8188/system_stats" -TimeoutSec 3 -UseBasicParsing | Out-Null } catch { break }
    }
    Ok "旧后端已关闭"
} catch { }

Log "  启动一次后端做自检（首次启动约 1 分钟）…"
try {
    Start-Process -FilePath (Join-Path $InstallDir "start_comfy.bat") -WorkingDirectory $InstallDir -WindowStyle Minimized | Out-Null
    $okPing = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:8188/cleanbg/ping" -TimeoutSec 4 -UseBasicParsing
            if ($r.StatusCode -eq 200) { $okPing = $true; break }
        } catch { }
        if ($i % 5 -eq 4) { Log ("    等待后端启动… " + (($i + 1) * 3) + " 秒") }
    }
    if ($okPing) {
        Ok "后端启动成功，关闭接口正常"

        # ---- 关键：验证插件需要的每个节点类型是否真的能加载 ----
        Log "  正在验证插件需要的节点是否齐全…"
        $chk = Join-Path $stage "_nodecheck.py"
        $chkCode = @'
import json, urllib.request, sys
need = ["GetImageSize+","ImageResizeKJv2","ColorMatch","PainterFluxImageEdit",
        "AutoDownloadBiRefNetModel","GetMaskByBiRefNet","ImageScaleToTotalPixels",
        "ImageCompositeMasked","GrowMask","MaskToImage","ImageToMask","LoraLoaderModelOnly"]
d = json.load(urllib.request.urlopen("http://127.0.0.1:8188/object_info", timeout=240))
miss = [c for c in need if c not in d]
try:
    sch = d.get("KSampler",{}).get("input",{}).get("required",{}).get("scheduler",[[]])[0]
    hasBeta57 = "beta57" in sch
except Exception:
    hasBeta57 = False
try:
    ct = d.get("CLIPLoader",{}).get("input",{}).get("required",{}).get("type",[[]])[0]
    hasFlux2 = "flux2" in ct
except Exception:
    hasFlux2 = False
print("MISSING=" + ",".join(miss))
print("BETA57=" + ("yes" if hasBeta57 else "no"))
print("FLUX2=" + ("yes" if hasFlux2 else "no"))
'@
        [System.IO.File]::WriteAllText($chk, $chkCode, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $pyEmbed) {
            $out = & $pyEmbed -X utf8 $chk 2>$null
            $missLine = ($out | Where-Object { $_ -like "MISSING=*" }) -replace "MISSING=", ""
            $b57 = ($out | Where-Object { $_ -like "BETA57=*" }) -replace "BETA57=", ""
            $fx2 = ($out | Where-Object { $_ -like "FLUX2=*" }) -replace "FLUX2=", ""
            if ([string]::IsNullOrWhiteSpace($missLine)) { Ok "插件需要的 12 个节点全部就位" }
            else { Bad ("还缺这些节点：" + $missLine + "  —— 请把这段日志发出来") }
            if ($b57 -eq "yes") { Ok "beta57 采样器可用" } else { Warn "没有 beta57 采样器（缺 RES4LYF）—— 插件会自动改用 beta 采样器，能跑但效果略有差别" }
            if ($fx2 -eq "yes") { Ok "flux2 模型类型可用" } else { Bad "ComfyUI 不支持 flux2 类型，版本太旧" }
        } else {
            Warn "没找到便携版 python，跳过节点校验"
        }
    } else {
        Warn "后端还没就绪（可能第一次加载慢）。稍后点桌面「启动 ComfyUI」再试。"
    }
} catch {
    Warn ("启动自检失败：" + $_.Exception.Message)
}

# ------------------------------------------------------------------ 收尾
Banner "安装完成"
Log ""
Log "接下来只要两步：" "Cyan"
Log "  1. 重新启动 Photoshop（插件要重启才加载）" "Cyan"
Log "  2. 在 Photoshop 菜单【增效工具 / 插件】里找到「清空环境」，点【启动 ComfyUI】后就能用了" "Cyan"
Log ""
Log "安装目录 : $InstallDir"
Log "插件目录 : " ($(if ($PSPlugins) { Join-Path $PSPlugins "cleanbg" } else { "（没找到 Photoshop，请手动复制）" }))
Log "安装日志 : $logFile"
Log ""
Log "如果哪一步失败了，把「安装日志.txt」整个发给帮你装插件的人即可。" "Yellow"
Log ""
Read-Host "按回车键关闭这个窗口"
