# 决策记录（ADR 风格）

> English: [Decisions](Decisions) / 日本語: [Decisions-ja](Decisions-ja) / 繁體中文 (本頁)

以「背景 → 选项 → 决定 → 理由」的形式记录主要的设计判断。
理念层面的内容见[设计理念](Design-Philosophy-zh)，实现见[架构](Architecture-zh)。

## D1: 影像采用 MJPEG 基调 + H.264 档的双层

- **背景**: 设备横跨 Win7 Toughpad 到最新 iPhone。单一编解码器无法兼顾。
- **选项**: (a) 全部 MJPEG、(b) 全部 H.264、(c) 双层。
- **決定**: (c)。MJPEG (`/stream.mjpeg`) 是 compatibility baseline；只有實測 hardware path healthy 的
  device 可 publish HW-encoded fMP4 (`/stream.mp4`)。client 只在 exact renderer/source commissioning 後
  claim 該 path。iOS 5 shell direct playback HTTP(S) MJPEG/snapshot；JPEG 留在 local，不 forward 到 Core。
- **理由**: MJPEG 適合舊 CPU，但 compatibility 是逐 client implementation/test 結果，不是 universal
  promise。qualified H.264 可用 go2rtc `#video=copy` 避免 HA transcoding。codec health 失敗時 `auto`
  fallback 至 MJPEG；Android API 19 目前正式 supported SKU 是 0。

## D2: 站间对讲用直连 SIP（不依赖 PBX）

- **背景**: 起初对讲也是经 Asterisk 的设计。但 PBX 会成为单点故障。
- **选项**: (a) 统一走 Asterisk、(b) 自有协议、(c) 标准 SIP 的直接呼叫。
- **决定**: (c)。各子机固定监听 UDP 47190，用 `X-Doorbell-Mode` 头
  区分 answer/monitor。对方 IP 从 mesh 的成员名册解析（仅限成员）。
- **理由**: PBX 故障时对讲、监听依然存活（自愈方针）。因为仍是 SIP，PJSIP 的
  实现可与电话腿共用，避免发明自有协议。也不需要改 dialplan。
  Asterisk 的职责被纯化为「通往电话网的腿」这一条。

## D3: 在外视频通话不采用 Telegram 通话、FaceTime

- **背景**: 想从外面与门口「视频通话」（计划书 §17 调研）。
- **选项**: (a) Telegram video call、(b) FaceTime、(c) HomeKit 远程观看 + PSTN 语音、
  (d) VPN + 自家栈、(e) Telegram video note（短视频）。
- **决定**: (c) 为标准，(d) 面向高级用户，(e) 为辅助。**(a)(b) 不采用**。
- **理由**: Telegram 的通话 API 不对 bot 开放，做不出自动应答的门口机。
  FaceTime 仅限 Apple 设备，且毫无自动化 API，在 kiosk 设备上
  无人应答无法成立。HomeKit（影像）+ 光纤电话（语音）的组合
  只用既有的成熟通道就满足了「能看能说」。架起 VPN 则自家 UI 的全部功能
  都可原样使用。

## D4: 不在 HomeKit 上搭载对讲（双向语音）

- **背景**: 在家庭 App 能收通知、看直播，却不能用应答按钮说话。
- **选项**: (a) 作为 HomeKit Doorbell 实现到双向语音、(b) 仅观看。
- **决定**: (b)。HomeKit 限定为「通知 + 实时影像」，语音应答用电话 (PSTN) 或
  自家应用进行。
- **理由**: 经 HA 的 HomeKit Bridge 时双向语音流的处理有制约，
  无法保证稳定的对讲品质。与其增加一个不稳定的对讲，不如把语音托付给
  确实能接通的电话腿，更符合「宁重勿漏」。

## D5: 不增加依赖 —— 自制 fMP4、自制 MQTT 客户端

- **背景**: fMP4 muxer 也好 MQTT 客户端也好，都有现成库。
- **选项**: (a) 链接 ffmpeg/libmosquitto 等、(b) 自制必要最小限。
- **决定**: (b)。fMP4 是只做「把 H.264 AnnexB 装箱」的自制 muxer，MQTT 是
  仅 3.1.1 QoS0 的自制客户端 (`core/src/bridge/mqtt_client.cpp`)。
- **理由**: 目标横跨 Win7 x86 到 iOS —— 依赖越多，旧平台的构建和分发
  越容易坏。用到的功能只是规范的极薄一层切面，自制反而在
  测试、移植、长期维护上更轻。只有 TLS 委托给平台的框架 (SPI `https_request`)，
  避免自制加密。

## D6: iOS 分发采用 Ad Hoc → App Store（分阶段）

- **背景**: 明明只是分发给家里的少数几台，iOS 却有签名这堵墙。
- **选项**: (a) 免费团队 7 天签名、(b) Ad Hoc、(c) App Store (unlisted)、(d) ABM 定制 App。
- **决定**: 先 (b) Ad Hoc（UDID 登记 + 每年重签 1 次）。永久化计划在 Phase 7 做 (c)。
- **理由**: (a) 每周重签，不适合常设运行。(b) 每年一次仪式即可，靠应用内的
  到期显示和 Telegram 的提前 30 天警告防止遗忘。等台数和运维定型后
  上架 App Store (unlisted)，彻底消灭重签，才是终点。

## D7: 只有网页通话用 Asterisk WebRTC 网关（可选功能）

- **背景**: 浏览器不能直接说 SIP/UDP。
- **决定**: 原生设备的对讲由 D2 的直连完结，**只在想用浏览器通话时**
  才把 Asterisk 用作 WebRTC (JsSIP + WebSocket) 网关。不用就无需配置。
  浏览器→门口机的影像也不走 WebRTC 协商，而是 canvas→JPEG POST 的成熟老办法。
- **理由**: 不把 WebRTC 的复杂性 (ICE/DTLS/SFU) 带进核心必经路径。
  详情: [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)。

## D8: 文案用单一 YAML → 生成各平台格式

- **背景**: resx (WPF) / strings.xml (Android) / Swift，每个平台文案格式都不同。
- **决定**: 以 [i18n/strings.yaml](https://github.com/yukiinagato/ox-app-doorbell/blob/main/i18n/strings.yaml)
  （ja 原文 + en/zh）为单一来源，由 `tools/gen_i18n.py` 生成各格式。运行时的
  覆盖 (i18n_overrides) 用同一套 key 体系放进 CRDT。
- **理由**: 三语言 × 多平台的文案靠手工同步必然崩坏。生成物带禁止编辑
  头部并纳入追踪，key 的重复、缺失会在 CI 中暴露（开发史上留有那次修复提交——
  不在 [FAQ](FAQ-zh)，请查 git log）。
