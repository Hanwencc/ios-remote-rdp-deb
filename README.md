# XYHelper Remote RDP：局域网 RDP

## 当前状态

当前版本 **0.4.0~rc7**，用于个人设备试运行，不是已完成长期稳定性验收的通用发布版。

- 目标实机：iPad 第七代 / A10，iPadOS 18.7.9，palera1n rootless，Sileo。
- Windows 原生 `mstsc` 直接连接局域网地址，固定 TCP **3389**，TLS + NLA/CredSSP。
- 单客户端；1080×1440 竖屏、VideoToolbox 硬件 H.264 / RDPGFX AVC420，目标 60 FPS。
- 设置 → 通用 → XYHelper Remote RDP：服务开关、RDP 账号密码修改、连接与编码状态。
- 已按用户授权卸载设备旧 0.3.0 网页包，删除旧配置、网页资源和独立 pilot，安装新版 rootless 包。
- 两种包均已通过本地 Docker 编译和包结构校验：
  `iphoneos-arm` 为 rootful 布局，`iphoneos-arm64` 为 rootless 布局；**两者内部均为 ARM64 Mach-O，不支持 32 位 ARM**。
- rootless 已验证安装、设备独立证书生成、3389 监听、服务启停、关闭后空闲采集、
  Unicode 密码的 PBKDF2/NT hash 同步更新、NLA 认证存储刷新、开关/账号的重启保留、
  重复安装准备保留账号/证书，以及测试后的账号恢复。
  rc1 的设置页入口和服务开关已由用户确认；rc2 按实际 RDP 功能重写文案和状态显示，
  已升级实机并核对全部配置字段及设备证书未变，用户已确认 rc2 版本和新 RDP 字段正常显示。
  rc3 已升级实机，入口名称和图标、状态格式化测试通过；再次核对全部配置字段及证书未变，
  用户已确认“XYHelper Remote RDP”名称和图标正常显示。
  rc4 修复打开设置时被旧 250 ms 写入看门狗误断开的问题，升级后保留全部配置及证书；
  用户已确认通过辅助触控连续完成 10 次“桌面 → 设置 → 桌面”，没有断连。
  回归后实机 RDPGFX 和硬件编码正常，发送队列为 0，最近错误为空；不代表长期稳定性已验收。
  rc5 建立真实点击回显基线；rc6/rc7 增加输入优先、编码前背压、码流借用和帧就绪通知，
  保持分辨率、目标帧率和码率不变。rc7 已安装，配置、账号和证书保持不变；
  用户确认连续点按、拖动/滑动、小白点桌面与设置往返正常，没有断连或触控卡住。
- rc1 正式包已由用户确认画面、鼠标点按和拖动正常。历史服务端编码约 60.08 FPS，
  不代表客户端显示帧率或已测端到端延迟。
- rootful 只有编译和包结构验证，没有对应实机验证；其他设备/系统不承诺兼容。
- 不保留浏览器协议，不实现公网、隧道或中转；只接受 RFC1918/loopback IPv4 来源。

FreeRDP 固定 3.32.2 / `97eff6ddfbbfaa8e42a126d362686bd001ff8bdc`，
OpenSSL 固定 3.5.9 / `45e844fa2a14ec92d146bd8f5778ac130b6625fb`。
保留 NLA settings 身份读取、必需的 PostConnect、激活后初始化 drdynvc、
合法 ACK 暂停/恢复、有界队列与网络超时等实机排障修复，不启用认证数据转储。

### 设置菜单与状态字段

- 入口和详情页标题统一为“XYHelper Remote RDP”，安装包显示名同步更新，内部包标识及配置路径不变。
  通用入口使用原创蓝色圆角“显示器 + 鼠标指针”图标，按屏幕倍率由 UIKit 绘制，保持原色并适配浅色/深色背景。
- 开关为“启用 RDP 服务”，账号按钮为“修改 RDP 账号密码”，不再描述网页登录。
- “响应延迟测试”提供红绿色块，用于配合 Windows 自动测量点击到实际画面回显。
- 画面与鼠标共用一个 RDP 会话，显示“端口监听”“RDP 客户端”“图形通道”，
  不显示不存在的独立“视频连接”和“控制连接”。
- “连接协议”显示 `RDP / NLA / AVC420`；“软件版本”可用于核对当前后台版本。
- 采集管线区分初始化、空闲、就绪和接口不可用；硬件编码区分使用中和未启用。
  “触控接口可用”表示注入能力，不表示已有远程触控操作。
- 视频分辨率只在采集管线就绪时显示；空闲时不把上一会话的尺寸和耗时显示成当前数据。
- “编码帧率”带 `FPS` 单位，统计 VideoToolbox 输出回调，不等于客户端显示帧率。
  “采集与提交耗时”带 `ms` 单位，不含异步编码完成、网络传输和客户端呈现。
- 保留目标视频码率和最近错误；不把最近断开错误直接等同于当前监听失败。
- 升级时按精确 PID 退出真实“设置”进程，避免已加载的旧 bundle 继续显示旧文案。
  正常升级保留账号、开关和设备证书，但会短暂断开 RDP，需要重新打开设置和客户端连接。

### 安装安全约束

只能通过 `dpkg` 安装 deb，**禁止将包含 `var/jb` 父目录的 tar 解包到 `/`**。
此前一次试运行解包事故已恢复 `/var/jb` 的真实 preboot 软链接；
恢复备份 `/var/jb-rdp-deploy-backup-20261013` 继续保留。
安装/清理脚本只处理明确的 Remote iPad 路径，不删除 SSH、bootstrap 或恢复备份。

## 1. 最终目标架构

```text
Windows mstsc
    │ 局域网 TCP 3389，TLS，目标使用 NLA
    ▼
FreeRDP server peer + WinPR
    ├── 认证 / 能力协商 / 单客户端会话 / 超时
    ├── RDPGFX surface + AVC420 + FrameAck
    │       ▲
    │       │ 有界输出队列、NAL 格式适配、SPS/PPS、帧元数据
    │   VideoToolbox 硬件 H.264
    │       ▲
    │   IOSurface-backed CVPixelBuffer
    │       ▲
    │   CARenderServerRenderDisplay（首版基线）
    └── 鼠标输入 → 坐标映射 → iOS HID 触控

设置 → 通用 → XYHelper Remote RDP
    │ 本机 Unix socket，核验 UID 与 Settings 真实进程路径
    ▼
后台管理：启停、账号修改、状态与错误
```

这是共享 iPad 的真实屏幕，不是 Windows 桌面，也不是独立虚拟会话。
使用 FreeRDP 的 server peer 接口和 Shadow 实现作为参考，不从零编写 RDP 协议。
FreeRDP 服务端已在目标 rootless iPad 上编译、加载并完成实际连接；
这不是其他 iOS 系统、越狱环境或设备的兼容证明。

### 首版范围

- 一个已认证客户端；固定竖屏 1080×1440，目标 60 FPS、初始约 4 Mbps。
- AVC420 硬件 H.264，无 B 帧，实时编码；断线或无人连接时停止采集并释放编码器。
- 左键按下、拖动、释放映射一个触点；坐标按画面有效区域归一化，排除黑边。
- 断线、关闭、修改账号和编码尺寸变化时释放触点，防止残留按压。
- Home 已接入独立 Home 键的扩展扫描码，但尚未专项实机验证；系统辅助触控“小白点”
  已在远程画面显示，并用于桌面/设置往返验证。滚轮和文本键盘输入未实现。
- 不启用音频、剪贴板、磁盘、打印机重定向或多指操作。
- 不绕过设备锁屏或受保护画面。越狱失效时服务不可用，不承诺系统重启后自动恢复越狱。

## 2. 采集路径重新评估

### 当前基线并不是图片截图传输

[Engine.mm](native/Engine.mm) 已经使用：

```text
CARenderServerRenderDisplay
  → 原生尺寸 BGRA IOSurface / CVPixelBuffer pool
  → VideoToolbox 硬件 H.264
```

这台设备原生尺寸为 1620×2160，旧链路输出为 1080×1440。
此前实测约 60 FPS，render 约 8–9 ms、VT 提交调用约 1–2 ms。
这些是历史短时结果，不是 RDP 性能保证；**VT 提交时间不等于完整编码时间**。
当前像素池仍是原生尺寸，编码器输出较小，内部缩放、色彩转换的具体实现没有测实，不能称为整条链路零拷贝。
探针输出 PNG 仅用于诊断，不属于视频传输路径。

### 候选比较

| 路径 | 潜在收益 | 关键问题 | 本项目结论 |
|---|---|---|---|
| 当前 RenderDisplay → IOSurface → VT | 已在目标设备运行，无应用录屏授权流程 | 每帧 render 成本，原生 BGRA 到较小 H.264 的转换成本 | 首版可靠基线 |
| 直接显示 surface → CVPixelBuffer → VT | 如果能拿到完整、稳定的合成帧，可能减少每帧 render | 私有 ABI、权限、像素格式、平铺/压缩、同步、surface 复用、完整合成画面 | 优先做独立对照实验，不直接替换 |
| 私有系统镜像/显示流回调 | 可能按显示更新通知，避免无效采集 | 目标系统是否导出、能否在 daemon 使用、帧所有权和生命周期均未验证 | 候选，未证实可用 |
| AirPlay 屏幕镜像 | 系统已有镜像和编码能力 | 公开流程需要选择接收端；还需接收协议、连接恢复、保护内容处理与 RDP 转封装 | 不作为首版 |
| ReplayKit 广播扩展 | 系统提供 CMSampleBuffer，避免自己取画面 | 标准系统广播是用户启动流程；应用录屏与全系统广播不是同一能力 | 不符合直接采用公开 API 的无人值守要求 |
| ScreenCaptureKit | 桌面采集能力完善 | 不能把 macOS / Mac Catalyst 能力当成 iPadOS 18.7.9 daemon 的可用 API | 不作为本机路线 |
| CGImage / UIImage / JPEG 截图 | 便于调试 | 增加格式转换、复制或图片编码，不是更优连续视频管线 | 不采用 |

公开的 IOMobileFramebuffer 头文件中存在 `GetMainDisplay` 和 `GetLayerDefaultSurface`，
这是调查直接 surface 路径的依据，而不是 iPadOS 18.7.9 兼容证明。
旧项目的 CoreSurface 接口也不能直接套用到现代 IOSurface。
获取一个 layer 的默认 surface 不等于已获取当前完整合成屏幕。
不能仅靠 `IOSurfaceLock` 就假定已解决显示生产者同步或缓冲复用问题。

AirPlay 并非必然需要二次编码：如果能可靠取得兼容码流，理论上可以重封装；
但需要验证 SPS/PPS、分辨率变化、时间戳、关键帧、流控及接收端行为。
如果为了进入 RDP 先解码再用 VT 编码，反而增加延迟和资源消耗。
AirPlay 也不提供本项目的触控注入，因此不会因为采用“镜像”就自动解决控制问题。

### 推荐优化顺序

1. 先打通现有采集 → VT → AVC420 → mstsc，不同时更换所有变量。
2. 编码回调不做网络发送。保留原生 `CMSampleBufferRef`，由适配层按需提取 H.264；异步排队前 retain，消费或取消时 release。
3. 测试直接显示 surface 的实际可用性、内容正确性及同步；与当前基线使用相同分辨率、码率、客户端比较。
4. 再测试 GPU 缩放和 BGRA → NV12 后提交 VT 的成本；不能直接给要求 BGRA 的 render 接口传 NV12。
5. 只有端到端延迟、功耗或稳定性确实改善才替换基线，不以符号存在或 CPU 单项下降判定成功。

## 3. 编码与 RDPGFX

首版使用 **AVC420**，保留硬件编码要求并回读硬件状态，不静默退到软件编码。
AVC444 不是普通 VideoToolbox 参数开关，不纳入首版。

VT 输出的 H.264 不能裸发给 mstsc。适配层需要：

- 协商 RDPGFX/AVC420 能力；客户端不支持时明确报错，不偷偷启用高 CPU 的旧图形编码。
- 从 CMVideoFormatDescription 获取参数集及 NAL 长度字段，按协议要求将长度前缀码流转换成 Annex B。
- 正确处理 IDR、SPS/PPS、尺寸与裁剪信息；验证 VT 实际 profile/level 对客户端是否兼容。
- 创建和映射 GFX surface，构造合法 AVC420 region/quality 元数据及 SurfaceCommand。
- 使用 StartFrame / EndFrame / FrameAck 管理帧生命周期。
- 首帧、重连、尺寸变化和拥塞重同步从可解码关键帧开始。

**Windows 客户端负责解码和呈现，但不预先承诺所有 Windows 环境都会启用硬件解码。**
服务端统计 60 FPS、RDP FrameAck 或 TCP 成功发送都不能单独证明客户端可见画面达到 60 FPS。

### 防止再次“卡住”

- 采集和编码回调不执行网络发送；RDP 事件循环处理输入，发送采用非阻塞背压，不同步等待发送缓存排空。
- 输出队列同时限制帧数、字节数和最老帧年龄；根据 FrameAck 和队列年龄调整采集/码率。
- 优先在编码前跳过待采集帧；已经编码的参考帧不能随意丢 P 帧后继续发送其依赖帧。
- 必须丢弃过时压缩队列时，进入重同步状态，请求新 IDR；旧 epoch 的输出不再进入新会话。
- 接收慢、写超时、能力不匹配和编码失败都应明确显示错误，不能无限排队或保留冻结画面假装连接正常。
- rc4 关闭 FreeRDP 的同步发送缓存排空等待，每轮事件循环非阻塞排空缓存；
  缓存仍有积压时不提交新视频帧，保留最多 2 帧 / 4 MiB / 100 ms 的编码队列和关键帧重同步。
  只有实际发送缓存连续 2 秒未排空才断开慢连接，不再把输入处理或画面切换超过 250 ms 当作网络写入失败。
  认证/图形协商仍保留 30 秒期限；正常帧确认模式仍保留 2 秒 ACK 超时，合法暂停帧确认仍被接受。
- rc6 优先处理已缓冲输入，每批最多 32 包或 2 ms。只合并同批连续鼠标移动，
  按下、释放和键盘事件前先提交移动；暂停和会话切换清除待处理移动。
  编码中帧与编码后队列合计最多 2 帧，网络或 ACK 阻塞时在采集前跳过，
  不再持续编码后丢弃参考帧。连续 CoreMedia buffer 直接借用并转换成自有 Annex B 数据，
  非连续 buffer 明确复制；借用指针不会留给异步发送。
- rc7 在编码帧入队时通知 RDP 事件循环，不必总等 5 ms 轮询；
  输出或 ACK 阻塞时不等待持续有信号的帧事件，避免忙循环。
  已完成图形协商与当前允许输出分别记录，最小化/输出暂停不会再次触发认证超时；
  rc6 实机最小化超过 30 秒后保持连接并成功恢复。
- 首版使用 TCP，不预设 RDP UDP multitransport 已在自定义 iOS 服务端实现。
  TCP 仍有队头阻塞；RDP 本身不是低延迟或 60 FPS 的保证。

## 4. 账号、加密和设置

使用 **TLS + NLA/CredSSP**，固定 3389，只用于可信局域网。
局域网不等于可以取消认证或使用弱 RDP Security。

- schema 3 同时保存 PBKDF2-SHA256 和 NLA NT hash；均不保存明文密码。NT hash 是密码等价敏感材料。
- [New-Credentials.ps1](scripts/New-Credentials.ps1) 在 Windows 安全输入初始密码并生成完整配置；
  打包使用私有配置，安装后默认开启，无需现场配对。当前个人包沿用此前提供的远程账号/密码。
- 用户名 1–64 位，不含控制字符、冒号和反斜杠；新密码 12–256 位。
  设置页保存时同步更新两种哈希、断开已有连接、刷新 NLA 存储。
- 配置、NTLM 存储、初始种子、TLS 私钥在设备上均为 root 私有文件。个人 deb 含初始 NT hash，
  **不要公开分发、上传公开仓库或发送给他人**；构建输出和私有材料目录限制 Windows ACL，
  凭据生成/迁移也在创建或覆盖文件时限制 DACL。
- 每台设备首次安装生成独立 RSA/SHA256 自签证书和私钥，包不携带 TLS 私钥或专用 CA 私钥。
  SAN 包含安装时本机 IPv4；建议固定 DHCP 租约。地址变化可能导致证书名称校验失败，
  当前没有自动证书轮换功能，不应绕过名称校验。
- 安装脚本下载新公开证书；连接脚本先检查精确 SHA256 指纹、地址、有效期和缺链状态，
  再打开 mstsc。首次 mstsc 证书警告需查看并核对指纹；不导入 Windows CA、不关闭全局验证。
- 服务关闭后停止监听、断开会话、释放触控/采集/编码，只保留本机管理。
  状态中的 `listening` 才表示真实监听；启动错误会返回并显示，不假报成功。
- 升级保留 schema 3 账号及开关。schema 2 只在安装种子的原 PBKDF2 身份字段完全匹配时
  导入 NLA 材料并迁移到 3389，不匹配则明确拒绝，不重置账号。
  本次实机按授权执行全新安装，未验证旧 schema 2 原地升级。

## 5. 源码清理结果

已移除网页静态资源、HTTP 路由、Cookie/session、WebSocket、自定义 RIPD 视频包、
WebCodecs/MSE/fMP4、浏览器/旧视频协议测试、本地网页代理、Node 依赖及旧发布包。

保留：

- [native/Engine.mm](native/Engine.mm)：IOSurface 采集、VT 硬件编码、HID；输出改为原生 sample 回调。
- [native/Daemon.mm](native/Daemon.mm)：本机管理、状态、日志轮转与 RDP 生命周期。
- [native/Configuration.mm](native/Configuration.mm)、[native/Paths.hpp](native/Paths.hpp)：配置迁移、设备证书与双布局路径。
- [native/RDP.mm](native/RDP.mm)：NLA/AVC420、单客户端、有界输出、鼠标及超时处理。
- [native/Management.hpp](native/Management.hpp)：有界 IPC 和超时。
- [native/Preferences.mm](native/Preferences.mm)、[native/SettingsHook.mm](native/SettingsHook.mm)：设置页与通用入口。
- [native/Probe.mm](native/Probe.mm)：采集/硬件/HID 诊断，非网络服务。
- [tests/management.mm](tests/management.mm)：本机管理请求工具，不保留旧网页迁移和服务运行假设。
- [scripts/Invoke-Ipad.ps1](scripts/Invoke-Ipad.ps1)：设备运维工具。
- [packaging/](packaging/)：由打包脚本替换前缀，生成 rootful/rootless 两种包。

已删除独立 pilot 模式、部署脚本和旧本地 TLS 生成流程；正式服务统一通过 deb 安装。

## 6. Windows 本地 Docker 验证

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1 -Foundation
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1 -Probe
```

先运行 [Get-Dependencies.ps1](scripts/Get-Dependencies.ps1)，再运行 `Build.ps1 -Dependencies` 构建固定版本的 iOS 库。
无参数生成两个个人 deb：

- [com.xyhelper.remoteipad_0.4.0~rc7_iphoneos-arm.deb](packages/com.xyhelper.remoteipad_0.4.0~rc7_iphoneos-arm.deb)：rootful，ARM64 CPU。
- [com.xyhelper.remoteipad_0.4.0~rc7_iphoneos-arm64.deb](packages/com.xyhelper.remoteipad_0.4.0~rc7_iphoneos-arm64.deb)：rootless，ARM64 CPU；当前 iPad 使用此包。

`-Foundation` 编译 rootless 基础、管理工具、设置 bundle 和 hook，不生成 deb。
`-Probe` 编译原生诊断程序。

Docker 编译容器使用 `--network none`，依赖本地已存在的工具链镜像。
[Dockerfile](Dockerfile) 中基镜像的历史名称为 `cloudflared-ios-builder:latest`，
这里只复用 Theos/Clang/iOS SDK；不构建、部署或运行任何隧道组件。
SDK 16.5 / arm64 iOS 15 编译目标不代表设备系统版本。

包结构校验覆盖架构、ARM64 Mach-O、双前缀/rpath、配置形状、权限、
launchd/安装脚本与私钥排除：

```powershell
docker run --rm --network none --mount "type=bind,source=$PWD,target=/work" remoteipad-builder:local -c "python3 tests/packages.py"
```

构建同时生成 `build/rootless/preferences-test` 和 `build/rootful/preferences-test`，
用于对应 iOS 环境中验证入口名称、29 pt 原色图标及真实设置格式化方法：中文状态、FPS/ms/Mbps 单位、
空闲时隐藏上一会话的尺寸与耗时、状态过期提示。不把这些测试工具打进 deb。
`build/rootless/output-flow-test` 和 `build/rootful/output-flow-test` 验证真实背压计时策略：
输入延迟不算写超时、短暂积压恢复后清零、连续积压在 2000 ms 边界超时；测试工具也不打进 deb。
构建还生成 `latency-flow-test`、`avc-buffer-test` 和 `encoder-properties-test`：
分别验证两帧合计预算/输入批次/暂停期限、连续与分段码流转换、隔离的硬件属性探测。
硬件属性探针只在正式编码器释放后运行，不打进 deb。A10 上 `MaxFrameDelayCount`
虽然可读，写入 0 或 1 均返回 -12900，因此正式编码器没有强行设置或声称该属性降低了延迟。

### 响应延迟实测

保持同一台 iPad、Windows mstsc、1080×1440、目标 60 FPS、约 4 Mbps。
先进入设置中的“响应延迟测试”，保持远程桌面窗口可见；测试期间不要移动鼠标、遮挡或调整窗口。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Measure-RdpLatency.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Measure-RdpLatency.ps1 -Count 40 -OutputPath .\build\latency-rc7-after.json
```

[Measure-RdpLatency.ps1](scripts/Measure-RdpLatency.ps1) 仅匹配指定 IP 的唯一 mstsc 窗口，
也可通过 `-ClientProcessId` 指定进程。检查前台、窗口位置/大小和鼠标位置，
条件变化即停止。2 次预热后统计 40 次 Windows `SendInput` 到首次红绿像素回显，
P50/P95 使用 nearest-rank；不保存截图或输入内容。

| 版本 | P50 | P95 | GDI 读取 P50 |
|---|---:|---:|---:|
| rc5 基线 | 179.68 ms | 219.00 ms | 17.14 ms |
| rc6 输入与编码流优化 | 179.95 ms | 199.29 ms | 16.98 ms |
| rc7 帧就绪通知 | 179.58 ms | 199.06 ms | 13.00 ms |

原始结果保存在 [基线](build/latency-baseline.json)、[rc6](build/latency-rc6-after.json)、
[rc7](build/latency-rc7-after.json)。P95 比基线约低 9%，但中位数没有明显改善，
rc7 相比 rc6 也没有可确认的额外改善。每版只有一组样本，读取开销也会波动，
不能据此断言整体显著加速或将变化全部归因于代码。GDI 读取/轮询开销已包含在结果中，
没有简单相减后冒充无扰动延迟。

rc7 实机状态采样：采集到编码回调平均约 20.69 ms，编码队列到封包调用完成平均约 0.69 ms，
编码约 59.52 FPS，队列 0，最近错误为空；这些不是网络到达或客户端显示延迟。
测试页记录的最后 40 次输入事件时间戳到按钮动作 P50 18.13 ms、P95 27.80 ms，
不包含 Windows 输入到达前的阶段，也不能证明触控按下到释放的总耗时。
祖先手势的延迟标志只能提供线索，没有修改系统手势或断言 UIKit 固定等待 150 ms。

仅测试页点击会在 `/var/mobile/Library/Caches/com.xyhelper.remoteipad-latency.plist`
后台写入最多 202 个数字耗时、次数、更新时间及祖先类名/延迟布尔值；
不记录全局按键、文本或截图。本轮读取结果保存到
[设备侧诊断](build/latency-rc7-device.json)，随后清除该设备缓存；再次点击测试页会重新创建。
TCP_NODELAY 在基线中已开启，不作为本轮新增优化。
当前仍使用原生 BGRA → VideoToolbox 硬件 H.264；Metal/NV12/直接显示 surface 尚未实现。

### rootless 安装及试运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Ipad.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Installed.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Open-Remote.ps1
```

默认安装保留已有配置。只有明确要删除旧包和全部 Remote iPad 配置时，才加 `-CleanOldVersion`；
此选项不适用于保留账号/开关的正常升级。脚本检查 rootless 链接，使用 dpkg，不在根目录解包 tar。
上传文件在 finally 清理，新公开证书保存到 `private/installed-server.crt`。

`Test-Installed.ps1` 是有副作用的实机测试：短暂断开连接、关闭/开启服务、设置临时账号、
重启 daemon；完成或失败时尝试恢复**测试开始时的新安装配置**，并核对恢复结果。
失败时明确报错，恢复失败会保留测试备份，不应在活跃使用中随意运行。
它验证管理接口和认证存储，不代表设置页 UI 或实际客户端密码认证已验证。

[rdp-negotiation.ps1](tests/rdp-negotiation.ps1) 只验证 HYBRID/NLA 协商和精确 TLS 身份，
不提交密码，不证明视频可用。握手后主动断开产生未完成认证日志是预期行为。
[Open-Remote.ps1](scripts/Open-Remote.ps1) 生成不含密码的连接文件；修改账号后可传 `-Username`。
在 mstsc 输入远程密码并核对新证书指纹，不要继续使用旧 pilot 指纹。
连接文件禁用剪贴板、音频、打印机和磁盘重定向，脚本不接管密码输入。
SSH 工具使用单一 JSON 请求；含引号的命令请直接调用脚本或用 PowerShell `-Command { ... }`，
不要用原生 `-File ... -Command` 传递嵌套引号。

## 7. 后续实施关口

| 阶段 | 必须验证的结果 |
|---|---|
| A：FreeRDP 服务端可行性 | 固定版本交叉编译、依赖最小化、rootless 加载、TLS/会话协商，不先假设 iOS 服务端现成可用 |
| B：硬件图形链路 | VT 样本 → AVC420 → mstsc 真实可见画面，测客户端呈现，不仅看编码计数 |
| C：输入与生命周期 | 连续点击/拖动、断线释放、启停、重新连接和错误恢复 |
| D：认证与证书 | 正确/错误密码、NLA、旧凭据迁移、改密码撤销、证书验证、局域网访问边界 |
| E：采集对照 | 相同输出条件下比较直接 surface、当前 render、可选 GPU 转换的延迟/温度/内存 |
| F：发布验收 | 30 分钟连续交互、2 小时运行、至少 50 次重连及启停、内存不持续增长、无冻结和残留触点 |

建议初始延迟验收目标：稳定局域网下可见输入反馈 p95 ≤ 150 ms，运动场景向 60 FPS 靠近。
这是待测目标，不是当前承诺；采集完成、编码回调、队列、发送和可见呈现需要分别观测。
FrameAck 不一定表示显示器已呈现，测真实端到端反馈需客户端可见证据或外部同步拍摄。
当前实测 P95 约 199 ms，尚未达到 150 ms 目标。RC 包仅供用户授权试运行；
长期稳定性、目标可见延迟和 rootful 实机兼容仍需上述验收，
不能因为包已生成就宣称全部通过。

## 参考依据

- [FreeRDP server Sample](https://github.com/FreeRDP/FreeRDP/tree/master/server/Sample)
- [FreeRDP Shadow](https://github.com/FreeRDP/FreeRDP/tree/master/server/shadow)
- [Microsoft AVC420 bitmap stream](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/5f12c20e-2ea1-4ad1-a2a0-019ee3893731)
- [Microsoft AVC420 metablock](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/c4a67f2c-06a9-4ea6-b043-f708e7f57db8)
- [Apple ReplayKit security](https://support.apple.com/guide/security/replaykit-security-seca5fc039dd/web)
- [Apple ReplayKit](https://developer.apple.com/documentation/replaykit)
- [Apple AirPlay 操作流程](https://support.apple.com/en-us/102661)
- [Dopamine IOMobileFramebuffer 头文件](https://github.com/opa334/Dopamine/blob/master/BaseBin/_external/frameworks/IOMobileFramebuffer.framework/Headers/IOMobileFramebuffer.h)
- [历史 RecordMyScreen 头文件](https://github.com/coolstar/RecordMyScreen/blob/master/RecordMyScreen/headers/IOMobileFrameBuffer.h)

私有接口资料仅证明公开代码存在该候选；本轮没有新增实机 surface/镜像探针验证。
