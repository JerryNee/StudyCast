# UxPlay #544 合并后端口测试交接

日期：2026-08-11
状态：**等待实测。计划于 2026-08-12 完成并在原 PR 追加回复。**

这份文件是给接手的 AI agent 或开发者看的。无需回读聊天记录；按本文执行即可。

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

### A. 固定非传统端口，对照组

```sh
cd "/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay"
./uxplay -n UxPlay-P2P-Fixed -p2p -pin 3939 -d -p 35000 2>&1 | tee /tmp/uxplay-p2p-fixed.log
```

从发送端选择 `UxPlay-P2P-Fixed`，输入 PIN `3939`，投屏至少 15 秒，然后停止 UxPlay。

### B. 完全省略 `-p`，实验组

```sh
cd "/Users/nijianwei/Desktop/Vision Pro/LPVT/UxPlay"
./uxplay -n UxPlay-P2P-Dynamic -p2p -pin 3939 -d 2>&1 | tee /tmp/uxplay-p2p-dynamic.log
```

从同一个发送端选择 `UxPlay-P2P-Dynamic`，输入相同 PIN，投屏至少 15 秒，然后停止 UxPlay。这里绝对不要添加任何形式的 `-p`。

## 4. 每组必须记录的结果

运行后分别提取：

```sh
rg "using network ports|Accepted IPv|Local :|Remote:|connection request|Begin streaming|decryption of video packet failed" /tmp/uxplay-p2p-fixed.log /tmp/uxplay-p2p-dynamic.log
```

记录以下信息：

1. UxPlay 打印的 UDP/TCP 端口。
2. 发送端是否能发现接收器。
3. 是否出现 `Accepted IPv6 client`。
4. `Remote:` 是否为 `fe80::...%N`，并用 `ifconfig awdl0` 确认 AWDL 正常。
5. 是否出现 `Begin streaming to GStreamer video pipeline`，画面是否持续至少 15 秒。
6. 发送端型号、macOS 防火墙状态，以及两组之间是否改变过 Wi-Fi、蓝牙、MDM 或系统 AirPlay Receiver 设置。

## 5. 如何判定

- A、B 都成功：`-p` 不是 AWDL 或 AirPlay 协议要求，只用于端口可预测性、防火墙配置等场景。
- A 成功、B 失败：先不要断言协议要求 `-p`。保留两份日志，检查动态端口是否正确进入 DNS-SD SRV、是否有防火墙拦截，以及连接是否到达监听 socket。
- A、B 都失败：测试环境本身没有复现既有成功条件，本次 A/B 无效，不能回复结论。
- B 成功、A 失败：大概率是固定端口冲突或本机环境问题，不是协议偏好动态端口。

## 6. GitHub 追加回复模板

只有完成测试后才使用，并把方括号内容换成真实结果：

```text
I ran the promised A/B test on the same host and sender.

Fixed-port control (`-p 35000`): [discovered/connected/streamed], accepted on TCP [port], remote `[fe80 address with scope]`.
Dynamic-port run (no `-p` at all): [discovered/connected/streamed], UxPlay selected TCP [ports], accepted on TCP [port], remote `[fe80 address with scope]`.

[Conclusion supported by the two runs.] The relevant log markers were `Accepted IPv6 client`, the `Remote: fe80::...%N` AWDL endpoint, and `Begin streaming to GStreamer video pipeline`.
```

追加到原 PR #544，不要新开 issue 或 PR。回复前先检查维护者在测试期间是否又补充了问题。
