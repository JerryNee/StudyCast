# UxPlay #544 合并后端口测试交接

日期：2026-08-11（结果于 2026-08-12 补记）
状态：**已完成。测试于 2026-08-12 执行，结果已追加至原 PR：[issuecomment-5268536294](https://github.com/FDH2/UxPlay/pull/544#issuecomment-5268536294)。**

这份文件是给接手的 AI agent 或开发者看的。无需回读聊天记录；按本文执行即可。
**第 3 节的测试已经跑完，不要重复执行**；结论见第 7 节。

## 1. 背景和待回答问题

上游 PR [FDH2/UxPlay#544](https://github.com/FDH2/UxPlay/pull/544) 已于 2026-08-09 合并。维护者随后问：

> does your code or the macOS specify legacy ports like 7000? do you think the protocol needs port 7000? can you test your working system to see if -p option is needed?

2026-08-11 已先回复有证据支持的部分：

- 回复链接：[issuecomment-5258689536](https://github.com/FDH2/UxPlay/pull/544#issuecomment-5258689536)
- 已确认 TCP 7000 不是协议要求。
- 尚未确认的是：**完全省略 `-p`、让 UxPlay 动态选择端口时，AWDL 投屏是否仍成功。** 这就是明天要做的测试。

## 2. 已有证据，不要重复争论

AWDL 补丁本身不选择端口。UxPlay 的裸 `-p` 才会选传统端口组；StudyCast 的普通多工位路径传入的是 `-p <basePort>`：

- `Sources/Station.swift`：`basePort = 35000 + index * 10`
- `Sources/UxPlayProcess.swift`：普通路径添加 `-p <basePort>`

已有成功日志：

```text
/Users/nijianwei/Movies/StudyCast/Study/2026-07-31_16-20-48/2_Station_2.uxplay.log
```

其中关键行是：

```text
using network ports UDP 35010 35011 35012 TCP 35010 35011 35012
Accepted IPv6 client on socket 25, port 35011
Remote: fe80::6044:00ff:fe63:df4d%16
connection request from Jerry‘s iPhone (iPhone14,7) ...
Begin streaming to GStreamer video pipeline
```

这证明发送端可以通过 AWDL 使用 35011，固定的 TCP 7000 并非必要。它**不能**证明 `-p` 选项本身可以省略，因为该次运行仍传入了 `-p 35010`。

## 3. 明天要做的 A/B 测试

使用同一台 Mac、同一个之前能成功的发送端、相同 Wi-Fi/蓝牙、macOS 防火墙和系统 AirPlay Receiver 设置。测试期间关闭 StudyCast 和其他 UxPlay 进程，避免名称或端口冲突。开始前记录防火墙状态：

```sh
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
```

可执行文件已经存在，并支持 `-p2p`：

```text
/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay/uxplay
```

### A. 固定非传统端口，前置对照组

```sh
cd "/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay"
./uxplay -n UxPlay-P2P-Fixed-Before -p2p -pin 3939 -d -p 35000 2>&1 | tee /tmp/uxplay-p2p-fixed-before.log
```

从发送端选择 `UxPlay-P2P-Fixed-Before`，输入 PIN `3939`，投屏至少 15 秒，然后停止 UxPlay。

### B. 完全省略 `-p`，连续五轮实验组

```sh
cd "/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay"
run=1 # 每轮依次改为 1、2、3、4、5
./uxplay -n "UxPlay-P2P-Dynamic-$run" -p2p -pin 3939 -d 2>&1 | tee "/tmp/uxplay-p2p-dynamic-$run.log"
```

每一轮都重新启动 UxPlay，从同一个发送端选择当轮名称，输入相同 PIN，投屏至少 15 秒，然后停止 UxPlay。这里绝对不要添加任何形式的 `-p`。五次独立启动会重新选择端口，可检验是否存在“某些随机端口碰巧成功”的情况。

### C. 固定非传统端口，后置对照组

```sh
cd "/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay"
./uxplay -n UxPlay-P2P-Fixed-After -p2p -pin 3939 -d -p 35000 2>&1 | tee /tmp/uxplay-p2p-fixed-after.log
```

用同一发送端再投屏至少 15 秒。前后两个固定端口对照都成功，才能排除测试过程中 AWDL、发送端或主机环境本身失效。

## 4. 每组必须记录的结果

运行后分别提取：

```sh
rg "using network ports|Accepted IPv|Local :|Remote:|connection request|Begin streaming|decryption of video packet failed" /tmp/uxplay-p2p-fixed-*.log /tmp/uxplay-p2p-dynamic-*.log
```

记录以下信息：

1. UxPlay 打印的 UDP/TCP 端口；五轮动态测试分别记录，不能只保留成功轮次。
2. 发送端是否能发现接收器。
3. 是否出现 `Accepted IPv6 client`。
4. `Remote:` 是否为 `fe80::...%N`，并用 `ifconfig awdl0` 确认 AWDL 正常。
5. 是否出现 `Begin streaming to GStreamer video pipeline`，画面是否持续至少 15 秒。
6. 发送端型号、macOS 防火墙状态，以及各轮之间是否改变过 Wi-Fi、蓝牙、MDM 或系统 AirPlay Receiver 设置。

一次动态端口成功足以证明“`-p` 并非建立 AWDL 会话的绝对前提”，但不能证明省略 `-p` 后足够稳定。对可靠性的结论必须报告成功次数，例如 `5/5`，不能只写“works”。

## 5. 如何判定

- 两个固定端口对照都成功，动态端口 `5/5` 成功：有力支持 `-p` 不是 AWDL 或 AirPlay 协议要求，在本测试环境中也未观察到随机端口不稳定；它主要用于端口可预测性和防火墙配置。
- 两个对照成功，动态端口有成功也有失败：可以说 `-p` 不是绝对前提，但不能说省略后可靠。保留全部日志，检查失败轮次的 DNS-SD SRV、端口过滤、服务发现缓存和监听 socket。
- 两个对照成功，动态端口 `0/5`：先不要断言协议要求 `-p`；更可能是动态端口发布、缓存或防火墙问题，需要继续定位。
- 任一固定端口对照失败：测试环境没有持续复现既有成功条件，本次可靠性比较无效。
- 动态端口成功而两个固定对照失败：大概率是固定端口冲突或本机环境问题，不是协议偏好动态端口。

## 6. GitHub 追加回复模板

只有完成测试后才使用，并把方括号内容换成真实结果：

```text
I ran the promised repeated A/B test on the same host and sender.

Fixed-port controls before and after (`-p 35000`): [results], accepted on TCP [ports], remote `[fe80 addresses with scope]`.
Dynamic-port runs (no `-p` at all): [N/5] discovered, connected and streamed. UxPlay selected TCP [port sets]; successful accepts used TCP [ports], remote `[fe80 addresses with scope]`.

[Conclusion supported by all runs.] The relevant log markers were `Accepted IPv6 client`, the `Remote: fe80::...%N` AWDL endpoint, and `Begin streaming to GStreamer video pipeline`.
```

追加到原 PR #544，不要新开 issue 或 PR。回复前先检查维护者在测试期间是否又补充了问题。

## 7. 实测结果（2026-08-12）

发送端全程为同一台 iPad Air（`iPad13,16`）。主机防火墙 `State = 0`（disabled），
Wi-Fi、蓝牙、系统 AirPlay Receiver 设置（`AirplayReceiverEnabled = 1`、
`AirplayReceiverAdvertising = 3`）全程未变。七轮均出现 `Begin streaming to
GStreamer video pipeline`，`decryption of video packet failed` 计数均为 0，
远端均为 `fe80::…%16`（该主机 `awdl0` 的 `scopeid 0x10`）。

| 轮次 | 端口 | Accepted | 结果 |
|---|---|---|---|
| A 前置对照 `-p 35000` | UDP/TCP 35000 35001 35002 | TCP 35001 | 成功 |
| B1 动态 | TCP 54762 | TCP 54762 | 成功 |
| B2 动态 | TCP 54849 | TCP 54849 | 成功 |
| B3 动态 | TCP 55037 | TCP 55037 | 成功 |
| B4 动态 | TCP 55144 | TCP 55144 | 成功 |
| B5 动态 | TCP 55212 | TCP 55212 | 成功 |
| C 后置对照 `-p 35000` | UDP/TCP 35000 35001 35002 | TCP 35001 | 成功（第 2 次） |

**动态端口 5/5。** 按第 5 节判定，落在第一档：有力支持 `-p` 不是 AWDL 或 AirPlay
协议的要求，其作用是端口可预测性与防火墙配置。

两个实操注意点，供以后复跑参考：

- **动态端口模式下 UxPlay 不打印 `using network ports`**（该行仅在 `-p` 设置了
  `udp[0]` 时输出）。每轮端口需从监听 socket 取：
  `lsof -nP -p <pid> | grep -i listen`。
- **C 轮第一次在视频窗口显示前 `SIGABRT` 崩溃**，日志留档于
  `/tmp/uxplay-p2p-fixed-after-attempt1-crashed.log`。崩溃点是 AppKit 断言
  `assertion failure: "!view->_descendantHasCachedVisibleRect"`，经
  `-[GstGLNSWindow resize:height:]` → `_show_window` → `gst_gl_invoke_on_main`
  触发，属渲染侧 GStreamer-on-macOS 缺陷，**与第 6 节记录的 teardown 阶段
  `pthread_mutex_lock` 崩溃不是同一个**。相同参数立即重跑即正常，故判为间歇性，
  与发现、AWDL、端口选择无关。已在 PR 回复中单独说明并提出可另开 issue。

日志留档：`/tmp/uxplay-p2p-fixed-before.log`、`/tmp/uxplay-p2p-dynamic-{1..5}.log`、
`/tmp/uxplay-p2p-fixed-after.log`、`/tmp/uxplay-p2p-fixed-after-attempt1-crashed.log`。
`/tmp` 会被系统清理，长期保留需另行归档。
