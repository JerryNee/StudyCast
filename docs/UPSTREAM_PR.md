# 向 UxPlay 上游提交 `-p2p` 的准备材料

日期：2026-07-31  
状态：**未提交。** 分支和描述都已备好，等决定是否发出。

本文的目的是让任何人（包括另一个 agent）能独立完成提交，不需要回看对话记录。

## 1. 只提交一个补丁

`third_party/uxplay-patches/` 有 5 个补丁，**只有 0003 应该提给上游**。

| 补丁 | 提不提 | 原因 |
|---|---|---|
| 0001 连续 MP4 音频采集 | 否 | 为 StudyCast 的录制需求所做，改动了 `-mp4` 的行为语义，上游未必想要 |
| 0002 忽略 in-source 构建产物 | 否 | 本地构建习惯，与功能无关。**特意拆出来**，好让 0003 只碰源码 |
| **0003 `-p2p`** | **是** | 自包含、加的是正规选项、默认行为零变化、不含任何 StudyCast 私货 |
| 0004 mirror payload 异地解密 | 可选 | 独立的小修复，可作为第二个 PR 单独发；但它现在的提交信息引用了 0005，单独提要改措辞 |
| 0005 AP2 研究路径 | 否 | 功能不完整（视频解不开）、引入 libsodium 和 vendored pair_ap，且上游已把 AWDL/AP2 关成 `not planned` |

## 2. 生成 PR 分支

```sh
git clone https://github.com/<你的账号>/UxPlay /tmp/uxplay-pr
cd /tmp/uxplay-pr
git remote add upstream https://github.com/FDH2/UxPlay
git fetch upstream
git checkout -b p2p-discovery upstream/master
git am /path/to/StudyCast/third_party/uxplay-patches/0003-*.patch
```

补丁的基点是上游 `9c24ed264f91948e4a32a51c5f8ade3ece30e58c`。若上游已前进且 `git am` 冲突，用 `git am --3way`；冲突通常只会出现在 `uxplay.cpp` 的选项解析和用法文本处。

确认一下改动范围，应该只有 6 个源文件、没有别的：

```sh
git show --stat HEAD
```

## 3. PR 描述草稿

> **Title:** Add `-p2p`: advertise and accept AirPlay over Apple peer-to-peer (macOS)
>
> **Body:**
>
> UxPlay is currently only reachable through whatever network it shares with
> the client. On managed networks that is often nothing: mDNS gets filtered or
> proxied, and client isolation blocks the connection even when discovery
> works. That is the recurring situation in #234 and antimof#163, where the
> conclusion each time was that nothing could be done from the receiver side.
>
> There is something that can be done. Registering the service over AWDL in
> addition to the normal interfaces lets a client find and reach UxPlay
> directly, with no shared network and no cooperation from the network's
> operator.
>
> **Scope — please read this part.** This is *not* an implementation of
> Apple's peer-to-peer AirPlay handshake, which #472 correctly concluded is
> not feasible from public information. The media session here is the ordinary
> one UxPlay already implements; the only change is that the client can find
> the receiver over an AWDL link and open the connection across it. Nothing
> about pairing, FairPlay or the media protocol changes.
>
> **Two changes, and neither works without the other:**
>
> 1. Register with `kDNSServiceFlagsIncludeP2P | kDNSServiceFlagsIncludeAWDL`
>    on `kDNSServiceInterfaceIndexAny`. Pinning the registration to `awdl0`
>    instead hides the service from clients using other peer-to-peer
>    interfaces — which is why `IncludeP2P` alone looks like it does nothing.
>
> 2. Set `SO_RECV_ANYIF` on the listening sockets. A conventional BSD listener
>    silently drops packets delivered over AWDL, so without this the receiver
>    appears in the client's list but the server never sees the connection —
>    no bytes on the port, nothing logged.
>
> **On `SO_RECV_ANYIF`:** it is not in the public SDK headers; the value
> (`0x1104`) comes from XNU's private `socket.h`. That is why this is opt-in
> and macOS-only. I understand if that is a blocker — happy to guard it
> further or gate it behind a build option if you would prefer.
>
> **Default behaviour is unchanged.** Without `-p2p` the service still
> resolves to the host's own name. With it, to the randomized UUID name
> mDNSResponder publishes for peer-to-peer registrations (that name resolves
> over the AWDL link; it is Apple's normal privacy behaviour, not a fault).
>
> **Tested** on macOS 27 / Apple Silicon with iPadOS and iOS clients, and with
> a third-party Mac that had no prior relationship to the receiver's host or
> its network. Mirroring works over the AWDL link with the ordinary legacy
> FairPlay media path; verified in the logs by the connection's interface
> (`fe80::…%awdl0`) and by zero decryption failures.

## 4. 预期的反对意见与已准备的回答

| 可能的反对 | 回答 |
|---|---|
| 「AWDL 支持已经在 #472 里关成 not planned」 | 那个 issue 讨论的是复现 Apple 的点对点 **握手**。本 PR 不碰握手，只让服务在 AWDL 上可被发现和连接，媒体会话完全是 UxPlay 现有那套 |
| 「`SO_RECV_ANYIF` 是私有 API」 | 属实，这也是它 opt-in 且仅限 macOS 的原因。可以进一步加编译开关。没有它这个功能不成立——服务能广播但收不到包 |
| 「随机 UUID 主机名看起来像 bug」 | 那是 mDNSResponder 对点对点注册的既定行为，在 AWDL 链路上能正常解析。文档里已说明 |
| 「为什么要改 `dnssd_set_peer_to_peer` 去调 netutils」 | 两者缺一无用，分开设置只会制造「广播了但连不上」的半开状态。合并成单一入口也避免了给 `netutils.h` 加 `extern "C"` |
| 「Windows/Linux 怎么办」 | 该选项在非 macOS 上是空操作。AWDL 是 Apple 专有链路层 |

## 5. 不要在 PR 里出现的东西

- 任何 `StudyCast` 字样
- `UXPLAY_DISCOVERY_PROFILE` / `mac-p2p` 研究档案
- `ap2_capture` 及媒体密钥探测
- `.gitignore` 改动

若 0003 里混进了以上任何一项，说明补丁重新生成时出了问题，回到 §2 重来。

## 6. 证据出处

对话中的实测记录已归纳在 [AWDL_DISCOVERY.md](AWDL_DISCOVERY.md)。若维护者要求更具体的数据：

- 会话日志格式与判读方式：AWDL_DISCOVERY.md 第 5 节
- 「可见但连不上」对应 `SO_RECV_ANYIF` 缺失：AIRPLAY_P2P_FEASIBILITY_2026-07-30.md 第 5 节表格中「TCP 7000 累计收发 0 字节」那几行，是加该选项之前的实测
- 上游相关 issue：
  [#234](https://github.com/FDH2/UxPlay/issues/234)、
  [antimof#163](https://github.com/antimof/UxPlay/issues/163)、
  [#472](https://github.com/FDH2/UxPlay/issues/472)

## 7. 提交这一步

需要人来做：先有自己的 fork，再 push 分支、开 PR。上游仓库 `FDH2/UxPlay` 不是本项目的 remote，不要直接往那里 push。

`third_party/UxPlay` 只是文件，不是独立的 git 仓库，所以 PR 分支必须按 §2
另外 clone 一份来做。推送前确认 remote 指向的是**你自己的 fork**。
