---
name: yonyou-uclient-fix
description: 诊断并无侵入根治用友 UClient 客户端（涵盖 NC65、NC63、NC Cloud / NCC、YonBIP 重量级端）在 Windows 锁屏唤醒、高分屏 DPI 切换、双显卡切换及 RDP 远程桌面重连下的白屏、界面假死与数十 GB 日志爆盘故障。
---

# 用友 UClient 客户端白屏、假死与日志爆盘无侵入修复技能 (yonyou-uclient-fix)

> **适用范围**：所有基于 **用友 UClient** 容器运行的 Java/Swing 客户端节点，包括但不限于 **NC65、NC633/NC63/NC57、NC Cloud (NCC 全系) 以及 YonBIP 重量级胖客户端**。
> **边界说明**：本方案专门根治 **UClient Java/Swing 客户端容器白屏与假死**，且脚本会自动过滤仅处理包含 `<java>` 节点的业务应用（自动跳过 `ubrowser` 微浏览器组件）；若故障发生在纯外部浏览器（Chrome/Edge）打开的前端网页报错或网络超时白屏，请按网页前端问题排查，勿套用本方案。

---

## 一、 核心根因（三重连锁缺陷）与无侵入防御参数

1. **第一层 · Direct3D 设备丢失（白屏）**：Windows 锁屏（`Win+L`）、息屏休眠、插拔高分屏（DPI 切换）、核显/独显切换或 RDP 远程桌面断开重连时，系统显示驱动（WDDM / 虚拟显卡）会重置 Direct3D 上下文并触发 `D3DERR_DEVICELOST`，Java 2D 无法恢复硬件 Surface 缓冲区，导致 Swing 画布呈现不可逆纯白屏。
2. **第二层 · 控制台流劫持阻塞 EDT（假死）**：用友客户端内置 `NCConsoleOutputStream` 将 `System.out`/`System.err` 重定向到 Swing 事件调度线程（EDT）文档模型；底层异常刷屏时 EDT 发生锁竞争停滞，界面彻底失去响应。
3. **第三层 · 字体广播触发动作栏 NPE 死循环（日志爆盘）**：RDP 重连或 DPI 变动触发 Windows 全局 `WM_SETTINGCHANGE` 广播，`MetalLookAndFeel$AATextListener` 调用 `SwingUtilities.updateComponentTreeUI()` 强制重构 UI 树时，动作栏 `BasicActionsBarUI$ActionsBarLayoutManager.computerBtnsHeight` 未对父容器判空而抛出 `NullPointerException`，进而陷入每秒数万次重绘抛错死循环，单夜即可写爆数十 GB 系统盘。

### 唯一无侵入全局防御 JVM 参数栈
```text
-Dsun.java2d.d3d=false -Dsun.java2d.noddraw=true -Dredirect=N -Dawt.useSystemAAFontSettings=lcd
```

| 参数项 | 防御机理 |
| :--- | :--- |
| `-Dsun.java2d.d3d=false`<br>`-Dsun.java2d.noddraw=true` | 强制关闭 Direct3D 与 DirectDraw 硬件加速，回退至纯 GDI 软件渲染；对锁屏、睡眠、双显卡及虚拟显示驱动天然免疫，彻底根治白屏。 |
| `-Dredirect=N` | 切断客户端对标准控制台输出的重定向劫持，避免异常日志涌入 Swing EDT 线程造成死锁假死。 |
| `-Dawt.useSystemAAFontSettings=lcd` | 静态锁死 LCD 字体抗锯齿模式，屏蔽系统桌面字体提示广播引发的 UI 树重构，彻底阻断动作栏 NPE 递归死循环与日志爆盘。 |

---

## 二、 AI 自动化执行铁律（6 步标准 SOP，融合实体机与远程虚拟机）

当用户要求修复本机用友 UClient 客户端白屏、假死或日志爆盘时，AI 助手必须**严格按顺序执行以下 6 个步骤**，严禁跳过安全检查与备份：

### 步骤 1：自动环境探测与磁盘急救检查
通过 PowerShell 探测 `Win32_ComputerSystem`、`Win32_VideoController` 及 `$env:SESSIONNAME`：
- 识别是否包含虚拟/远程显卡特征（如 `VirtIO`、`QXL`、`VMware`、`Hyper-V`、`Microsoft Remote Display`、`OrayIddDriver`、`ToDesk` 等）或当前会话为 `RDP-Tcp*`，自动判定为 **「远程虚拟机 / RDP 环境」** 或 **「实体物理机环境」**。
- 检查 C 盘与 UClient 所在磁盘可用空间，并统计 `<UClientRoot>\log` 目录占用大小：
  - 若系统盘可用空间低于 **2 GB** 或 `<UClientRoot>\log` 占用超过 **500 MB**，**立即列出超大日志文件清单向用户汇报，征得用户明确同意后再协助清理**（严禁静默删除任何文件！防止 C 盘空间为 0 导致后续写配置产生空字节损坏）。

### 步骤 2：运行进程安全检查（防丢单最高红线）
使用 `Get-CimInstance Win32_Process` 检查是否存在正在运行的 `UClient.exe`，以及命令行或可执行路径明确包含 `UClient`、`nc.starter` 或 `NCCloudLogin` 的 `javaw.exe`（切勿误杀其他无关 Java 程序）。
- **铁律**：如果检测到 UClient 或关联 `javaw.exe` 正在运行，**必须立即暂停修改操作，提示用户先保存界面中未提交的财务凭证或业务单据，并手动退出全部 UClient 客户端后再继续；严禁擅自使用 `Stop-Process` 或 `taskkill` 强杀进程！**

### 步骤 3：UClient 多路径智能寻址与应用过滤
按以下优先级自动定位 `<UClientRoot>` 根目录：
1. 默认标准路径：`%LOCALAPPDATA%\UClient`（检查其下 `apps` 子目录是否存在）；
2. 快捷方式解析：扫描当前用户桌面与公共桌面下名称或目标含 `UClient` 的 `.lnk` 快捷方式指向的目录；
3. 常见自定义绿色版目录：`C:\UClient`、`D:\UClient`、`E:\UClient`。

定位到 `<UClientRoot>\apps` 后，遍历子目录，仅处理同时存在 `client.esc` 与 `app.esc`、且 XML 解析 `client.esc` 后存在 `app.start.profile.java` 节点的 Java/Swing 应用（自动跳过 `ubrowser` 等非 Java 微浏览器组件）。

### 步骤 4：双重安全备份与 `<openMode>` 容器模式校验
修改任何文件前，必须执行**双重安全备份**：
1. **集中归档备份**：创建 `<UClientRoot>\_backup_<yyyyMMdd_HHmmss>\<应用目录ID>\`，将原 `client.esc` 与 `app.esc` 完整复制归档；
2. **同级备份**：在每个应用目录下生成 `client.esc.bak_<时间戳>` 与 `app.esc.bak_<时间戳>`。

同时检查 `client.esc` 中的 `<openMode>` 节点：
- **必须保持为 `embed`**。若发现被人为或异常改成了 `disembed`，**必须改回 `embed`**（在 RDP 虚拟环境下 `disembed` 会导致窗口句柄丢失并触发 `BasicSingleSideZoomPaneUI` 陷入黑屏递归死循环）。

### 步骤 5：幂等注入 4 项防御参数并严格保留 BOM 编码
更新 `client.esc` 与 `app.esc` 中所有 `jvm="..."` 属性：
- **幂等性**：若 `jvm` 属性中已存在某个 `-Dkey=...` 参数，原地替换为其标准目标值；缺失的规范追加到末尾，绝不重复叠加。
- **BOM 与排版保护**：写入前读取原文件前 3 字节判断是否为 UTF-8 BOM（`0xEF 0xBB 0xBF`：`client.esc` 通常为 UTF-8 with BOM，`app.esc` 通常为 UTF-8 without BOM），**必须严格按原文件的 BOM 特征写回**，保持原有 XML 缩进与节点结构完整。
- **严禁篡改 JAR**：绝对禁止反编译修改 `NCCACHE` 或 `apps` 下的任何 `.jar` 文件（`ProvisionClassLoader` 会校验哈希签名并抛出 `Client code is tampered` 致命异常拒启）。

### 步骤 6：XML 语法校验、结果汇报与运维收尾
1. 重新用 `[xml]` 解析修改后的每个 `client.esc` 与 `app.esc`，确认 XML 语法完全合法且 4 项参数均已正确写入；
2. 向用户输出清晰的结果汇总表（环境探测结论、磁盘与日志检查结果、应用名称、目录 ID、`openMode` 状态、加固状态及备份/回滚路径）；
3. 若环境探测为 **RDP 远程挂机场景**（如虚拟机后台跑批/长期挂单），补充提醒用户后续退出远程桌面时可使用管理员命令 `tscon %sessionname% /dest:console` 将会话切回控制台，避免会话被 Windows 冻结。

---

## 三、 附：无侵入幂等加固与一键回滚 PowerShell 参考实现

> 若工作区已包含完整仓库，推荐直接执行 `scripts\Harden-UClient.ps1`（支持 `-DryRun` 预览）与 `scripts\Rollback-UClient.ps1`（支持 `-ListOnly` 列出备份）。若当前环境仅能读取本单文件，可参照下方经验证的内联幂等加固脚本（保存执行时请务必使用 UTF-8 with BOM 编码）：

```powershell
[CmdletBinding()]
param(
    [string]$UClientRoot = "",
    [switch]$DryRun
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# 1. 环境自动探测
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$sessionName = $env:SESSIONNAME
$isRdpOrVm = ($sessionName -match '^RDP-') -or (($gpus -join ' ') -match 'VirtIO|QXL|VMware|Hyper-V|Remote Display|Oray|ToDesk|VNC') -or ($cs.Model -match 'Virtual|VMware|QEMU|KVM|Hyper-V')
Write-Output ("环境识别: " + $(if ($isRdpOrVm) { "远程虚拟机 / RDP / 虚拟显示环境" } else { "实体物理机环境" }))
Write-Output ("当前会话: $sessionName | 显卡: " + ($gpus -join ', '))

# 2. UClient 根目录多路径寻址
function Resolve-UClientRoot([string]$CustomRoot) {
    if ($CustomRoot -and (Test-Path (Join-Path $CustomRoot 'apps'))) { return $CustomRoot }
    $candidates = @("$env:LOCALAPPDATA\UClient", 'C:\UClient', 'D:\UClient', 'E:\UClient')
    try {
        $shell = New-Object -ComObject WScript.Shell
        @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) |
            Where-Object { $_ -and (Test-Path $_) } | ForEach-Object {
                Get-ChildItem -Path $_ -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
                    $target = $shell.CreateShortcut($_.FullName).TargetPath
                    if ($target -match 'UClient\.exe$') { $candidates += (Split-Path $target -Parent) }
                }
            }
    } catch {}
    foreach ($dir in ($candidates | Select-Object -Unique)) {
        if ($dir -and (Test-Path (Join-Path $dir 'apps'))) { return $dir }
    }
    return $null
}

$rootDir = Resolve-UClientRoot $UClientRoot
if (-not $rootDir) { Write-Error "未自动找到 UClient 目录，请通过 -UClientRoot 手动指定。"; exit 1 }
$appsDir = Join-Path $rootDir 'apps'
$logDir = Join-Path $rootDir 'log'
Write-Output "定位 UClient 根目录: $rootDir"

# 3. 磁盘与日志占用检查（仅汇报，严禁静默删除）
$sysDrive = Get-PSDrive ($env:SystemDrive.TrimEnd(':')) -ErrorAction SilentlyContinue
if ($sysDrive) {
    $freeGB = [math]::Round($sysDrive.Free / 1GB, 2)
    Write-Output "系统盘 ($($env:SystemDrive)) 可用空间: $freeGB GB"
}
if (Test-Path $logDir) {
    $logBytes = (Get-ChildItem $logDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    $logMB = [math]::Round(($logBytes / 1MB), 2)
    Write-Output "UClient 日志占用: $logMB MB (路径: $logDir)"
    if ($logMB -ge 500) { Write-Warning "日志目录占用已达 $logMB MB，请人工确认后清理超大历史日志！" }
}

# 4. 进程安全检查（禁止强杀）
$runningUClient = @(Get-Process -Name 'UClient','Uclient' -ErrorAction SilentlyContinue)
$runningJava = @(Get-CimInstance Win32_Process -Filter "Name = 'javaw.exe' OR Name = 'java.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'UClient|nc\.starter|NCCloudLogin' })
if (($runningUClient.Count -gt 0 -or $runningJava.Count -gt 0) -and (-not $DryRun)) {
    Write-Warning "检测到用友 UClient 客户端正在运行！请先保存未提交单据并手动退出客户端，再重新执行本脚本。"
    exit 2
}

# 5. 双重备份与幂等参数注入
$defenseArgs = @('-Dsun.java2d.d3d=false', '-Dsun.java2d.noddraw=true', '-Dredirect=N', '-Dawt.useSystemAAFontSettings=lcd')
function Update-JvmString([string]$origJvm) {
    $current = $origJvm.Trim()
    foreach ($arg in $defenseArgs) {
        $key = $arg.Split('=')[0]
        $pattern = '(?i)(?:^|\s)' + [regex]::Escape($key) + '=[^\s"]*'
        if ($current -match $pattern) {
            $current = [regex]::Replace($current, [regex]::Escape($key) + '=[^\s"]*', $arg)
        } else {
            $current = ($current + ' ' + $arg).Trim()
        }
    }
    return $current
}

$centralBackupDir = Join-Path $rootDir "_backup_$timestamp"
$results = @()

Get-ChildItem -Path $appsDir -Directory | Where-Object {
    (Test-Path (Join-Path $_.FullName 'client.esc')) -and (Test-Path (Join-Path $_.FullName 'app.esc'))
} | ForEach-Object {
    $clientEsc = Join-Path $_.FullName 'client.esc'
    $appEsc = Join-Path $_.FullName 'app.esc'
    try {
        [xml]$testXml = Get-Content $clientEsc -Encoding UTF8
        if ($null -eq $testXml.app.start.profile.java) { return }
        $appName = if ($testXml.app.name.'#text') { $testXml.app.name.'#text' } else { [string]$testXml.app.name }
    } catch { return }

    $openMode = [string]$testXml.app.openMode
    $modeFixed = ($openMode -ne 'embed')

    if (-not $DryRun) {
        $backupSubDir = Join-Path $centralBackupDir $_.Name
        New-Item -ItemType Directory -Path $backupSubDir -Force | Out-Null
        Copy-Item $clientEsc (Join-Path $backupSubDir 'client.esc') -Force
        Copy-Item $appEsc (Join-Path $backupSubDir 'app.esc') -Force
        Copy-Item $clientEsc (Join-Path $_.FullName "client.esc.bak_$timestamp") -Force
        Copy-Item $appEsc (Join-Path $_.FullName "app.esc.bak_$timestamp") -Force

        foreach ($file in @($clientEsc, $appEsc)) {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
            $encoding = [System.Text.UTF8Encoding]::new($hasBom)
            $content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
            $newContent = [regex]::Replace($content, '(?<=jvm=")([^"]*)(?=")', { param($m) Update-JvmString $m.Value })
            if ($modeFixed -and ($file -eq $clientEsc)) {
                $newContent = [regex]::Replace($newContent, '(?<=<openMode>)([^<]*)(?=</openMode>)', 'embed')
            }
            [System.IO.File]::WriteAllText($file, $newContent, $encoding)
            [void]([xml](Get-Content $file -Encoding UTF8))
        }
    }

    $results += [PSCustomObject]@{
        '业务系统' = $appName
        '目录ID'   = $_.Name
        'openMode' = if ($modeFixed) { if ($DryRun) { "需纠正 ($openMode -> embed)" } else { "已纠正为 embed" } } else { "正常 (embed)" }
        '状态'     = if ($DryRun) { "预览待注入4项" } else { "已注入4项并校验通过" }
    }
}

if (-not $DryRun) { Write-Output "=== 集中备份目录: $centralBackupDir ===" }
$results | Format-Table -AutoSize
```
