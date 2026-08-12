# 无需网络登记的 AirPlay 发现（AWDL）

日期：2026-07-31  
适用：StudyCast + 相邻 UxPlay 工作树（分支 `codex/studycast-stable-audio-fix`）

## 1. 结论

StudyCast 现在通过 Apple 的点对点 Wi-Fi（AWDL）被发现和连接，**不依赖所在网络的任何配置或设备登记**。发送端与接收端直接建链，媒体不经过基础设施 Wi-Fi 的转发策略，因此也不受托管网络对 mDNS 的过滤或客户端隔离影响。

这取代了 `AIRPLAY_P2P_FEASIBILITY_2026-07-30.md` 中「必须依赖校园网 Bonjour/AirGroup、Guest 网络或自带路由器」的结论。

## 2. 让它成立的三处改动，外加一个环境先决条件

改动全部在 UxPlay 侧，合计不到 40 行。缺任何一处都不成立。
除此之外还有一个不在代码里的前提，见 2.4——它同样是必需的。

### 2.1 Bonjour 注册加入 Apple 点对点

`lib/dns_sd/dns_sd.c`：

```c
*interface_index = kDNSServiceInterfaceIndexAny;
*flags = kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL;
```

关键在于 **必须用 `kDNSServiceInterfaceIndexAny`**。早期实验把服务钉死在 `awdl0` 接口上，结果反而对使用其他点对点接口的客户端不可见——这正是旧文档中「加了 `IncludeP2P` 仍不可发现」那条结论的由来。

注册到点对点后，mDNSResponder 会用一个随机 UUID 主机名（形如 `7dc0846c-....local.`）发布 SRV 记录。这是 Apple 的隐私行为，**不是故障**；该主机名在 AWDL 链路上可以正常解析。

### 2.2 监听 socket 必须显式接受 AWDL 流量

`lib/netutils.c`：

```c
#define SO_RECV_ANYIF 0x1104   /* XNU 私有 socket 选项 */
setsockopt(server_fd, SOL_SOCKET, SO_RECV_ANYIF, &on, sizeof(on));
```

这是最隐蔽的一环。普通 BSD 监听 socket 会**静默丢弃**由 AWDL 投递的数据包。没有它，接收端会出现在发送端列表里、但连接永远到不了服务进程——即旧文档记录的「可见但 `Unable to Connect`、TCP 7000 收发零字节」。

这两处都由 UxPlay 的 `-p2p` 选项一起打开，StudyCast 给每个 Station 都传它。
不加该选项时 UxPlay 的行为完全不变——服务仍解析到主机本身的名字，而不是
mDNSResponder 为点对点注册发布的随机 UUID 名字。

### 2.3 打开 feature bit 27

给 UxPlay 传 `-pin`。UxPlay 只在配置了 PIN 时才把 bit 27（"supports legacy pairing"）置位，而发送端会参考该位决定是否把接收端作为点对点目标提供出来。

代价是需要配对码。StudyCast 为每个 Station 分配固定四位码并显示在各自的 tile 上：

| Station | AirPlay 名称 | 配对码 |
|---|---|---|
| 1 | `StudyCast-1` | `1111` |
| 2 | `StudyCast-2` | `2222` |
| 3 | `StudyCast-3` | `3333` |

一室多屏时这也顺带避免了投错工位。

### 2.4 系统自带的「隔空播放接收器」必须开着（2026-08-12 补记）

系统设置 → 通用 → 隔空投送与接力 → 隔空播放接收器。**关闭时点对点连接不成立。**

同一台 Mac、同一台 iPad Air（`iPad13,16`）、同一条命令
（`-p2p -pin 3939 -d -p 35000`）、同一网络，半小时内做的 A/B/A：

| 接收器 | 独立启动次数 | 连接尝试 | 成功 |
|---|---|---|---|
| 开 | 8 | 8 | 8 |
| 关 | 2 | 3 | **0** |
| 恢复开 | 1 | 1 | 1 |

关闭状态下发送端**仍然能发现并列出**接收器，但每次连接都失败，且 uxplay 侧
日志零字节——没有 `Accepted IPv6 client`、没有 `Remote:`、没有 `connection
request`。这与 2.2 中缺少 `SO_RECV_ANYIF` 的症状**完全一致**，排查时必须先
排除本项，否则会误判成 helper 构建有问题。

关键的反面证据：**`awdl0` 在两种状态下都保持 `status: active`**，无论 uxplay
是否运行。所以机制不是「AWDL 接口掉线」，而是系统在接收器关闭时不再把 AWDL
投递的入站流量交给第三方监听者；`SO_RECV_ANYIF` 单独不足以兜住。具体机制未
定位，不要在此基础上编原理。

局限：一台主机、一个发送端、一个网络。它确立的是本机上可复现的依赖关系，
不是普遍规律。

StudyCast 已在 `AppModel.startProjection()` 中检测该设置，为关闭时给出非阻断
警告（`AppModel.systemAirPlayReceiverEnabled`，读 `com.apple.controlcenter`
的 `AirplayReceiverEnabled`，currentHost 作用域）。键不存在时不告警，因为
「从未设置过」不等于「已关闭」。

已向上游报告：[FDH2/UxPlay#544 issuecomment-5268751102](https://github.com/FDH2/UxPlay/pull/544#issuecomment-5268751102)。

## 3. 不要伪装成 Mac 接收器

存在一条看似更直接的路线：把接收端的 TXT 身份伪装成系统 Mac（`model=Mac15,6`、`srcvers=980.63.2`、完整 HomeKit 配对栈）。它**同样能拿到 AWDL**，但发送端会因此切换到 AirPlay 2 的媒体路径：不再发送 legacy `ekey`，改用一套未公开的密钥推导。结果是视频数据能送达接收端，但无法解密，画面全黑。

实测已确认 **Mac 身份不是 AWDL 的必要条件**：标准 UxPlay 身份同样能拿到点对点，并且走 UxPlay 本来就能解密的 legacy FairPlay 路径。

该路线保留为研究项，默认关闭，见 [AP2_MIRRORING_KEY_SEARCH.md](AP2_MIRRORING_KEY_SEARCH.md)。

第 2.1、2.2 两处改动本身与 StudyCast 无关，已整理成可提给 UxPlay 上游的独立
补丁，材料见 [UPSTREAM_PR.md](UPSTREAM_PR.md)。

## 4. 已验证与未验证

已验证：

- 本机 iPad（`iPad13,16`）与 iPhone（`iPhone14,7`）经 AWDL 连接并正常出画面；
- **Apple Vision Pro（`RealityDevice14,1`）** 经 AWDL 连接并正常出画面
  （2026-08-12 补记，此前漏列；日志见
  `2026-07-31_14-31-46/1_Station_1.uxplay.log`，`Accepted IPv6 client on
  socket 25, port 7000` / `Remote: fe80::…%16`，解密失败 0）；
- **不属于本机账号的第三方 Mac** 经 AWDL 连接并成功投屏，此时网络侧的设备登记已被移除；
- 日志确认链路为 `fe80::...%awdl0`，媒体协议走 legacy 分支（`SETUP 1`），解密失败计数为 0；
- 双工位并发投屏正常。

未验证：

- 三工位同时投屏；
- 录制与剪辑功能在当前改动下的完整行为。

## 5. 判读日志

会话日志在 `~/Movies/StudyCast/Study/<时间戳>/<N>_<标签>.uxplay.log`。

| 现象 | 含义 |
|---|---|
| `Remote: fe80::...%16` | 走 AWDL（接口 16 通常是 `awdl0`，用 `ifconfig` 确认） |
| `Remote: 10.x` / 其他路由地址 | 走基础设施 Wi-Fi，不是点对点 |
| `SETUP 1` 出现 | 发送端使用 legacy ekey 路径，UxPlay 能解密 |
| `SETUP 1` 缺失 + 大量 `decryption of video packet failed` | 发送端走了 AP2 路径，说明接收端被识别为现代 Mac 接收器 |
| 列表可见但连接不上 | 优先检查 `SO_RECV_ANYIF` 是否生效 |

## 6. 已知未解决

- **GStreamer 崩溃（两种，均与 AWDL 无关）**：
  - 断开时：`GLib (gthread-posix.c): pthread_mutex_lock: Invalid argument.
    Aborting.`，出现在发送端断开后的清理路径，2026-07-30 与 07-31 各复现一次。
  - 窗口显示/缩放时：AppKit 断言
    `assertion failure: "!view->_descendantHasCachedVisibleRect"`，经
    `-[GstGLNSWindow resize:height:]` → `_show_window` →
    `gst_gl_invoke_on_main` 触发，SIGABRT，2026-08-12 复现一次（画面尚未显示
    即崩溃，相同参数立即重跑正常，判为间歇性）。

  两者都属既有缺陷、早于 `-p2p` 改动。teardown 那个于 2026-08-12 在真实
  StudyCast 会话中再次复现（发送端断开时接收端自行 abort）。

  **崩溃的后果已经大幅缓解，但崩溃本身仍未修复：**
  - 录像不再随崩溃丢失。UxPlay 的 mp4 管线改为分片写入
    （`mp4mux fragment-duration=2000 fragment-mode=first-moov-then-finalise`，
    见 `third_party/uxplay-patches/0006-*.patch`），录制过程中持续落盘，
    正常停止时仍收尾成常规 MP4。上述那次真实崩溃后文件立即可读：
    1,763,611 字节 / 43.1 秒 / 843 个视频包，并成功裁出 23 秒剪辑。
    **改动前同样的崩溃会留下 0 字节，整场尽失。**
  - 工位可单独重启而不波及其他工位，见 `Station.restartReceiver()`；
    每次启动使用独立 staging base，重启不会覆盖既有片段。

- ~~**跨片段剪辑偏移错误**~~（2026-08-12 已修）：一次 Projection 内若发送端
  断开重连、或接收端被重启，UxPlay 会产生多个录像片段。此前片段虽已全部保留，
  但 Record 标记的区间一律按最新片段计算偏移，早先片段中标记的区间会被静默
  裁错。现在每个片段在移动到输出目录前会记录自己的时间窗口（创建时间到最后
  写入时间），每个标记区间按其起点匹配所属片段，从该片段裁剪；匹配不到片段的
  区间不生成剪辑并明确报告，而不是裁出错误内容。此外接收端死亡时会就地闭合
  当前区间，避免区间跨越片段边界。
