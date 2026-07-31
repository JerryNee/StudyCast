# AP2 镜像媒体密钥离线搜索

日期：2026-07-31
对象：StudyCast `codex/studycast-stable-audio-fix`，相邻 UxPlay 工作树同分支

> **状态：已封存，非交付路径。**
>
> 本文档描述的是「把接收端伪装成系统 Mac」这条路线上的遗留问题。该路线已
> 被放弃——实测确认 Mac 身份不是拿到 AWDL 的必要条件，标准 UxPlay 身份同样
> 能建立点对点链路，且走的是可解密的 legacy FairPlay 路径。
> 现行方案见 [AWDL_DISCOVERY.md](AWDL_DISCOVERY.md)。
>
> 以下内容保留，因为采集与离线搜索工具仍然可用：若将来需要与真正的
> AirPlay 2 发送端互操作（例如 Apple 停止支持 legacy 路径），可以直接接着做，
> 不必从头再来。启用方式是打开 StudyCast 的 `AP2 research mode (1)` 开关。

## 1. 当前实际进度

`docs/AIRPLAY_P2P_FEASIBILITY_2026-07-30.md` 写于「AWDL 上可见但 TCP 7000
始终 0 字节」的阶段。此后 UxPlay 工作树的改动已经推翻了那一条结论。

2026-07-30 18:30 的会话日志
（`~/Movies/StudyCast/Study/2026-07-30_18-30-57/1_Station_1.uxplay.log`）
显示，发送端（`iPad13,16`，iOS 18.7.8，`AirPlay/870.14.1`）完成了完整的
接收流程：

| 阶段 | 结果 |
|---|---|
| AWDL 上被发现并选中 | 成功 |
| 通过 IPv6 链路本地地址连上 TCP 7000 | 成功（`fe80::9c14:76ff:fe6a:928f%16`） |
| HomeKit `/pair-setup`（normal，非 transient） | 成功 |
| HomeKit `/pair-verify` | 成功，建立加密控制通道 |
| `/fp-setup` 完整 FairPlay 握手（mode 3，164 字节 keymsg） | 成功 |
| 初始 `SETUP`（`isScreenMirroringSession=true`） | 成功，事件通道连通 |
| `RECORD` | 成功 |
| type-110 流 `SETUP` | 成功，镜像传输就绪 |
| 未加密的 codec/SPS/PPS 包 | 成功解析（1554x1080 h264） |
| 加密视频包解密 | **失败** |

也就是说，剩下的唯一障碍是 AP2 镜像视频流的 AES 媒体密钥推导。发现、
准入、配对、FairPlay、传输、封装全部已经打通。

## 2. 问题的确切形状

AP2 发送端完成 FairPlay 握手，但在任何 `SETUP` 里都**不发送** legacy 的
`ekey`/`eiv`。UxPlay 传统路径依赖它们：

```
aeskey  = fairplay_decrypt(ekey)                        // 16 字节
aeskey  = SHA512(aeskey || ecdh_secret)[0:16]           // 有 pair-verify 时
key     = SHA512("AirPlayStreamKey" + streamConnectionID || aeskey)[0:16]
iv      = SHA512("AirPlayStreamIV"  + streamConnectionID || aeskey)[0:16]
AES-128-CTR
```

没有 `ekey` 时，「媒体种子」从哪来是未公开的。可用的会话材料只有：

- FairPlay session key（`playfair` 的 sapKey，16 字节）；
- FairPlay keymsg（164 字节）；
- HomeKit pair-verify 的 X25519 shared secret（32 字节）；
- 各 HKDF 通道派生密钥；
- `streamConnectionID`。

## 3. 为什么改成离线搜索

之前每验证一种推导都要重新做一次真机投屏。这既慢又不可复现。

现在改为：**一次真机会话产出一份可以无限次离线重放的样本**。判定标准是
自明的——正确解密的镜像负载会解析成一串「4 字节大端长度 + NAL unit」，
错误密钥几乎不可能碰巧满足。

### 3.1 采集端

`UXPLAY_AP2_CAPTURE` 指向一个文件时，UxPlay 会写入：

- `fairplay_session_key`、`fairplay_keymsg`
- `hkp_shared_secret`
- `hkp_ch{0..5}_write` / `hkp_ch{0..5}_read`
- `stream_connection_id`
- `packet0..packet7`：**未解密**的原始视频负载

实现见 `lib/ap2_capture.{c,h}`，调用点在 `lib/raop_handlers.h`（会话材料）
和 `lib/raop_rtp_mirror.c`（`streamConnectionID` 与密文包）。

StudyCast 打开 `Experimental Mac bridge (1)` 时自动设置该变量，采集文件与
`.uxplay.log` 一起落到会话目录，后缀 `.ap2capture`。

### 3.2 搜索端

```bash
python3 scripts/ap2_key_search.py ~/Movies/StudyCast/Study/<会话>/1_Station_1.ap2capture
```

脚本无外部依赖（自带 AES-128 与 FIPS-197 自检），当前枚举约 490 种推导：

- 各材料直接作为种子，及其 SHA512 的 16/32/64 字节截断；
- `SHA512(fp_key || hkp)` 与 `SHA512(hkp || fp_key)` —— 与 legacy 的
  「eaes」形状同构，是最强假设；
- 以 `hkp` 为 IKM 的 HKDF-SHA512，遍历 salt/info 组合，含 pair_ap 里
  记录的「salt 后接 64 位 seed」动态形式（用 `streamConnectionID`）；
- 绕过 `AirPlayStream*` 哈希、直接当作 (key, iv) 使用的材料。

先用第一个 AES 块做廉价筛选，幸存者再对全部包做完整校验。整份采集只需
零点几秒即可跑完，新增猜测直接改 `candidate_seeds()` / `candidate_key_ivs()`
重跑，**不需要再碰设备**。

工具本身已用合成样本端到端验证：注入 `SHA512(fp_key||hkp)[:16]` 作为真值，
脚本在 491 个候选中唯一命中。

### 3.3 在线兜底

`lib/raop_rtp_mirror.c` 里 codex 写的多候选并行探测仍然保留并已构建
（`raop_rtp_mirror_add_aes_candidate` + `raop_rtp_mirror_enable_aes_probe`，
约 39 个候选）。它在会话中就地尝试，命中会打印
`HomeKit/AP2 media key selected: <名称>`。这条路径尚未经过真机验证——
它是在 2026-07-30 23:16 之后写的，晚于最后一次实测。

## 4. 下一步

1. 用 iPad（比 Vision Pro 迭代快，且已证明走同一条 AWDL 路径）跑一次投屏，
   开启 `Experimental Mac bridge (1)`。
2. 检查日志里是否出现 `HomeKit/AP2 media key selected` —— 若出现，在线探测
   已经命中，把该推导固化为默认即可。
3. 否则用产出的 `.ap2capture` 跑离线搜索，并按需扩充候选空间。
4. 找到推导后：固化到 `raop_handler_setup` 的 hkp 分支，移除探测与采集，
   再验证多接收端并发。

## 5. 尚未验证的风险

- 若 AP2 镜像视频改用 ChaCha20-Poly1305 而非 AES-CTR，则任何 AES 候选都不会
  命中。采集文件同样支持验证这一点：届时密文长度与 NAL 结构的关系会暴露
  额外的认证标签。
- 本路线仍然依赖 AWDL/点对点，与校园网 Bonjour 策略无关；
  `docs/AIRPLAY_P2P_FEASIBILITY_2026-07-30.md` 第 7 节的产品决策不受影响。
