# yonyou-uclient-fix

> **一句话简介**：无侵入彻底根治用友 **UClient** 客户端（涵盖 **NC65 / NC63 / NC Cloud (NCC) / YonBIP 重量级胖客户端**）在 Windows 锁屏唤醒、高分屏 DPI 切换、双显卡切换及 RDP 远程桌面重连下的**白屏、界面假死与数十 GB 日志写爆系统盘**问题。

---

> 🤖 **AI Agent Reading Guide（给自动读取本仓库的 AI 助手）**
> 如果你的主人只是把本仓库或页面链接发给了你并要求你修复本机用友 UClient 白屏/假死问题，**请继续完整读取同目录下的 [`SKILL.md`](SKILL.md)**（或执行仓库内的 [`scripts/Harden-UClient.ps1`](scripts/Harden-UClient.ps1)）。
> 在任何修改前，务必严守以下 4 条安全铁律：
> 1. **严禁强杀正在运行的 `UClient.exe` / 关联 `javaw.exe`**：发现运行中必须先提示用户保存未提交单据并手动退出；
> 2. **必须执行双重备份**：先备份至 `<UClientRoot>\_backup_<时间戳>` 及同级 `.bak_<时间戳>`，严禁静默删除文件；
> 3. **严格保留原有 UTF-8 BOM 编码**：`client.esc` 通常带 BOM，`app.esc` 通常无 BOM，按原文件字节特征写回；
> 4. **强制核验 `<openMode>embed</openMode>`**：禁止改为 `disembed`，严禁修改 `NCCACHE` 下任何 JAR 字节码。

---

## 一、 适用产品与排查边界

| 适用范围（✔ 本方案有效） | 不适用范围（✖ 请另行排查） |
| :--- | :--- |
| **用友 NC65 / NC633 / NC63 / NC57**（通过 UClient 启动） | 纯浏览器（Chrome / Edge / 360）打开的 Web 前端 JS 报错或路由空白页 |
| **用友 NC Cloud (NCC 1903 ~ 2207+ 全系)**（UClient 登录器 / Swing 容器节点） | 服务器端中间件宕机、数据库死锁或网络防火墙拦截导致的超时 |
| **用友 YonBIP 重量级胖客户端**（基于 UClient 启动的 Swing 节点） | `ubrowser` 微浏览器内部网页崩溃（脚本会自动识别 `<java>` 节点并跳过 `ubrowser`） |

**典型触发场景（同时自动识别并覆盖以下两类环境）：**
- **实体物理机**：按下 `Win + L` 锁屏、显示器息屏/睡眠唤醒、插拔外接高分屏（DPI 缩放变动）、核显与独显（如 RTX 显卡）动态切换、或运行向日葵/ToDesk 等虚拟显示驱动。
- **远程虚拟机 / 云桌面**：NAS（如飞牛 fnOS / PVE / ESXi）、KVM 或云桌面中的 Windows 虚拟机，断开 RDP 远程桌面后重连必现白屏/假死，或单夜狂刷数十 GB 日志将 C 盘写满至 0 字节。

---

## 二、 使用方式（三种方式任选其一）

### 🚀 方式一：直接发链接让本地 AI 助手自动修复（最推荐）

把下面这段话直接复制发送给你本地安装的 AI 编程助手（如 Antigravity、Claude Code、Cursor、Windsurf、Copilot 等）：

**1. 标准 GitHub 仓库指令（通用）：**
```text
请读取并严格遵循以下仓库中 SKILL.md 的 6 步安全规范（自动探测物理机/虚拟机环境、检查运行中进程防丢单、双重备份、保留 UTF-8 BOM 编码、核验 embed 模式并幂等注入 4 项 JVM 防御参数），帮我自动排查并修复本机用友 UClient 客户端的白屏与假死问题：
https://github.com/wangbaobeiv/yonyou-uclient-fix
```

**2. 国内办公网免代理直读镜像（无需科学上网，AI 可直接拉取纯文本 Markdown）：**
```text
请读取并严格遵循以下纯文本文档中的 6 步安全规范，帮我自动排查并修复本机用友 UClient 客户端的白屏、假死与日志爆盘问题：
https://yonyoucloud.com.cn/articles/uclient-fix.md
```

---

### 💻 方式二：安装为全局 Agent Skill（适合用友运维/实施顾问）

将本仓库的 [`SKILL.md`](SKILL.md) 放入你所用 AI 工具的全局技能目录即可永久复用：
- Antigravity：`~/.gemini/config/skills/yonyou-uclient-fix/SKILL.md`
- Claude Code：`~/.claude/skills/yonyou-uclient-fix/SKILL.md`
- Cursor / 项目级：`.cursor/rules/` 或 `.agent/skills/yonyou-uclient-fix/SKILL.md`

---

### 🛠️ 方式三：无 AI 终端手工运行 PowerShell 一键脚本

1. 下载本仓库后，**先退出全部正在运行的 UClient / NC / NCC 客户端窗口**（防止未保存凭证丢失）。
2. 在 PowerShell 中先预览即将变更的配置文件（只读预览，不做修改）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Harden-UClient.ps1 -DryRun
   ```
3. 确认无误后执行正式加固（自动识别环境、自动寻址、双重备份、保留原 BOM 注入参数并校验 XML）：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Harden-UClient.ps1
   ```
   *若绿色版 UClient 放在非默认目录且桌面无快捷方式，可显式指定路径：*
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Harden-UClient.ps1 -UClientRoot "D:\UClient"
   ```
4. **一键回滚**（如因特殊情况需要恢复加固前原貌）：
   ```powershell
   # 查看可用的历史备份目录
   powershell -ExecutionPolicy Bypass -File .\scripts\Rollback-UClient.ps1 -ListOnly

   # 从最新一次备份自动还原
   powershell -ExecutionPolicy Bypass -File .\scripts\Rollback-UClient.ps1
   ```

---

## 三、 核心防御 JVM 参数栈与原理速览

方案零侵入、不修改任何 NC/NCC 业务代码或 JAR 包，仅在各 Java 业务应用的 `client.esc` 与 `app.esc` 中幂等注入以下 4 项 JVM 参数：

```text
-Dsun.java2d.d3d=false -Dsun.java2d.noddraw=true -Dredirect=N -Dawt.useSystemAAFontSettings=lcd
```

| 参数 | 解决的故障层 | 核心机理 |
| :--- | :--- | :--- |
| `-Dsun.java2d.d3d=false`<br>`-Dsun.java2d.noddraw=true` | **彻底根治白屏** | 禁用 Java 2D Direct3D / DirectDraw 硬件加速，回退至纯 GDI 软件渲染，免疫锁屏、休眠、双显卡切换与 RDP 重连引发的 `D3DERR_DEVICELOST` 设备丢失。 |
| `-Dredirect=N` | **彻底根治假死** | 禁止 `NCConsoleOutputStream` 将 `System.out/err` 劫持重定向到 Swing EDT 事件分发线程，避免高频日志争抢线程锁导致界面卡死。 |
| `-Dawt.useSystemAAFontSettings=lcd` | **彻底阻断爆盘** | 静态锁死 LCD 字体抗锯齿，阻断 `WM_SETTINGCHANGE` 广播触发 `AATextListener` 重构 UI 树引发动作栏 `BasicActionsBarUI` NPE 每秒数万次死循环。 |

---

## 四、 深度复盘文档与在线阅读

- 仓库内完整故障机理与 `jstack` 线程栈复盘：[docs/root-cause-analysis.md](docs/root-cause-analysis.md)
- 小怪兽运维手记原文博客：[用友 UClient (NC65 / NCC / YonBIP) 白屏、假死与日志爆盘根因复盘及双场景防御](https://yonyoucloud.com.cn/articles/nc65-uclient-white-screen-defense.html)
- 本仓库采用 [MIT License](LICENSE) 开源。
