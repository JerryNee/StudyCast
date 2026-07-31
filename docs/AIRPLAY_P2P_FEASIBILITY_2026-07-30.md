# StudyCast 校园网 AirPlay 可行性说明（实测修订版）

日期：2026-07-30  
结论对象：StudyCast 0.1.0-beta.2、UxPlay 1.74、Apple Vision Pro、macOS 27.0 测试机

> **2026-07-31：本文结论已作废，仅作过程记录保留。**
>
> 问题已解决。StudyCast 现在通过 AWDL 被发现和连接，**不需要校园网配合、
> 不需要设备登记、不需要 Guest 网络、不需要自带路由器**，并且不需要逆向任何
> 未公开协议。第三方设备（非本机账号、网络侧登记已移除）实测可正常投屏。
>
> 本文以下判断均已被实测推翻：
>
> - 第 1 节「没有可承诺的受支持实现路径」；
> - 第 1、5 节「强制 AWDL 后可见但 TCP 7000 始终 0 字节」——真实原因是监听
>   socket 未设置 `SO_RECV_ANYIF`，而非发现或配对失败；
> - 第 5 节「加 `kDNSServiceFlagsIncludeP2P` 仍不可发现」——真实原因是当时把
>   服务钉死在 `awdl0` 接口，改用 `kDNSServiceInterfaceIndexAny` 后即可见；
> - 第 7 节的方案 A/B/C/D/E 全部不再适用。
>
> 现行方案见 **[AWDL_DISCOVERY.md](AWDL_DISCOVERY.md)**。
>
> 仍然成立的部分：第 2 节的 Apple 官方文档引用、第 2.7 节关于系统接收器私有
> 权限的分析，以及第 3 节 UxPlay 上游对 AWDL 的态度。这些解释了为什么
> 「伪装成系统 Mac」不可行——而最终方案恰恰不需要伪装。

## 1. 给管理层的结论

最新 socket 级“停止投屏—重新投屏”A/B 已确认：本次 Vision Pro
投屏到 macOS 系统接收器时，会话会新建多条 `awdl0` IPv6 TCP/UDP
连接；停止投屏后这些连接立即关闭。此前依据网卡总字节增量判断媒体经过
`en0`/IllinoisNet 是误判，因为 `en0` 同时承载了大量无关应用流量。
成功会话还会把系统 `_airplay._tcp` 与 `_raop._tcp` 的 SRV 端点从待机
服务切换到由 `ControlCenter` 临时监听的 `58412` 端口，并发布到
`en17`（接口 29，链路本地地址 `169.254.51.130`）。因此，系统 Mac
并不是把固定的 TCP 7000 服务原样暴露给 Vision Pro。

现有证据支持以下分层结论：

- StudyCast/UxPlay 的媒体协议可用；它在个人热点上能够被 Vision Pro 发现并完成镜像。
- 在 IllinoisNet 上，StudyCast 已在本机正确发布 `_airplay._tcp` 和 `_raop._tcp`，但 Vision Pro 没有收到或没有接受这些服务记录；失败发生在“发现/网络准入”阶段。
- 将服务直接发布到 `awdl0` 可以让 Vision Pro 显示接收器，但选择后 UxPlay 的 TCP 7000 累计收发始终为 0 字节；可见性不等于建立了可用的点对点链路。
- 进一步将 AWDL 发现到的 SRV 目标桥接到本机 IllinoisNet IPv4，Vision Pro 仍未向 TCP 7000 发起连接，因此失败早于 UxPlay 的 RTSP、配对和媒体协议。
- UIUC 官方支持的个人接收设备拓扑是：登记接收设备的 Wi-Fi MAC、启用 AirGroup、让接收设备连接 `IllinoisNet_Guest`；发送端继续连接 IllinoisNet。
- 登记成功的设备通过 MAC 获得 Guest 网络访问，不走普通访客每天重新登录的流程；需要注意固定该 SSID 的 Private Wi-Fi Address，并在登记到期前续期。
- macOS 系统接收器具有普通应用没有的系统级发现和接收器实现；本次成功会话实测使用了 AWDL。

因此有两个不同的产品结论：

1. **UIUC 固定部署**：存在官方支持的纯网络方案，但必须按学校规定把接收端放在 `IllinoisNet_Guest` 并登记 AirGroup；继续把接收端留在 IllinoisNet 不属于 UIUC 文档给出的接收设备部署方式。
2. **任意大学、零配置、零硬件**：仍然不能保证。每所学校都可能过滤未授权 DNS-SD；普通 macOS 应用也没有公开 API 可完全复制系统 AirPlay Receiver 的私有发现能力。

若产品要求“不依赖各校 IT、不使用 Guest/自带网络/额外硬件、仍从 Vision Pro 系统屏幕镜像发起并支持多接收端”，目前没有可承诺的受支持实现路径。

## 2. Apple 官方证据

### 2.1 Apple 明确区分三种 AirPlay 发现路径

Apple 的部署文档把 AirPlay 发现分成：

1. Bonjour；
2. Bluetooth IP address advertisement；
3. peer-to-peer discovery。

Apple 同时说明 Bonjour 使用 multicast，通常不会跨子网转发；大型网络需要 Bonjour gateway，并需要传播 `_airplay._tcp` 和 `_raop._tcp`。  
来源：[Use AirPlay with Apple devices](https://support.apple.com/en-sg/guide/deployment/dep9151c4ace/web)

这解释了为什么 StudyCast 在私人热点中可见、在受管理校园网中不可见：热点允许本地 Bonjour，而校园网可以过滤、代理或按策略授权服务。

### 2.2 macOS 系统接收器在本次 UIUC 会话中实际建立了 AWDL 链路

Apple 的 macOS Monterey 技术说明明确表示，系统“AirPlay receiver”的 `Everyone` 模式即使没有连接 Wi-Fi，也支持 peer-to-peer discovery and connectivity。  
来源：[Prepare your organization for macOS Monterey](https://developer.apple.com/videos/play/tech-talks/10891/?time=1120)

为避免把普通联网流量误认为 AirPlay，本项目进行了 socket 级开关对照：

1. 无投屏时记录所有 `awdl0`/`anri0` 已建立连接；
2. 开始系统 AirPlay 投屏后，立即新增 9 条 AWDL IPv6 TCP 和 2 条
   AWDL UDP；
3. 新连接由 `rapportd`、`UniversalControl` 和 `ControlCenter` 持有，
   两端地址均明确带 `%awdl0`；
4. 停止投屏后，这些 socket 进入 `FIN_WAIT` 并消失；
5. 重新投屏后，又以新的端口建立同样一组 AWDL 连接；
6. `ControlCenter` 的 AWDL UDP 包含 `VO` 流量类别并持续接收数据；
7. 同期未发现 Vision Pro 校园网 `10.x` 地址进入系统 AirPlay 的已建立
   socket；
8. 会话建立后，系统 `_airplay._tcp` 和 `_raop._tcp` 都解析到
   `Jerrys-MacBook-Pro-408.local.:58412`、接口 29；`lsof` 确认
   `58412` 的 IPv4/IPv6 listener 均由 `ControlCenter` 持有；
9. 同一主机名在接口 29 上解析到 `en17` 的 IPv4 链路本地地址
   `169.254.51.130`，同时系统仍维持 `awdl0` 上的会话 socket。

这证明本次成功会话确实进入了 Apple 系统管理的点对点链路和动态接收端点，
而不是直接连接 IllinoisNet 上的固定 TCP 7000。关闭蓝牙不能排除 AWDL：
AWDL 使用 Wi-Fi 无线电，蓝牙只是 Apple 文档列出的发现/触发方式之一；
在已有 Bonjour、缓存、配对或其他 Apple 发现上下文时，关闭蓝牙不等于
关闭 `awdl0`。

### 2.3 Apple 公共 AirPlay API 面向发送端，不提供等价接收端注册

Apple 公开的 AirPlay 应用文档讲述如何：

- 使用 AVFoundation/AVKit 把媒体发送到 AirPlay 设备；
- 使用 `AVRoutePickerView` 显示输出设备；
- 配置播放和路由。

来源：

- [Supporting AirPlay in your app](https://developer.apple.com/documentation/avfoundation/supporting-airplay-in-your-app)
- [AVRoutePickerView](https://developer.apple.com/documentation/AVKit/AVRoutePickerView)

在当前公开文档中，没有与 macOS 系统“隔空播放接收器”等价、可供普通应用注册为 AirPlay Mirroring receiver 的 API。

### 2.4 公开的 Apple peer-to-peer Wi-Fi API 不是 AirPlay receiver API

Apple 允许应用通过 Network framework 的 `includePeerToPeer` 建立 Apple 设备之间的应用网络连接，但官方同时说明其 on-the-wire protocol 不公开，只能用于配合开发的 Apple 设备应用。  
来源：[TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)

它不能让 Vision Pro 的系统屏幕镜像功能自动把任意 `_airplay._tcp` 应用当成原生接收器。StudyCast 已实际测试 `kDNSServiceFlagsIncludeP2P` 注册，Vision Pro 仍未显示接收端。

### 2.5 新的 Media Device framework 不是当前目标的直接解法

Apple 的 Media Device framework 是 iOS 27 beta 功能。它要求在发送端 iOS 应用中安装带 entitlement 的 extension，并实现自定义 media-sharing protocol；文档描述的是从 iOS 应用把媒体发送到第三方播放硬件。  
来源：[Creating a media device extension](https://developer.apple.com/documentation/MediaDevice/creating-a-media-device-extension)

它目前不能满足本项目的关键约束：

- 不是 macOS 接收端应用单独安装即可生效；
- 需要发送端应用/extension；
- 不是让 Vision Pro 系统控制中心把 StudyCast 当成原生 AirPlay receiver；
- 仍是 beta API。

它可以作为未来“Vision Pro 配套发送应用 + StudyCast 自定义传输协议”的架构研究方向，但那已经不是兼容系统 AirPlay Mirroring。

### 2.6 Apple 对第三方 AirPlay 技术采用授权体系

Apple MFi 计划把 AirPlay audio 列为 licensed technology，并通过计划向硬件厂商提供规范、认证工具和许可。公开 MFi 页面没有提供可直接下载的 AirPlay Mirroring receiver SDK。  
来源：[MFi Program — How It Works](https://mfi.apple.com/en/how-it-works)

这不能单独证明视频镜像永远无法实现，但证明 Apple 的完整第三方接收器技术并不是普通开发者公开 API 的一部分。

### 2.7 本机系统接收器不是可供应用复用的库

本机检查显示，系统接收器由单例系统 LaunchDaemon
`/usr/libexec/AirPlayXPCHelper` 提供。其 Apple 平台签名包含普通应用无法
自行获得的私有权限，包括：

- `com.apple.wifip2pd`
- `com.apple.wifi.peer_traffic_registration`
- `com.apple.private.corewifi`
- `com.apple.bluetooth.system`
- `com.apple.PairingManager.Read/Write`
- `com.apple.rapport.Client`
- `com.apple.private.system-keychain`
- `com.apple.private.airplay.mangrove.client`

StudyCast 的签名不具备这些权限。给普通应用的 ad-hoc 签名手工写入同名
entitlement 也不会获得系统授权；这些权限由 Apple 平台签名和系统服务身份
共同校验。系统只暴露单例 `com.apple.AirPlayXPCHelper` Mach service，
没有公开的“创建第二、第三个 AirPlay Receiver”API。

因此，“复制 Mac 内置协议”不是把 UxPlay 的 TXT、端口或启动参数改成 Mac
即可：内置实现还依赖系统 Wi-Fi 建链、设备配对、Rapport 和系统密钥服务。

## 3. UxPlay 维护者证据

### 3.1 UxPlay 当前不支持 AWDL AirPlay

在 2025 年的 UxPlay issue 中，维护者直接回复：

- UxPlay 不支持通过 OWL/AWDL 建立 AirPlay；
- 可能可以研究，但需要观察并记录真实 Apple TV 的连接；
- 目前不知道 AWDL 握手如何建立；
- issue 最终关闭为 `not planned`。

来源：

- [Maintainer: “It doesn't support it”](https://github.com/FDH2/UxPlay/issues/472#issuecomment-3495875401)
- [Maintainer: peer-to-peer BLE data still contains seven unknown bytes](https://github.com/FDH2/UxPlay/issues/472#issuecomment-3499930574)
- [Maintainer: handshake unknown; issue closed](https://github.com/FDH2/UxPlay/issues/472#issuecomment-3501063327)

这与“升级 UxPlay 或增加 P2P 注册标志即可获得系统 Mac 协议”的假设直接冲突。

### 3.2 UxPlay 对校园网问题的已知结论

另一个用户在大学网络中遇到：

- UxPlay 服务在本机正确注册；
- iOS 客户端看不到；
- 普通 HTTP 连接可用；
- 换 iPhone 热点后立即成功。

这是与 StudyCast 当前测试最接近的公开案例。维护者和参与者判断问题属于大学网络对 mDNS 的过滤/隔离，不是 UxPlay 媒体协议故障。  
来源：

- [University network issue #234](https://github.com/FDH2/UxPlay/issues/234)
- [Hotspot immediately works](https://github.com/FDH2/UxPlay/issues/234#issuecomment-1789836619)
- [Likely no client-side workaround for blocked mDNS](https://github.com/FDH2/UxPlay/issues/234#issuecomment-1789914198)

Eduroam issue #163 中，维护者同样判断学校可能只允许已授权的 DNS-SD 服务。2025 年的后续回复指出，最新版 UxPlay 可用 BLE beacon 绕过 DNS-SD 发现；该机制广播 UxPlay 的 IPv4 地址和端口，媒体仍走普通 IP 网络。  
来源：[Running UxPlay on Eduroam](https://github.com/antimof/UxPlay/issues/163)

### 3.3 UxPlay 的官方绕过方案只是 BLE “发现”，不是完整 AWDL

UxPlay 1.73+ 增加 BLE beacon：它广播接收端 IPv4 地址和端口，使 Apple 客户端在不使用 DNS-SD 的情况下发现 UxPlay。媒体仍通过普通 IP 网络连接。

限制：

- macOS 原生蓝牙栈不允许普通用户程序发送所需的 manufacturer-specific BLE advertisement；
- UxPlay 在 macOS 上要求 BleuIO USB dongle；
- BLE 只绕过发现，不能绕过校园网对客户端到接收端 IP/端口的访问控制；
- 多个 beacon 同时服务多个 UxPlay 实例在官方 README 中标为未测试。

来源：[UxPlay Bluetooth LE beacon setup](https://github.com/FDH2/UxPlay#bluetooth-le-beacon-setup)

## 4. UIUC 官方网络证据

UIUC 的 AirGroup 文档说明：

- AirGroup 用设备所有权和 NetID 限制发现；
- 接收/服务设备需要在设备门户登记并启用 AirGroup；
- 普通用户只能共享给指定 NetID；
- 部门账号才可以配置同一建筑内广泛可发现。

来源：[UIUC AirGroup troubleshooting](https://answers.uillinois.edu/illinois/90276)

UIUC 对个人 Apple TV 和其他非 802.1X 接收设备的官方配置是：登记接收设备 MAC，然后把接收设备放在 `IllinoisNet_Guest`。发送端可以并且应当留在 IllinoisNet，AirGroup 负责跨网络发现。  
来源：[UIUC Wi-Fi Help Portal — IoT devices](https://answers.uillinois.edu/illinois/90287)

UIUC 的设备登记说明还指出，Manage Devices 中登记的设备会从 `IllinoisNet_Guest` 获得网络访问，并可持续使用到登记到期，而不是普通访客每天经过网页登录。  
来源：[UIUC Wi-Fi Help Portal — Gaming Devices](https://answers.uillinois.edu/enterpriseservicecatalog/90286)

这仍是一种 UIUC 特定的受管网络方案，不是可带到任意大学的通用产品能力。若产品明确排除 Guest，则也排除了 UIUC 为个人 AirPlay 接收设备公开支持的部署拓扑。

## 5. StudyCast 本机对照实验

测试平台：

- macOS 27.0，Apple Silicon；
- StudyCast Git commit `e7c72fb1e7a4`；
- UxPlay 1.74，source commit `a73e88c77d7aaa70c1cef0cb31b6407787b9ca1d`；
- IllinoisNet IPv4 `10.194.138.217`；
- 三个独立 UxPlay 接收端：`StudyCast-1/2/3`。

| 测试 | 结果 | 说明 |
|---|---|---|
| StudyCast 与 Vision Pro 同接个人热点 | 可发现 | 证明 Vision Pro 与 UxPlay 1.74 的基本 AirPlay 镜像兼容 |
| StudyCast 与 Vision Pro 同接 IllinoisNet | 不可发现 | 失败集中在校园发现路径 |
| macOS 防火墙关闭 | 仍不可发现 | 排除主机应用防火墙 |
| 本机 `dns-sd` 检查 `_airplay._tcp` / `_raop._tcp` | 三个实例均正确发布 | UxPlay 没有停止注册服务 |
| 模仿校园 Solstice 的 model/features/srcvers/TXT | 仍不可发现 | 不是简单设备型号或 feature bit 过滤 |
| 启用 PIN/配对 feature | 仍不可发现 | 不是缺少 PIN 标志 |
| 同时模仿 Solstice 的 AirPlay 与 RAOP TXT | 仍不可发现 | 不是 RAOP TXT 差异 |
| DNSServiceRegister 加 `kDNSServiceFlagsIncludeP2P` | 仍不可发现 | 公开 P2P 注册标志不足以复刻系统 AirPlay receiver |
| Mac 系统 AirPlay Receiver | 可发现 | 系统接收器拥有额外 Apple 平台能力 |
| Mac 关闭蓝牙后的系统接收器测试 | 仍可工作 | 蓝牙不是 AWDL 本身；关闭蓝牙不能排除 Wi-Fi 点对点链路 |
| 仅比较 `awdl0` 与 `en0` 总字节增量 | `en0` 增长更多 | 已判定为无效方法：`en0` 同时包含浏览器、同步和其他互联网流量 |
| 系统投屏的 socket 级“停—投—停—再投”A/B | 每次开始都新增 9 条 AWDL TCP、2 条 AWDL UDP；停止后关闭 | 直接证明本次系统 AirPlay 会话建立在 `awdl0` 上 |
| 成功会话中检查校园网 socket | 未发现 Vision Pro `10.x` 地址进入 AirPlay | 不支持“本次系统投屏媒体仅走 IllinoisNet”的假设 |
| 成功会话中解析系统 `_airplay` / `_raop` | 两者均切换到 `58412`、接口 29；`ControlCenter` 持有 listener | 系统会话使用动态端点，不是把待机 TCP 7000 直接交给发送端 |
| 解析接口 29 的系统主机地址 | `en17 = 169.254.51.130`，链路本地地址 | 系统还创建/启用了独立于 IllinoisNet 地址的点对点网络接口 |
| 对比系统 Mac 与 StudyCast 的 DNS-SD | 两者均在接口 14 发布 `_airplay._tcp`/`_raop._tcp` | StudyCast 本机发布成功，但远端可见性受校园发现策略或客户端筛选影响 |
| 系统 Mac AirPlay TXT | `model=Mac15,6`、`srcvers=980.63.2`、现代 features/protovers | 系统实现与 UxPlay legacy 广告存在明显能力差异 |
| StudyCast AirPlay TXT | `model=AppleTV3,2`、`srcvers=220.68`、三个独立虚拟 Device ID | 热点可见，说明字段足以在普通 LAN 工作；尚不能断言 UIUC 具体过滤哪一字段 |
| Mac 风格广告 A/B 实验 | `StudyCast-1` 使用 Mac 风格 TXT，`StudyCast-2/3` 保持标准 UxPlay | 实验实现和本机 TXT 验证完成 |
| 精确复制系统 Mac 的实例名、Device ID、SRV 主机、端口、型号、版本和非能力 TXT，保留 UxPlay 自有 key/features | IllinoisNet 上仍不可见 | 排除名称、Device ID、主机名、端口和普通 TXT 指纹 |
| 再复制系统 Mac 的完整 `features`，仅保留 UxPlay 必须匹配私钥的 `pk` | IllinoisNet 上仍不可见 | 排除 AirGroup 只按 feature bitmap 筛选 |
| 精确 Mac 广告直接注册到 `awdl0` | Vision Pro 可见，但选择后 `Unable to Connect` | 恢复了发现，未建立可用连接 |
| 上述 AWDL 测试期间统计 UxPlay TCP 7000 | `bytes_in=0`、`bytes_out=0`，无已建立 socket | 失败发生在 UxPlay RTSP/加密握手之前 |
| 使用 Apple 文档规定的 `kDNSServiceInterfaceIndexP2P` 注册 | Vision Pro 不可见 | 公共 DNS-SD P2P 注册语义没有复制系统接收器发现行为 |
| AWDL 发布服务，并把自定义 SRV/A 记录桥接到 IllinoisNet `10.194.138.217:7000` | 可见但仍 `Unable to Connect`，TCP 仍为 0 字节 | 仅用 DNS-SD 把“发现路径”和“普通 Wi-Fi 传输路径”拼接无效 |
| UIUC 门户登记当前 IllinoisNet MAC，启用 AirGroup，并重新发布三个服务 | 仍不可发现 | AirGroup 在当前 IllinoisNet 布置下没有解决；UIUC 官方接收设备布置要求 Guest |

这些对照实验共同表明：

1. UxPlay 媒体会话本身可用；
2. Bonjour 在私人局域网可用；
3. 普通 IllinoisNet DNS-SD 路径没有让 StudyCast 获得与系统接收器相同的连接；
4. 本次系统 Mac 的成功会话实际建立了 AWDL 链路；
5. 修改公开 DNS-SD 字段和 P2P 标志仍不能获得 macOS 系统接收器的全部发现能力；
6. 强制 AWDL 发布只能制造一个“可见但不可连接”的列表项，不能证明 UxPlay 已支持点对点 AirPlay；
7. 失败时 TCP 7000 为 0 字节，排除了 UxPlay RTSP、解码、录制和多实例逻辑作为当前根因。

## 6. 若坚持绕过所有校园网络策略，实际包含的工作

若继续选择该方向，至少需要完成以下未知项：

1. 捕获并解析真实 Mac/Apple TV 的 BTLE Continuity advertisement；
2. 识别并生成用于 peer-to-peer AirPlay 的未公开数据；
3. 在 macOS 上获得足够底层的 Wi-Fi/AWDL 控制权限，或开发外部网络 sidecar；
4. 复现 AWDL 建链和地址配置；
5. 复现 AirPlay peer-to-peer 认证、配对和加密；
6. 将该链路接入 UxPlay 的 legacy AirPlay server；
7. 验证 Vision Pro 各版本兼容性；
8. 设计三条并行接收链路、资源隔离和重连；
9. 评估私有 API、系统完整性保护、代码签名、分发和 Apple 许可风险。

UxPlay 上游目前没有完成第 1–5 项。项目无法仅通过修改 StudyCast 的 Swift UI 或普通 UxPlay 启动参数获得 AWDL。

但这些工作**不是解决 UIUC 官方部署的前置条件**：若 Guest + AirGroup 配置成功，媒体可以继续使用普通 IP/Wi-Fi。

## 7. 可向管理层提出的决策

### 方案 A：把“任意校园网、零额外硬件”定义为不可支持环境

产品文档要求一个允许本地发现和客户端互访的局域网。跨校演示使用自带旅行路由器。该方案保留标准 Vision Pro 系统屏幕镜像，并支持当前三接收端架构。

### 方案 B：校园部署由学校网络提供 Bonjour/AirGroup

适合固定场地，不适合跨校即插即用。UIUC 应先验证“已登记的接收端连接 IllinoisNet_Guest、Vision Pro 连接 IllinoisNet”。其他学校需要各自的 IT 配置和长期设备身份。

### 方案 C：BleuIO + UxPlay BLE beacon

它可以绕过被屏蔽的 Bonjour 发现，并尝试把客户端指向 UxPlay 的 IPv4 地址和端口。注意：本次严格 socket A/B 已推翻“系统 Mac 的媒体经 `en0`”这一判断，所以不能再以系统接收器成功作为 IllinoisNet 普通 IP 媒体可达的证据；该方案必须用真实硬件单独验证。

限制是 macOS 原生蓝牙栈不向普通应用开放所需的 manufacturer-specific AirPlay advertisement，UxPlay 在 macOS 上明确要求 BleuIO USB dongle。多个并行 beacon 在上游文档中仍标为未测试；一个接收端一个端口，三接收端可能需要多广告实例、轮播实现或多个适配器。该方案应先做硬件 PoC。

### 方案 D：立项私有协议逆向研发

这不是常规功能迭代。建议以“研究项目”单独预算，并设置逐级停止条件：

1. Vision Pro 能发现实验接收端；
2. 能建立直接数据链路；
3. 能完成一次稳定镜像；
4. 能支持三路并发；
5. 能在目标 macOS/visionOS 版本上稳定分发。

任何一级失败都可能终止该路线。当前资料不足以给出成功保证或固定交付日期。

### 方案 E：未来改成 Vision Pro 配套应用 + 自定义协议

研究 Apple 的 Wi-Fi Aware/Media Device 等公开框架，绕开 AirPlay receiver 私有协议。但这要求发送端安装配套应用，且当前新框架仍处于 beta，不能满足“直接使用系统屏幕镜像”的现有产品要求。

## 8. 推荐表述

可对外或对管理层使用以下表述：

> StudyCast 已验证可以在正常私人局域网中通过普通 IP 接收 Vision Pro AirPlay。对系统 Mac 的 socket 级“停—投—停—再投”A/B 则确认，本次校园环境中的成功系统会话实际新建了多条 AWDL IPv6 TCP/UDP，停止投屏后这些连接立即关闭；此前依据 `en0` 总流量得出“只走校园 Wi-Fi”的结论是误判。会话期间，系统 `_airplay` 与 `_raop` 还同时切换到 `ControlCenter` 临时监听的端口 58412 和链路本地接口 `en17`，说明内置接收器运行的是动态点对点建链流程，而不是固定 TCP 7000 服务。精确复制系统 Mac 的 Bonjour 身份在 IllinoisNet 上仍不可见；强制 AWDL 后虽然可见，但 UxPlay TCP 7000 始终为 0 字节，说明 StudyCast 只复制了服务广告，没有完成系统接收器通过 Rapport/wifip2pd 建立的真实点对点会话。macOS 内置接收器依赖 Apple 私有 Wi-Fi、配对、Rapport 和系统密钥权限，普通应用没有公开 API 创建等价或多个系统接收器。因此，在“不依赖校园 IT、不使用 Guest、不自带网络、不增加硬件、仍从 Vision Pro 系统屏幕镜像发起”的组合约束下，没有现成的纯应用实现；若继续研发，正确方向是复现 AWDL/Rapport 建链，而不是继续修改 AirPlay TXT。
