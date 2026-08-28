> 日文原文: README.ja.md（以日文为准）

# Asterisk 侧设置（参考配置）

本目录是给用户自行管理的 Asterisk 的**参考配置**。app 侧只知道
「SIP 服务器/账号/呼叫目标分机」— 分配（响谁的铃、夜间怎么处理、
是否出局到手机）全部可以在 dialplan 里自由改。

## 架构

```
[門口機 8001/8002] --SIP--> [Asterisk] --内線REGISTER--> [ひかり電話 HGW] --> NTT網 --> 携帯(PSTN)
                               |--> [内線話機 201], [スマホSIP 202 (VPN)]
按鈴: 門口機 → 600/601   逆呼び(モニタ): 内線 → 8001..
```

## 步骤

1. HGW（PR-400/500/RX-600 系）管理页面 →「電話設定 > 内線設定」启用 1 个内线号码
   （例: 内线 4）。记下用户名/密码，抄进 `pjsip.conf` 的 `hgw-*`。
   不需要 MAC 认证或伪装 — 用普通的 SIP REGISTER 即可注册。
2. 导入 `pjsip.conf` / `extensions.conf`，改写 `CHANGE_ME_*` 和 `MOBILE`，
   然后 `pjsip reload; dialplan reload`。
3. 在门口机 app 的管理页面配置 SIP 服务器 IP、账号 (8001..)、呼叫目标分机 (600/601)。
4. 验证: `pjsip show registrations`（HGW 注册 OK）、`pjsip show endpoints`（门口机 8001 Avail）。
   门口机按铃 → 内线 + 手机响铃 → 接听后双向通话、确认回声情况。

## 注意事项（依机型而异）

- **HGW 内线的并发通话数很少**（通常 2）。多个玄关同时按铃可能争用手机出局 —
  app 侧由 leader 仲裁把外呼串行化，dialplan 侧也可以用 Queue 等控制。
- **DTMF**: PSTN→HGW 这条腿多为 inband。通话中的功能码（开锁 *1 等）能否传到门口机
  需要实测。传不到时: 保持 `[hgw] dtmf_mode=inband` 交给 Asterisk 的 DSP 检测
  （当前配置），或者改成 rfc4733 试试。门口机侧只支持接收 RFC2833。
- 来电号码显示、国际/长途前缀遵循 HGW 的拨号规则（与用话机拨号的格式相同）。
- HGW 重启后的恢复依赖 `retry_interval=60`。长期 UNREACHABLE 时检查 HGW 侧配置。
- 夜间分支（extensions.conf 的 GotoIfTime）以 **Asterisk 服务器的时钟** 判定。
  与 app 侧的 quiet_hours（抑制门铃声）互相独立 — 管理页面的文档中也有同样说明。

## SIP 视频（Phase 6）

在 Tier A 门口机的 endpoint 追加 `allow=ulaw,h264` + `max_video_streams=1`。
Asterisk **不转码**视频（passthrough）— 接收侧客户端（Groundwire/Linphone）也要
统一为 H.264（baseline, packetization-mode=1）。PSTN 腿仅语音，可共存。
