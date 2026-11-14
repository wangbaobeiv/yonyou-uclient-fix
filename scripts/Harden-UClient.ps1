<#
.SYNOPSIS
    用友 UClient (NC65 / NC63 / NCC / YonBIP) 白屏、假死与日志爆盘无侵入加固脚本
.DESCRIPTION
    自动探测物理机/虚拟机环境，智能寻址 UClient 安装目录，检查磁盘与运行进程，
    执行双重备份后保持原文件 UTF-8 BOM 编码特性，幂等注入 4 项 JVM 防御参数并核验 embed 模式。
.PARAMETER UClientRoot
    可选，手工指定 UClient 根目录（包含 apps 子目录的路径）。留空则自动探测。
.PARAMETER DryRun
    可选，只读预览模式，仅展示探测结果与拟变更对比，不修改任何文件。
#>
[CmdletBinding()]
param(
    [string]$UClientRoot = "",
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Resolve-UClientRootPath {
    param([string]$CustomRoot)

    if (-not [string]::IsNullOrWhiteSpace($CustomRoot)) {
        if (Test-Path (Join-Path $CustomRoot 'apps')) {
            return (Resolve-Path $CustomRoot).Path
        }
        throw "指定的 UClientRoot 不存在 apps 子目录: $CustomRoot"
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'UClient'))
    }

    try {
        $wsh = New-Object -ComObject WScript.Shell
        $desktopPaths = @(
            [Environment]::GetFolderPath('Desktop'),
            [Environment]::GetFolderPath('CommonDesktopDirectory')
        ) | Where-Object { $_ -and (Test-Path $_) }

        foreach ($desk in $desktopPaths) {
            Get-ChildItem -Path $desk -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $target = $wsh.CreateShortcut($_.FullName).TargetPath
                    if ($target -and ($target -match '(?i)UClient\.exe$')) {
                        $candidates.Add((Split-Path $target -Parent))
                    }
                } catch {}
            }
        }
    } catch {}

    foreach ($fallback in @('C:\UClient', 'D:\UClient', 'E:\UClient', 'C:\Program Files\UClient', 'C:\Program Files (x86)\UClient')) {
        $candidates.Add($fallback)
    }

    foreach ($dir in ($candidates | Select-Object -Unique)) {
        if ($dir -and (Test-Path (Join-Path $dir 'apps'))) {
            return (Resolve-Path $dir).Path
        }
    }
    return $null
}

function Get-RunningUClientProcesses {
    $procs = New-Object System.Collections.Generic.List[object]
    Get-Process -Name 'UClient', 'Uclient' -ErrorAction SilentlyContinue | ForEach-Object {
        $procs.Add([PSCustomObject]@{ Id = $_.Id; Name = $_.ProcessName; Detail = $_.Path })
    }
    Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match '(?i)UClient|nc\.starter|NCCloudLogin' } |
        ForEach-Object {
            $procs.Add([PSCustomObject]@{ Id = $_.ProcessId; Name = $_.Name; Detail = $_.CommandLine })
        }
    return $procs
}

function Update-JvmString {
    param(
        [string]$OriginalJvm,
        [string[]]$TargetArgs
    )

    $current = if ($null -eq $OriginalJvm) { '' } else { $OriginalJvm.Trim() }
    foreach ($arg in $TargetArgs) {
        $key = $arg.Split('=')[0]
        $escapedKey = [regex]::Escape($key)
        if ($current -match "(?i)(?:^|\s)$escapedKey=[^\s`"]*") {
            $current = [regex]::Replace($current, "(?i)$escapedKey=[^\s`"]*", $arg)
        } else {
            if ([string]::IsNullOrWhiteSpace($current)) {
                $current = $arg
            } else {
                $current = "$current $arg"
            }
        }
    }
    return $current.Trim()
}

function Test-HasUtf8Bom {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' 用友 UClient (NC65 / NCC / YonBIP) 白屏与爆盘无侵入加固工具' -ForegroundColor Cyan
if ($DryRun) {
    Write-Host ' [当前模式: DryRun 只读预览，不会修改任何文件]' -ForegroundColor Yellow
}
Write-Host '============================================================' -ForegroundColor Cyan

# 1. 自动环境探测
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$sessionName = [string]$env:SESSIONNAME
$gpuText = ($gpus -join ' | ')
$isVirtualGpu = ($gpuText -match '(?i)VirtIO|QXL|VMware|Hyper-V|Remote Display|Oray|ToDesk|VNC|Basic Display')
$isVirtualModel = ($cs.Model -match '(?i)Virtual|VMware|QEMU|KVM|Hyper-V|Xen|Bochs')
$isRdpSession = ($sessionName -match '(?i)^RDP-')
$isVmOrRemote = ($isVirtualGpu -or $isVirtualModel -or $isRdpSession)

$envLabel = if ($isVmOrRemote) { '远程虚拟机 / RDP / 虚拟显示环境' } else { '实体物理机环境' }
Write-Host "[1/6] 环境探测: $envLabel"
Write-Host "      当前会话: $sessionName | 显卡列表: $gpuText"

# 2. UClient 根目录寻址
$rootDir = Resolve-UClientRootPath -CustomRoot $UClientRoot
if (-not $rootDir) {
    Write-Error '未能自动定位 UClient 根目录（含 apps 文件夹），请通过 -UClientRoot "你的路径" 参数显式指定。'
    exit 1
}
$appsDir = Join-Path $rootDir 'apps'
$logDir = Join-Path $rootDir 'log'
Write-Host "[2/6] 已定位 UClient 根目录: $rootDir"

# 3. 磁盘可用空间与日志爆盘检查（严禁静默删除）
$driveLetters = @($env:SystemDrive.TrimEnd(':'), (Split-Path $rootDir -Qualifier).TrimEnd(':')) | Select-Object -Unique
foreach ($dl in $driveLetters) {
    $drv = Get-PSDrive -Name $dl -ErrorAction SilentlyContinue
    if ($drv) {
        $freeGB = [math]::Round($drv.Free / 1GB, 2)
        Write-Host ("[3/6] 磁盘 {0}: 可用空间: {1} GB" -f $dl, $freeGB)
        if ($freeGB -lt 2) {
            Write-Warning ("磁盘 {0}: 可用空间仅 {1} GB（低于 2 GB 安全阈值），建议先释放空间后再修改配置！" -f $dl, $freeGB)
        }
    }
}
if (Test-Path $logDir) {
    $logFiles = @(Get-ChildItem -Path $logDir -Recurse -File -ErrorAction SilentlyContinue)
    $logSumBytes = ($logFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $logSumBytes) { $logSumBytes = 0 }
    $logMB = [math]::Round($logSumBytes / 1MB, 2)
    Write-Host "      日志目录占用: $logMB MB (路径: $logDir)"
    if ($logMB -ge 500) {
        Write-Warning "检测到日志目录体积较大 ($logMB MB)，请人工检查后按需清理以下大文件（脚本绝不擅自删除）："
        $logFiles | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object {
            Write-Host ("        - {0} ({1} MB)" -f $_.FullName, [math]::Round($_.Length / 1MB, 2)) -ForegroundColor Yellow
        }
    }
}

# 4. 运行进程安全检查（严禁强杀）
$runningProcs = @(Get-RunningUClientProcesses)
if ($runningProcs.Count -gt 0) {
    Write-Warning '检测到以下用友 UClient 相关进程正在运行：'
    $runningProcs | Format-Table -AutoSize
    if (-not $DryRun) {
        Write-Host '【安全中止】为防止财务未保存凭证/单据丢失，请先手动关闭全部 UClient 客户端窗口，再重新运行本脚本！' -ForegroundColor Red
        exit 2
    } else {
        Write-Host '      (当前为 DryRun 预览模式，继续扫描配置；正式执行前请务必关闭上述进程)' -ForegroundColor Yellow
    }
} else {
    Write-Host '[4/6] 运行进程检查: 无运行中的 UClient 或关联 javaw 进程'
}

# 5. 扫描 Java 业务应用并执行双重备份 + 幂等注入
$defenseArgs = @(
    '-Dsun.java2d.d3d=false',
    '-Dsun.java2d.noddraw=true',
    '-Dredirect=N',
    '-Dawt.useSystemAAFontSettings=lcd'
)

$centralBackupDir = Join-Path $rootDir "_backup_$timestamp"
$results = New-Object System.Collections.Generic.List[object]

$appDirs = @(Get-ChildItem -Path $appsDir -Directory -ErrorAction SilentlyContinue | Where-Object {
    (Test-Path (Join-Path $_.FullName 'client.esc')) -and (Test-Path (Join-Path $_.FullName 'app.esc'))
})

if ($appDirs.Count -eq 0) {
    Write-Warning "在 $appsDir 下未找到同时包含 client.esc 与 app.esc 的应用目录。"
    exit 0
}

Write-Host "[5/6] 正在扫描并处理应用配置（自动跳过非 Java 微浏览器组件）..."

foreach ($dir in $appDirs) {
    $clientEsc = Join-Path $dir.FullName 'client.esc'
    $appEsc = Join-Path $dir.FullName 'app.esc'

    try {
        [xml]$clientXml = Get-Content -Path $clientEsc -Encoding UTF8
    } catch {
        Write-Warning "跳过无法解析的 XML: $clientEsc ($($_.Exception.Message))"
        continue
    }

    if ($null -eq $clientXml.app -or $null -eq $clientXml.app.start -or $null -eq $clientXml.app.start.profile -or $null -eq $clientXml.app.start.profile.java) {
        $results.Add([PSCustomObject]@{
            '业务系统' = if ($clientXml.app.name.'#text') { $clientXml.app.name.'#text' } else { $dir.Name }
            '目录ID'   = $dir.Name
            '类型'     = '非Java组件(已跳过)'
            'openMode' = '-'
            '状态'     = '跳过（如 ubrowser）'
        })
        continue
    }

    $appName = if ($clientXml.app.name.'#text') { [string]$clientXml.app.name.'#text' } else { [string]$clientXml.app.name }
    if ([string]::IsNullOrWhiteSpace($appName)) { $appName = $dir.Name }

    $openMode = [string]$clientXml.app.openMode
    $modeNeedsFix = ($openMode -ne 'embed')

    $clientHasBom = Test-HasUtf8Bom -FilePath $clientEsc
    $appHasBom = Test-HasUtf8Bom -FilePath $appEsc

    $clientOrigContent = [System.IO.File]::ReadAllText($clientEsc, [System.Text.Encoding]::UTF8)
    $appOrigContent = [System.IO.File]::ReadAllText($appEsc, [System.Text.Encoding]::UTF8)

    $clientNewContent = [regex]::Replace($clientOrigContent, '(?<=jvm=")([^"]*)(?=")', { param($m) Update-JvmString -OriginalJvm $m.Value -TargetArgs $defenseArgs })
    if ($modeNeedsFix) {
        $clientNewContent = [regex]::Replace($clientNewContent, '(?<=<openMode>)([^<]*)(?=</openMode>)', 'embed')
    }
    $appNewContent = [regex]::Replace($appOrigContent, '(?<=jvm=")([^"]*)(?=")', { param($m) Update-JvmString -OriginalJvm $m.Value -TargetArgs $defenseArgs })

    if ($DryRun) {
        Write-Host ("  -> 预览 [{0}] ({1}) | client.esc BOM={2}, app.esc BOM={3}" -f $appName, $dir.Name, $clientHasBom, $appHasBom) -ForegroundColor Gray
        $results.Add([PSCustomObject]@{
            '业务系统' = $appName
            '目录ID'   = $dir.Name
            '类型'     = 'Java/Swing 客户端'
            'openMode' = if ($modeNeedsFix) { "待纠正 ($openMode -> embed)" } else { '正常 (embed)' }
            '状态'     = 'DryRun 预览待注入4项'
        })
        continue
    }

    # 双重备份：集中目录 + 同级目录
    $backupSubDir = Join-Path $centralBackupDir $dir.Name
    New-Item -ItemType Directory -Path $backupSubDir -Force | Out-Null
    Copy-Item -Path $clientEsc -Destination (Join-Path $backupSubDir 'client.esc') -Force
    Copy-Item -Path $appEsc -Destination (Join-Path $backupSubDir 'app.esc') -Force
    Copy-Item -Path $clientEsc -Destination (Join-Path $dir.FullName "client.esc.bak_$timestamp") -Force
    Copy-Item -Path $appEsc -Destination (Join-Path $dir.FullName "app.esc.bak_$timestamp") -Force

    # 严格按原文件 BOM 写回
    [System.IO.File]::WriteAllText($clientEsc, $clientNewContent, [System.Text.UTF8Encoding]::new($clientHasBom))
    [System.IO.File]::WriteAllText($appEsc, $appNewContent, [System.Text.UTF8Encoding]::new($appHasBom))

    # 6. XML 语法与参数完整性二次校验
    [xml]$verifyClient = Get-Content -Path $clientEsc -Encoding UTF8
    [xml]$verifyApp = Get-Content -Path $appEsc -Encoding UTF8

    $clientJvmVerify = [string]$verifyClient.app.start.profile.java.args.jvm
    $appJvmVerify = [string]$verifyApp.app.start.profile.java.args.jvm
    $allPresent = $true
    foreach ($reqArg in $defenseArgs) {
        if (($clientJvmVerify -notlike "*$reqArg*") -or ($appJvmVerify -notlike "*$reqArg*")) {
            $allPresent = $false
        }
    }

    $results.Add([PSCustomObject]@{
        '业务系统' = $appName
        '目录ID'   = $dir.Name
        '类型'     = 'Java/Swing 客户端'
        'openMode' = if ($modeNeedsFix) { '已纠正为 embed' } else { '正常 (embed)' }
        '状态'     = if ($allPresent) { '已注入4项并校验通过' } else { '警告: 部分节点未匹配jvm属性' }
    })
}

Write-Host '[6/6] 执行结果汇总:' -ForegroundColor Green
$results | Format-Table -AutoSize

if (-not $DryRun) {
    Write-Host "集中归档备份路径: $centralBackupDir" -ForegroundColor Cyan
    Write-Host "如需回滚还原，请运行: .\Rollback-UClient.ps1 -UClientRoot `"$rootDir`"" -ForegroundColor Cyan
}

if ($isVmOrRemote) {
    Write-Host ''
    Write-Host '【远程桌面/虚拟机运维提示】' -ForegroundColor Yellow
    Write-Host '若需长期挂机运行批量任务，断开 RDP 前建议用管理员命令切换至控制台会话防止桌面冻结：' -ForegroundColor Yellow
    Write-Host '    tscon %sessionname% /dest:console' -ForegroundColor White
}
