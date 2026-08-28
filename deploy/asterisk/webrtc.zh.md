> 日文原文: webrtc.ja.md（以日文为准）

# 浏览器通话 (WebRTC) — Asterisk 侧配置（**可选功能**）

**定位**: 室内机 App（Windows/Android/iOS/TV）⇔ 门口机的对讲不经 Asterisk，
走直接 SIP（UDP 47190）— PBX 宕机对讲也能用。
本文档只有在「**想从浏览器（网页面板）通话**」时才需要的追加配置。
浏览器无法直接说 SIP/UDP，故用 Asterisk 作 WebRTC 网关。
不用网页通话就不需要这些配置。

网页面板的双向语音采用「浏览器 = Asterisk 的内线」方式（JsSIP + WebSocket）。
门口机侧无需改动 — 浏览器只是向门口机的内线（8001 等）正常发起呼叫。

## 1. 重要前提: 安全上下文

**浏览器的 getUserMedia（麦克风）只在 HTTPS 页面上工作**（localhost 除外）。
子机的管理/面板页面是明文 HTTP，所以需要下面二者之一:

- **推荐: 在 HA 主机上用 Caddy 等反向代理 + 内部 CA**
  `https://doorbell.home` → 代理到子机 47180，`wss://` → Asterisk 8089。
  在每台终端安装一次内部 CA。
- **简易: 按浏览器设置例外** — Chrome:
  在 `chrome://flags/#unsafely-treat-insecure-origin-as-secure` 里加入 `http://<子机IP>:47180`。
  如果只是家里固定的几台设备，这样也现实。

## 2. http.conf（Asterisk 内置 HTTP — WebSocket 用）

```ini
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088
; 使用 wss 时（由 Caddy 终结则不需要）:
;tlsenable=yes
;tlsbindaddr=0.0.0.0:8089
;tlscertfile=/etc/asterisk/keys/asterisk.pem
```

## 3. pjsip.conf 追加（ws transport + 浏览器内线模板）

```ini
[transport-ws]
type=transport
protocol=ws                 ; 由 Caddy/wss 终结则保持 ws; 直接 wss 则 protocol=wss
bind=0.0.0.0

[browser](!)
type=endpoint
context=from-internal
disallow=all
allow=opus,ulaw             ; 浏览器默认 opus。没有则 ulaw
webrtc=yes                  ; use_avpf/ice_support/dtls 全套的简写 (Asterisk 15+)
dtls_auto_generate_cert=yes ; 自动生成自签名 DTLS 证书
dtmf_mode=rfc4733

;---- 网页面板用内线（按终端台数增加）----
[260](browser)
auth=260
aors=260
callerid="Web Panel" <260>
[260](door-auth)
username=260
password=CHANGE_ME_260
[260](door-aor)
max_contacts=3              ; 允许多个浏览器同时登录
```

- `webrtc=yes` 需 Asterisk 15+（20 没问题）。opus 是 codec_opus 模块
  （标准捆绑，用 `module show like opus` 确认）。浏览器⇔门口机之间
  由 Asterisk 转码 opus⇔ulaw（服务器负担，1-2 路通话可忽略）。
- extensions.conf 无需改动 — 260 在 from-internal 里可以照常拨 `8001`
  （直呼门口机）或 `0…`（光电话出局）。

## 4. 验证

```
asterisk -rx "pjsip show transports"     ; ws 在列
asterisk -rx "pjsip show endpoint 260"
```
浏览器侧（面板的通话页面）用 JsSIP 向
`wss://<host>:8089/ws`（或经 Caddy 的 `wss://doorbell.home/asterisk/ws`）REGISTER。

## 5. 关于视频

- 浏览器←门口机的视频不用 WebRTC，而是并排显示 MJPEG（`/stream.mjpeg`）—
  无需 Asterisk 的视频配置。
- 浏览器→门口机（双向视频时）采用 getUserMedia → canvas → JPEG POST 到门口机的
  `/call-frame` 的方式（app 侧实现）。不做 WebRTC 视频协商。
