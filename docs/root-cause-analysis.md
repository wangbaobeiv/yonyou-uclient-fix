# 用友 UClient (NC65 / NCC / YonBIP) 白屏、假死与日志爆盘深度根因复盘

## 一、 故障现象与触发场景

在运维部署基于 **用友 UClient** 启动的 Java/Swing 企业级客户端（覆盖 **NC65、NC633/NC63、NC Cloud / NCC 全系、YonBIP 重量级胖客户端**）时，现场长期存在一类极度隐蔽的偶发/必现复合故障：

1. **实体物理机场景（笔记本 / 办公台式机）**
   - 按下 `Win + L` 锁屏或显示器息屏节能后唤醒；
   - 笔记本合盖休眠重新打开、插拔外接高分屏（DPI 缩放比变化）；
   - 双显卡笔记本在核显与独立显卡（如 NVIDIA RTX 系列）之间动态切换；
   - 本机装有向日葵（`OrayIddDriver`）或 ToDesk 等远程虚拟显示驱动。
   - **症状**：UClient 界面瞬间变为不可逆的纯白屏，点击无反应、最小化再还原依旧空白，只能强杀重启。

2. **远程虚拟机场景（RDP / KVM / 飞牛 fnOS / PVE / 云桌面）**
   - 用户通过 Windows 远程桌面（RDP）连入虚拟机运行 UClient 办公；
   - 关闭或断开 RDP 窗口，过一段时间再次重新连入。
   - **症状**：UClient 几乎 100% 出现白屏无响应或全黑屏假死，同时后台 CPU 持续空转，疯狂向 `%LOCALAPPDATA%\UClient\log` 写入错误日志——**在真实排障案例中，单夜日志膨胀达 38 GB，直接将系统 C 盘写满至 0 字节**。

---

## 二、 深层根因链条：三重缺陷连锁叠加

通过对卡死现场抓取线程栈（`jstack`）以及分析 UClient 启动参数与客户端类库，证实这并非单一 Bug，而是 **Windows 图形子系统、NC 框架控制台流与 Swing 字体监听器** 三层缺陷串联引爆的结果：

### 第一层：Direct3D 设备丢失（触发白屏初始态）
Java 2D 在 Windows 上默认启用 Direct3D / DirectDraw 硬件加速管线。当 Windows 执行锁屏、休眠、显卡切换或断开 RDP 会话时，底层显示驱动（WDDM 或虚拟机 IddCx/VirtIO-GPU 驱动）会销毁或重置当前会话的 Direct3D 上下文，导致图形流水线抛出 `D3DERR_DEVICELOST`。Swing 离屏 Surface 缓冲区失效且无法在重连后自动重建，窗体底层缓冲区彻底变成纯白底色。

### 第二层：NC 控制台流劫持阻塞 EDT（导致界面假死）
用友底层客户端容器内部实现了 `NCConsoleOutputStream`，默认在启动时将 JVM 标准输出 `System.out` 与标准错误 `System.err` 重定向到一个挂载在 **Swing 事件调度线程（EDT）** 上的日志文档模型中。
当第一层或第三层产生高频异常输出时，日志写入操作会在 EDT 线程上频繁抢占组件锁与文档模型锁，直接造成 Swing 事件泵堵死，用户鼠标点击与键盘输入完全失效（界面假死）。

### 第三层：字体提示广播触发动作栏 NPE 死循环（终极灾难：38 GB 日志爆盘）
当用户重新连入 RDP 会话，或者实体机显示器分辨率 / DPI 缩放比发生切换时，Windows 会向所有顶层窗口广播 `WM_SETTINGCHANGE` 系统消息。
JDK AWT 捕获到桌面字体平滑属性（`awt.font.desktophints`）更新后，Swing 的 `MetalLookAndFeel$AATextListener` 会触发全局回调，递归调用 `SwingUtilities.updateComponentTreeUI()` 强制刷新整棵 Swing 组件树外观。

此时用友动作栏布局管理器 `BasicActionsBarUI$ActionsBarLayoutManager.computerBtnsHeight` 存在非空保护缺失：在非预期的树重构时机访问尚未就绪或空置的父级容器时，必然抛出 `NullPointerException (NPE)`。而未捕获的布局异常又中断了当前重绘并触发下一轮 `repaint()/revalidate()`，由此形成**每秒数万次抛错的死循环**——配合高频日志刷盘，一夜之间即可耗尽数十 GB 磁盘空间。

---

## 三、 核心无侵入 JVM 防御参数栈

无需改动服务端代码，也无需冒风险反编译客户端 JAR，仅在应用配置文件 `client.esc` 与 `app.esc` 的 `<args jvm="..."/>` 属性中静态固化以下 4 个参数即可彻底斩断上述三条链路：

```text
-Dsun.java2d.d3d=false -Dsun.java2d.noddraw=true -Dredirect=N -Dawt.useSystemAAFontSettings=lcd
```

1. **`-Dsun.java2d.d3d=false` + `-Dsun.java2d.noddraw=true`**：关闭 D3D 与 DirectDraw 硬件渲染管线，回退至纯 CPU GDI 软件光栅化渲染。对于 ERP 表单与表格控件几乎零性能开销，但完全消除了设备上下文丢失风险。
2. **`-Dredirect=N`**：利用用友客户端原生开关关闭 `System.out/err` 到 Swing UI 控制台的重定向劫持，保护 EDT 事件线程永不被日志阻塞。
3. **`-Dawt.useSystemAAFontSettings=lcd`**：将字体抗锯齿模式静态锁定为 LCD，屏蔽 Windows `WM_SETTINGCHANGE` 广播带来的动态字体 Hint 重建风暴，从源头彻底阻断动作栏 NPE 死循环与爆盘。

---

## 四、 两条高频踩坑禁忌（切勿复踩）

1. **严禁将 `client.esc` 中的 `<openMode>` 改为 `disembed`**
   - 不少排查者尝试将嵌入式窗口模式 `embed` 改为独立模式 `disembed` 以绕过容器白屏。实测在 RDP 虚拟环境及部分窗口嵌套场景下，`disembed` 会导致父窗口句柄失去同步，触发用友 `BasicSingleSideZoomPaneUI` 陷入 `revalidate()` 递归黑屏死循环，现象比白屏更恶劣。
2. **严禁反编译并替换本地 `NCCACHE` 中的 `.jar` 包**
   - UClient 内置的 `ProvisionClassLoader` 在加载客户端类库时会对本地缓存的所有 JAR 包做哈希完整性校验（`.DG` 校验摘要）。手工修改字节码哪怕只改一个类，都会在启动阶段直接触发 `Client code is tampered` 致命异常并拒绝启动。

---

## 五、 工程化落地要点

- **区分应用类型**：`<UClientRoot>\apps\` 下除了 Java 业务节点（包含 `<java>` 节点），还会包含如 `ubrowser`（Chromium 内核微浏览器）等非 Java 组件，修改脚本必须解析 `client.esc` 并只对存在 `app.start.profile.java` 的目录注入参数。
- **保留 UTF-8 BOM 特征**：原始 `client.esc` 通常带有 UTF-8 BOM（`EF BB BF`），而 `app.esc` 通常无 BOM；注入重写时须按各自原始 BOM 字节头原样保存，防止 UClient C++ 启动器解析 XML 异常。
- **先查磁盘与进程再动手**：面对已经发生过爆盘的虚拟机，必须先释放 `log` 目录下撑满磁盘的大文件，避免在 0 字节可用空间下保存配置文件导致文件内容被截断清空；同时必须先确认没有未保存单据的 `UClient.exe` / 关联 `javaw.exe` 在运行。
