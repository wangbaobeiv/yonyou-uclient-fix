<#
.SYNOPSIS
    用友 UClient 配置一键回滚脚本
.DESCRIPTION
    从 <UClientRoot>\_backup_<时间戳> 集中备份目录还原 client.esc 与 app.esc，
    原样保留字节流与 BOM 编码，并校验还原后的 XML 语法合法性。
.PARAMETER UClientRoot
    可选，手工指定 UClient 根目录。留空则自动探测。
.PARAMETER BackupDir
    可选，指定要恢复的某次备份目录路径（如 D:\UClient\_backup_20261114_170000）。留空则默认选用最新一次备份。
.PARAMETER ListOnly
    可选，仅列出所有可用历史备份目录，不执行恢复。
#>
[CmdletBinding()]
param(
    [string]$UClientRoot = "",
    [string]$BackupDir = "",
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

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

$rootDir = Resolve-UClientRootPath -CustomRoot $UClientRoot
if (-not $rootDir) {
    Write-Error '未能自动定位 UClient 根目录，请通过 -UClientRoot 手动指定。'
    exit 1
}

$backups = @(Get-ChildItem -Path $rootDir -Directory -Filter '_backup_*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
if ($backups.Count -eq 0) {
    Write-Warning "在 $rootDir 下未找到任何 _backup_* 集中备份目录。"
    exit 1
}

if ($ListOnly) {
    Write-Host "在 $rootDir 下发现以下历史备份（按时间倒序）：" -ForegroundColor Cyan
    $backups | ForEach-Object {
        $appCount = @(Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue).Count
        [PSCustomObject]@{
            '备份名称' = $_.Name
            '完整路径' = $_.FullName
            '应用数'   = $appCount
        }
    } | Format-Table -AutoSize
    exit 0
}

# 运行进程检查
$runningUClient = @(Get-Process -Name 'UClient', 'Uclient' -ErrorAction SilentlyContinue)
$runningJava = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '(?i)UClient|nc\.starter|NCCloudLogin' })
if ($runningUClient.Count -gt 0 -or $runningJava.Count -gt 0) {
    Write-Host '【安全中止】检测到 UClient 或关联 javaw 进程正在运行，请先保存单据并手动退出客户端后再执行回滚！' -ForegroundColor Red
    exit 2
}

$targetBackup = if (-not [string]::IsNullOrWhiteSpace($BackupDir)) {
    if (-not (Test-Path $BackupDir)) {
        throw "指定的备份目录不存在: $BackupDir"
    }
    (Resolve-Path $BackupDir).Path
} else {
    $backups[0].FullName
}

Write-Host "正在从备份还原配置: $targetBackup" -ForegroundColor Cyan
$appsDir = Join-Path $rootDir 'apps'
$rollbackResults = New-Object System.Collections.Generic.List[object]

Get-ChildItem -Path $targetBackup -Directory | ForEach-Object {
    $appId = $_.Name
    $srcDir = $_.FullName
    $dstDir = Join-Path $appsDir $appId

    if (-not (Test-Path $dstDir)) {
        Write-Warning "目标应用目录已不存在，跳过: $dstDir"
        return
    }

    $restoredFiles = New-Object System.Collections.Generic.List[string]
    foreach ($fileName in @('client.esc', 'app.esc')) {
        $srcFile = Join-Path $srcDir $fileName
        $dstFile = Join-Path $dstDir $fileName
        if (Test-Path $srcFile) {
            [System.IO.File]::Copy($srcFile, $dstFile, $true)
            [void]([xml](Get-Content -Path $dstFile -Encoding UTF8))
            $restoredFiles.Add($fileName)
        }
    }

    $rollbackResults.Add([PSCustomObject]@{
        '目录ID'   = $appId
        '还原文件' = ($restoredFiles -join ', ')
        'XML校验'  = '通过'
    })
}

Write-Host '回滚还原完成：' -ForegroundColor Green
$rollbackResults | Format-Table -AutoSize
