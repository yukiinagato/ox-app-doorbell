# 功能总览

> 日本語: [Features](Features) / English: [Features-en](Features-en)

简要汇总各功能「能做什么」。用法见[住户使用指南](Usage-Residents-zh) /
[管理员指南](Usage-Admin-zh) / [访客体验](Usage-Visitors-zh)，机制见[架构](Architecture-zh)。

## 呼叫

门口机的大按钮（通用）或事由按钮 1 次点按即完成按铃。事件进入规则引擎，
按配置并行执行 SIP 呼叫 / Telegram / HA 事件 / 室内门铃声 / 自动应答。
可按门、按事由、按时间段分支。→ [管理员指南](Usage-Admin-zh)

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

在室内机长按（默认 3 秒）→ 全节点警报 UI + 警笛 + Telegram 🚨 + MQTT（可联动 HA）。
解除需要 kiosk PIN。不会自动呼叫警察、消防。→ [设计理念](Design-Philosophy-zh)

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

## 资产分发 (assets)

背景图片、自定义语音 (≤3MB) 由 sha256 台账管理，**在被引用的时刻各设备主动
预取** (mesh FETCH_BLOB) —— 播放、显示永远走本地文件，毫秒级响应。
管理界面会显示每个节点的缓存覆盖率。

## kiosk 防盗

- Windows: 替换 shell + watchdog 前台守卫（把 Update 弹窗压回去）+ 绘制数字键盘 PIN
- Android: Device Owner 完全固定 + 禁用 keyguard
- iOS: 监督模式 + Single App Mode（解除只能靠 Configurator + 监督证书）
- 全平台: 离线 30 秒内通知 Telegram/HA（检测设备被盗、断线）

## 网页面板（legacy 支持）

`door.html`（按铃）/ `monitor.html`（接铃）在 iPad 1 的 iOS 5 Safari 上也能运行。
`call.html`（双向通话）需要现代浏览器 + Asterisk WebRTC 网关（可选功能）。
