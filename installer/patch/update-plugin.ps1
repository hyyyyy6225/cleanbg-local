<#
================================================================================
  「清空环境」Photoshop 插件 · 更新补丁（v4）
--------------------------------------------------------------------------------
  这个补丁做三件事：
    1. 找到已经装好的「清空环境」插件文件夹（Photoshop 的 Plug-ins 下面）
    2. 用新版插件文件覆盖它（旧文件自动备份成 *.bak，可随时回滚）
    3. 顺手把"后端目录"写进插件（写不进去也没关系 —— 新版插件运行时会自己找）

  用法：双击同目录的「①双击更新插件.bat」，跑完重启 Photoshop。
================================================================================
#>
[CmdletBinding()]
param([string]$PSPlugins)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $here) { $here = (Get-Location).Path }
try { $here = (Resolve-Path $here).Path } catch {}
$logFile = Join-Path $here "更新日志.txt"

function Log {
    param([string]$m, [string]$color = "Gray")
    Write-Host $m -ForegroundColor $color
    try { Add-Content -Path $logFile -Value ("[" + (Get-Date).ToString("HH:mm:ss") + "] " + $m) -Encoding UTF8 } catch {}
}
function Ok   { param([string]$m) Log ("  [OK]   " + $m) "Green" }
function Warn { param([string]$m) Log ("  [注意] " + $m) "Yellow" }
function Bad  { param([string]$m) Log ("  [失败] " + $m) "Red" }

Log ("清空环境插件更新补丁 · " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
Log ("补丁位置: " + $here)

# ---------------------------------------------------------------- 管理员权限
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Log ""
    Log "  需要管理员权限（要往 Photoshop 目录里写文件）。" "Yellow"
    Log "  马上会弹出「用户帐户控制」窗口，请点【是】。" "Yellow"
    try {
        $psArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Verb RunAs | Out-Null
        Log "  已在新的管理员窗口里继续，这个窗口可以关掉了。" "Green"
    } catch {
        Bad ("提权失败：" + $_.Exception.Message)
        Log "  请右键「①双击更新插件.bat」→ 以管理员身份运行。" "Yellow"
    }
    Read-Host "`n按回车键退出"
    exit
}
Ok "已获得管理员权限"

# ---------------------------------------------------------------- 检查补丁自身
$newSrc = Join-Path $here "插件本体\cleanbg"
if (-not (Test-Path (Join-Path $newSrc "main.js"))) {
    Bad ("补丁里的插件文件缺失：" + $newSrc)
    Log "  请确认压缩包解压完整（不是直接在压缩包里双击）。" "Yellow"
    Read-Host "`n按回车键退出"
    exit
}
$newMain = Join-Path $newSrc "main.js"
$newText = [System.IO.File]::ReadAllText($newMain, [System.Text.Encoding]::UTF8)
if ($newText -notmatch 'COMFY_DIR_DEFAULT') {
    Bad "补丁里的 main.js 不对劲（不是 v4 版本），已停止，什么都没改。"
    Read-Host "`n按回车键退出"
    exit
}
Ok "补丁里的插件文件就位（v4 版本）"

# ---------------------------------------------------------------- 找 Photoshop
$cands = @()
foreach ($base in @("C:\Program Files\Adobe", "C:\Program Files (x86)\Adobe", "D:\Program Files\Adobe", "D:\Adobe", "E:\Adobe", "F:\Adobe")) {
    if (Test-Path $base) {
        $cands += Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "Adobe Photoshop*" } |
                  ForEach-Object { Join-Path $_.FullName "Plug-ins" } |
                  Where-Object { Test-Path $_ }
    }
}
if ($PSPlugins -and (Test-Path $PSPlugins)) { $cands = @($PSPlugins) + $cands }
$cands = $cands | Select-Object -Unique
if ($cands.Count -eq 0) {
    Bad "没找到 Photoshop 的 Plug-ins 目录"
    Log "  请确认 Photoshop 装在 C 盘或 D 盘的 Adobe 目录下；也可以手动把" "Yellow"
    Log ("  " + $newSrc + " 整个文件夹复制到 Photoshop 的 Plug-ins 里。") "Yellow"
    Read-Host "`n按回车键退出"
    exit
}
foreach ($c in $cands) { Log ("  发现插件目录：" + $c) }

# 已经装好的 cleanbg（Plug-ins 下面 3 层以内，名字叫 cleanbg 且里面有 main.js）
$targets = @()
foreach ($pl in $cands) {
    $targets += Get-ChildItem -LiteralPath $pl -Recurse -Depth 3 -Directory -Filter "cleanbg" -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "main.js") }
}
$targets = @($targets | Sort-Object -Property FullName -Unique)

$fresh = $false
if ($targets.Count -eq 0) {
    Warn "这电脑上没找到已经装好的插件，改成新装一份。"
    $targets = @(Get-Item (Join-Path $cands[0] "cleanbg") -ErrorAction SilentlyContinue)
    if (-not $targets -or -not $targets[0]) {
        $dst = Join-Path $cands[0] "cleanbg"
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        $targets = @(Get-Item $dst)
    }
    $fresh = $true
}

# ---------------------------------------------------------------- 覆盖文件
$copied = 0
foreach ($t in $targets) {
    $dir = $t.FullName
    Log ""
    Log ("处理：" + $dir) "Cyan"
    foreach ($f in @("main.js", "index.html", "manifest.json")) {
        $src = Join-Path $newSrc $f
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $dir $f
        if ((Test-Path $dst) -and (-not $fresh)) {
            $bak = $dst + ".bak"
            if (-not (Test-Path $bak)) {
                Copy-Item -LiteralPath $dst -Destination $bak -Force -ErrorAction SilentlyContinue
            }
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
        if (Test-Path $dst) {
            $a = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
            $b = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash
            if ($a -eq $b) { Ok ($f + " 已更新（哈希一致）"); $copied++ }
            else { Bad ($f + " 复制后哈希不一致") }
        } else {
            Bad ($f + " 没写进去")
        }
    }
    $iconsSrc = Join-Path $newSrc "icons"
    if (Test-Path $iconsSrc) {
        Copy-Item -LiteralPath $iconsSrc -Destination (Join-Path $dir "icons") -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $dir "icons\icon.png")) { Ok "icons 已更新" } else { Warn "icons 没更新（不影响使用）" }
    }
}

# ---------------------------------------------------------------- 找后端目录并写进插件
function Find-Backend {
    $names = @("清空环境-便携版", "清空环境", "ComfyUI", "ComfyUI-aki-v2")
    $hints = @("browser", "download", "desktop", "soft", "tool", "program",
               "下载", "桌面", "软件", "程序", "应用", "工具",
               "ai", "comfy", "cleanbg", "清空", "便携")
    $drives = @()
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -and (Test-Path $d.Root)) { $drives += $d.Root }
    }
    foreach ($root in $drives) {
        foreach ($n in $names) {
            $p1 = Join-Path $root $n
            if (Test-Path (Join-Path $p1 "start_comfy.bat")) { return $p1 }
            $p2 = Join-Path $p1 $n
            if (Test-Path (Join-Path $p2 "start_comfy.bat")) { return $p2 }
        }
        foreach ($l1 in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if (Test-Path (Join-Path $l1.FullName "start_comfy.bat")) { return $l1.FullName }
            $ln = $l1.Name.ToLower()
            $hit = $false
            foreach ($h in $hints) { if ($ln.Contains($h)) { $hit = $true; break } }
            if (-not $hit) { continue }
            foreach ($l2 in (Get-ChildItem -LiteralPath $l1.FullName -Directory -ErrorAction SilentlyContinue)) {
                if (Test-Path (Join-Path $l2.FullName "start_comfy.bat")) { return $l2.FullName }
                foreach ($l3 in (Get-ChildItem -LiteralPath $l2.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if (Test-Path (Join-Path $l3.FullName "start_comfy.bat")) { return $l3.FullName }
                }
            }
        }
    }
    return ""
}

Log ""
Log "找一下 ComfyUI 后端在哪（找不到也没关系）…"
$backend = Find-Backend
if ($backend) {
    Ok ("找到后端目录：" + $backend)
    $fwd = ($backend -replace '\\', '/')
    foreach ($t in $targets) {
        $mainJs = Join-Path $t.FullName "main.js"
        try {
            $raw = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8)
            $new = [regex]::Replace($raw, 'const COMFY_DIR_DEFAULT\s*=\s*"[^"]*"\s*;', 'const COMFY_DIR_DEFAULT = "' + $fwd + '";')
            if ($new -ne $raw) {
                [System.IO.File]::WriteAllText($mainJs, $new, (New-Object System.Text.UTF8Encoding($false)))
            }
            # 读回校验：真的从磁盘读回来才算数
            $back = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8)
            if ($back -match [regex]::Escape($fwd)) { Ok ("后端目录已写入插件：" + $fwd) }
            else { Warn "后端目录没能写进默认值（插件运行时也会自己找，不影响使用）" }
        } catch {
            Warn ("写后端目录时出错：" + $_.Exception.Message + "（不影响使用）")
        }
    }
} else {
    Warn "没找到后端目录 —— 插件运行时也会自己找；也可以在插件面板里点【自动查找】。"
}

# ---------------------------------------------------------------- 自检
Log ""
Log "自检："
foreach ($t in $targets) {
    $mainJs = Join-Path $t.FullName "main.js"
    $txt = ""
    try { $txt = [System.IO.File]::ReadAllText($mainJs, [System.Text.Encoding]::UTF8) } catch {}
    $hasDir = ($txt -match 'COMFY_DIR_DEFAULT')
    $hasFind = ($txt -match 'detectComfyDir')
    $old = ([regex]::Matches($txt, 'F:/ComfyUI-aki-v2')).Count
    $old2 = ([regex]::Matches($txt, 'F:\\\\ComfyUI-aki-v2')).Count
    if ($hasDir -and $hasFind) { Ok ("新版本已生效（自动查找功能在）：" + $mainJs) }
    else { Bad ("文件好像没更新成功：" + $mainJs) }
    if (($old + $old2) -eq 0) { Ok "没有写死的 F: 路径了" }
    else { Warn ("还残留 " + ($old + $old2) + " 处写死的 F: 路径 —— 请把日志发出来") }
}

Log ""
if ($copied -gt 0) {
    Log "更新完成。接下来：" "Cyan"
    Log "  1. **完全退出 Photoshop 再重新打开**（插件必须重启才生效）" "Cyan"
    Log "  2. 打开【增效工具】→【清空环境】面板" "Cyan"
    Log "  3. 面板底部会显示【后端目录】：显示绿色就是找对了；" "Cyan"
    Log "     显示红字就点一下【自动查找】，还不行就手动填路径再点【应用】" "Cyan"
    Log "  4. 点【启动 ComfyUI】，状态变成「已就绪」就能用了" "Cyan"
    Log ""
    Log ("更新日志（出问题发给对方）：" + $logFile)
} else {
    Bad "一个文件都没更新成功，请把这份日志发给对方。"
}
Log ""
Read-Host "按回车键关闭这个窗口"
