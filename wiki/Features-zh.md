# 功能总览

> English: [Features](Features) / 日本語: [Features-ja](Features-ja) / 繁體中文 (本頁)

以下說明功能概念；已實作、建置驗證、硬體認證與不支援的區分，以 [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/zh/capability-matrix.md) 為準。

简要汇总各功能「能做什么」。用法见[住户使用指南](Usage-Residents-zh) /
[管理员指南](Usage-Admin-zh) / [访客体验](Usage-Visitors-zh)，机制见[架构](Architecture-zh)。

## 呼叫

门口机的大按钮（通用）或事由按钮 1 次点按即完成按铃。事件进入规则引擎，
執行規則配置的 action。
可按门、按事由、按时间段分支。→ [管理员指南](Usage-Admin-zh)

`purpose_first` 先選事由再 ring；`ring_then_purpose` 先 ring，再選擇或略過事由。訪客只可在 ringing
時 cancel，通話建立後應使用 End call/hangup。Web 手動接聽只由一個 `dialog_id` owner 持有；
recovery 在 origin 還原 ringing，而 in-call 僅由該 owner 還原。

## 事由按钮 (visit_purposes)

访问 / 快递 / 邮件 / 推销・收款 / 抄表・施工 / 其他 —— 默认 6 种，可自由编辑。
快递员点一下「快递」即完成按铃。事由会显示在室内机、TV、Telegram、HA、管理界面的
所有地方，也可以用作规则的分支条件 (`when.purposes`)。→ [访客体验](Usage-Visitors-zh)

## 访客语言切换

在门口机上显示语言按钮（日/英/中 —— 由 `ui.languages` 选择）。访客切换后
会以徽标传达到所有节点，**快捷回复的显示与朗读也会跟随访客的语言**。
无操作 60 秒（可配置）后自动恢复为日语。→ [访客体验](Usage-Visitors-zh)

## 对讲（三态）与应答接管

通过不经 Asterisk 的直连 SIP (UDP 47190)，提供 (1) 仅语音、(2) 门口影像 + 双向语音、
(3) 室内外双向影像（对称 MJPEG）三种形态。即使已经用电话接听，之后按室内机的「应答」
也能挂断电话腿并**接管**为室内对讲。PBX 宕机也照常运转。→ [架构](Architecture-zh)

## 监听（监视）

从室内机、Android TV 向门口机发起 `X-Doorbell-Mode: monitor` 的单向呼叫 ——
可以在不被察觉的情况下确认门口的声音和影像。来铃时 TV 会自动弹出全屏实时画面 + 监听。

## 快捷回复

「现在不在家」等预设短语（多语言、可自定义、带排序）可从室内机 / TV 遥控器 /
Telegram 内联按钮 / HA / 网页发送 → 在门口机大字显示 + 朗读。
朗读按 自定义语音（可按访客语言分别登记）→ 系统 TTS → 提示音 的顺序回退。

## 自动应答 (auto_reply)

作为规则的动作，即使没人应答按铃，门口机也会自动显示 + 朗读快捷回复。
经典用法是「如果是快递就自动播放『请放在门口』，并且不响电话」。→ [管理员指南](Usage-Admin-zh)

## 电话联动 (Asterisk + 光纤电话)

按铃时同时呼叫宅内内线和外出手机 (PSTN)。支持通话中的 DTMF 功能码
（*1 = 开锁等，动作可配置）。分配逻辑可在 dialplan 侧自由修改。
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md)

## 通知

- **Telegram**: 推送带照片 + 事由 + 访客语言徽标的按铃通知。内联按钮即刻回复。
- **Home Assistant** (MQTT Discovery): 门铃 event / 动体 / 设备在线 / 桥接存活 /
  紧急 / 访客语言 sensor 自动出现。附带 actionable 通知的片段。
- **室内门铃声**: 支持自定义音 (`asset:<sha256>`)。
- 对外发送只由 leader 节点执行，防止重复通知。

## SOS（紧急求助）

SOS active/clear 狀態會複製到所有 Core node，但 visual、sound、system notification、Web Push、
Telegram、MQTT 配送完全 rule-driven，也可設定零收件者。管理員開關
`emergency.web_active_page_alerts` 預設 true，所以即使零收件者或 Push-only rule，開啟中的 Web page
仍呈現 SOS。false 時，正向 matching `device_alert` 或已送達 Push 仍可呈現。Core `delivery_result` 是
dispatch attempt，client channel report 才是實際 presentation。raw-state 顯示期間，rule TTL 只結束
custom decoration/sound，安全的紅色 overlay 保留至 clear。Web page 把 `?group=` 保存值供 poll/Push
共用。explicit native-only target 不到 Web，Web-only target 不到 native shell；只有 legacy no-target
action 會到所有對象。完整 Push subscription 在 CRDT 中以 XChaCha20-Poly1305 seal，不出現在 plaintext config/export。
解除需要 kiosk PIN；不會自動呼叫警察、
消防。→ [设计理念](Design-Philosophy-zh)

## 动体检测

从门口机摄像头的帧总线检测动体，送入规则（例: 仅夜间 Telegram + HA）。
灵敏度、最小间隔可按设备分别调整。

## 影像 —— MJPEG 基调 + H.264 流畅档

默认是所有设备、所有浏览器都能显示的 MJPEG。拥有硬编的设备可用 `codec: auto/h264`
分发 HW 编码 fMP4 (`/stream.mp4`) —— 通话画质变得流畅，HA 侧也不再需要转码
(go2rtc `#video=copy`)。零订阅者时编码器停转，属于省电设计。→ [决策记录](Decisions-zh)

## HomeKit 联动

经由 go2rtc + HA 的 HomeKit Bridge，在 iPhone 的家庭 App 收到门铃通知和实时影像。
如果有家居中枢 (Apple TV / HomePod)，在外面也能查看。
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

## 主题推送・文案编辑・个性化

背景色 / 背景图片、文案 (i18n_overrides)、事由、快捷回复、自定义语音
从室内机或管理界面修改后，通过 CRDT 毫秒级同步到所有设备。还可以配置夜间模式
（减光 + 偏红）、屏保、防烧屏的 pixel shift。

每裝置 semantic size/color override 受 renderer manifest 約束。native client 公開 top-level
`ui_manifest`，配信中的 Core 另行公開 local `web_ui.manifest`。last-valid native peer contract 會永久
cache，`cached_contract:true` 的 configured offline device 可先驗證/queue，但仍需後續 apply report。
remote/offline Web manifest 未知時，Admin 不會從 native peer manifest 捏造 Web editor。

## 资产分发 (assets)

背景图片、自定义语音 (≤3MB) 由 sha256 台账管理，**在被引用的时刻各设备主动
预取** (mesh FETCH_BLOB) —— 播放、显示永远走本地文件，毫秒级响应。
管理界面会显示每个节点的缓存覆盖率。

## kiosk 防盗

- Windows: 替换 shell + watchdog 前台守卫（把 Update 弹窗压回去）+ 绘制数字键盘 PIN
- Android: Device Owner 完全固定 + 禁用 keyguard
- iOS: 监督模式 + Single App Mode（解除只能靠 Configurator + 监督证书）
- offline event 只有在 matching rule 與完成 commissioning 的 integration 選中時才會觸發
  Telegram/HA，不保證所有平台 30 秒內或必然送達。

## 网页面板（legacy 支持）

legacy web panel 在目標 Safari/裝置完成實機測試前屬 best-effort。`call.html` 需要 modern secure
context 與 Asterisk WebRTC。iPad 1 compatibility shell 可使用內建 mic/speaker，但沒有 camera；
須逐裝置 commissioning 並設定外部 camera/no-video profile。bounded RTSP/RTP-over-TCP H.264 ingest
與 Annex-B 轉送已通過 host/loopback test，但實際 IDR accept 前保持 degraded，且真實 camera iPad
qualification 尚未完成。另一項 bounded Android→Core fMP4→iPad 實機 smoke 已在 foreground renderer
確認 15–16 fps，但 crash 後 unattended foreground resume 仍未完成。
optional root helper 已實作並通過 host test；iOS 5 lane 有不會啟用 launchd 的可重現 staged DEB，但
實機 qualification 尚未完成。

## 目前 artifact gate

- Android API 19 正式 SKU allowlist 為空，supported SKU 是 0；CI artifact 是 debug-contract，不是可配送 release。
- tvOS 只有 real PJSIP 的 unsigned Debug simulator build；沒有 tracked Release/device artifact 或 Apple TV 實機證據。
- iOS 9 arm64 只有 unsigned device-link proof；正式 armv7 signing/hardware gate 尚未 commission。
- cross-platform conformance 是 golden behavior model + source-smoke contract，不代表所有 runtime artifact 都執行 trace。
- iPad 1 有 mic/speaker、沒有 camera，也不是 outdoor-rated；hardware、enclosure、audio、rollback gate 未完成。
- local 且未 push 的 `ios-legacy-0.2.0-final` tag 已存在，但此 working tree 的 `ios-compat` 尚未 tracked，
  fresh-clone/device/rollback gate 未完成；保留且不修改 `ios-legacy`。
