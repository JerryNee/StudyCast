# 无需网络登记的 AirPlay 发现（AWDL）

日期：2026-07-31  
适用：StudyCast + 相邻 UxPlay 工作树（分支 `codex/studycast-stable-audio-fix`）

## 1. 结论

StudyCast 现在通过 Apple 的点对点 Wi-Fi（AWDL）被发现和连接，**不依赖所在网络的任何配置或设备登记**。发送端与接收端直接建链，媒体不经过基础设施 Wi-Fi 的转发策略，因此也不受托管网络对 mDNS 的过滤或客户端隔离影响。

这取代了 `AIRPLAY_P2P_FEASIBILITY_2026-07-30.md` 中「必须依赖校园网 Bonjour/AirGroup、Guest 网络或自带路由器」的结论。

## 2. 让它成立的三处改动

全部在 UxPlay 侧，合计不到 40 行。缺任何一处都不成立。

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

## 3. 不要伪装成 Mac 接收器

存在一条看似更直接的路线：把接收端的 TXT 身份伪装成系统 Mac（`model=Mac15,6`、`srcvers=980.63.2`、完整 HomeKit 配对栈）。它**同样能拿到 AWDL**，但发送端会因此切换到 AirPlay 2 的媒体路径：不再发送 legacy `ekey`，改用一套未公开的密钥推导。结果是视频数据能送达接收端，但无法解密，画面全黑。

实测已确认 **Mac 身份不是 AWDL 的必要条件**：标准 UxPlay 身份同样能拿到点对点，并且走 UxPlay 本来就能解密的 legacy FairPlay 路径。

该路线保留为研究项，默认关闭，见 [AP2_MIRRORING_KEY_SEARCH.md](AP2_MIRRORING_KEY_SEARCH.md)。

## 4. 已验证与未验证

已验证：

- 本机 iPad（`iPad13,16`）与 iPhone（`iPhone14,7`）经 AWDL 连接并正常出画面；
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

- **GStreamer 断开时崩溃**：`GLib (gthread-posix.c): pthread_mutex_lock: Invalid argument. Aborting.`。出现在发送端断开后的清理路径，2026-07-30 与 07-31 各复现一次。属既有缺陷，早于本次改动，与 AWDL 无关。三工位场景下接收端进程死亡影响较大，建议单独排查。
- **跨片段剪辑偏移错误**：一次 Projection 内若发送端断开重连，UxPlay 会产生多个录像片段。片段现已全部保留，但 Record 标记的区间仍只按最新片段计算偏移，早先片段中标记的区间会裁错。
