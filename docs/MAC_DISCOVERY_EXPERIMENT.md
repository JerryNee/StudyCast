# Mac 风格 AirPlay 广告实验

日期：2026-07-30

> **2026-07-31：本实验已结束，结论为「不要这样做」。**
>
> 伪装成系统 Mac 确实能拿到 AWDL，但会让发送端切换到 AirPlay 2 媒体路径：
> 不再发送 legacy `ekey`，改用未公开的密钥推导，视频送达但无法解密。
>
> 实测确认 Mac 身份**不是** AWDL 的必要条件：标准 UxPlay 身份同样能拿到
> 点对点，且走可解密的 legacy 路径。现行方案见
> [AWDL_DISCOVERY.md](AWDL_DISCOVERY.md)；本文档所述档案仅保留为研究开关。

## 目的

判断 UIUC 网络或 visionOS 是否根据 Bonjour/DNS-SD 的 AirPlay 接收器属性筛选 UxPlay。

## 实验设计

StudyCast 的 `Mac test (1)` 开关默认开启。开始投屏接收后：

- `StudyCast-1` 设置子进程环境变量 `UXPLAY_DISCOVERY_PROFILE=mac`；
- `StudyCast-2` 和 `StudyCast-3` 保持标准 UxPlay 广告；
- 三个实例仍使用各自的名称、Device ID、公钥和端口。

该设计提供同一台 Mac、同一网络、同一时刻的直接 A/B 对照。

## 实验档案

`StudyCast-1` 的 AirPlay DNS-SD 记录已在本机验证为：

```text
deviceid=02:00:00:00:00:01
features=0x527FFEE6,0x0
pw=false
flags=0x204
acl=0
at=4
igl=0
gcgl=0
protovers=1.1
model=Mac15,6
srcvers=980.63.2
```

`features` 保留 UxPlay 真正实现的能力，没有复制系统 Mac 的完整 AirPlay 2 feature bitmap。这样可以降低“设备可见，但客户端因虚假能力选择不受支持的握手”的风险。

`StudyCast-2/3` 继续发布：

```text
flags=0x4
model=AppleTV3,2
srcvers=220.68
vv=2
```

## 结果判读

- 只有 `StudyCast-1` 出现：筛选与 DNS-SD 接收器档案有关，可以继续完善 Mac 兼容档案。
- 三个都不出现：仅修改 Bonjour/TXT 不足，优先考虑 Apple 私有邻近发现、校园网授权或 BLE beacon。
- 三个都出现：网络策略或缓存状态在测试期间发生了变化，需要重复测试。
- `StudyCast-1` 出现但无法连接：发现层伪装有效，但 HTTP `/info`、配对或 feature 协商仍不兼容。

## 回退

停止 Projection，关闭 `Mac test (1)`，再重新开始 Projection。三个接收端会全部恢复标准 UxPlay 广告。

## 实现位置

- StudyCast 启动与 UI：`Sources/AppModel.swift`、`Sources/ContentView.swift`、`Sources/Station.swift`、`Sources/UxPlayProcess.swift`
- UxPlay DNS-SD 档案：相邻 UxPlay 源码树中的 `lib/dns_sd/dns_sd.c` 和 `lib/mdnsd/dnssd_mdnsd.c`

