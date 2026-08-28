> 日文原文: ../ja/overview.md（以日文为准）

# 系统全貌（功能与架构总览）

面向自家住宅（多栋楼、多个玄关、同一 LAN）的门铃对讲系统。将旧款、低配置设备
再利用为门口机/室内机。**无服务器自愈** — P2P mesh 是唯一事实源，即使 HA/Asterisk
宕机，门铃本体、对讲、通知也会继续工作。

## 节点角色

| role | 设备示例 | 主要功能 |
|---|---|---|
| door_station（门口机） | 固定在玄关的 Toughpad(Win) / Android / iOS | 呼叫按钮、前置摄像头、麦克风/扬声器、kiosk |
| indoor_panel（室内机） | 室内的平板/PC/手机 | 来铃显示、应答/快捷回复、监视、SOS |
| indoor_panel + tv:true | Android TV | 来铃时全屏直播+直接监听、D-pad 应答 |
| (Web) door.html/monitor.html/call.html | 浏览器（含 iPad 1） | 网页版门口机/接铃/通话 |

所有节点搭载共享 C++ 核心（doorbell-core），通过 mesh 对等互联。

## 主要功能地图

- **呼叫**: 门口按钮（通用 或 按事由一键呼叫）→ 规则引擎 → SIP 呼叫 / 门铃声 /
  Telegram / HA / 自动应答。访客可切换语言，可选择事由（访问/快递/…）。
- **对讲**（不经 Asterisk 的直接 SIP，端口 47190）: 纯语音 / 门口视频+双向语音 /
  室内外双向视频（对称 MJPEG）。支持监听（单向）和应答接管（抢断电话腿在室内应答）。
  PBX 故障时也可用。仅浏览器通话经由 Asterisk WebRTC 网关（可选）。
- **电话联动**（Asterisk + 光电话/ひかり電話）: 按铃时同时呼叫内线+外出手机（PSTN），
  通话中用 DTMF 功能码开锁等。参见 deploy/asterisk/。
- **通知**: Telegram（照片+内联按钮快捷回复）/ HA（MQTT Discovery: 门铃 event、
  移动侦测、设备离线、桥接存活、紧急）/ 室内门铃声。仅 leader 节点对外发送（防重复）。
- **视频**: 默认 MJPEG（全设备、全浏览器）。h264 档（Phase 6）用硬件编码 fMP4 →
  流畅的通话画质、HA 无需转码。经 go2rtc→HomeKit 在 Apple 家庭 App 收门铃通知+直播。
- **快捷回复/留守应答**: 从室内/Telegram/HA/网页发送预设短语（多语言、可自定义）→
  门口机大字显示+朗读（系统 TTS 或自定义语音）。跟随访客语言。
- **紧急 SOS**: 室内长按 → 全节点警报+警笛+Telegram🚨+MQTT（HA 联动）。
  不会自动呼叫警察/消防。
- **个性化（推送）**: 背景色/图片、文案、事由、语言、语音可从室内/管理页面修改 → 通过 CRDT
  毫秒级同步。图片/语音会主动预取到各门口机（assets 台账）以便即时响应。
- **防盗/kiosk**: 退出需绘制数字键盘 PIN，替换 shell 自启动，watchdog 前台守卫
  （把 Windows Update 弹窗等顶回去），离线报警，Android 用 Device Owner 锁定。

## 各平台支持表

| 功能 | Windows(WPF) | Android | iOS | Web |
|---|---|---|---|---|
| 门口机完整功能 | ✅ | ✅ | ✅ | door.html（无语音） |
| 室内对讲 | ✅ | ✅ | ✅ | call.html（现代浏览器） |
| TV 监视 | — | ✅(TV) | AppleTV=HomeKit / tvOS app=✅（仅视频 — SIP 监听为 TODO） | — |
| kiosk 加固 | 替换 shell+守卫+数字键盘 | Device Owner+守卫 | 受监督 SAM | — |
| 防锁屏 | SetThreadExecutionState | 禁用 keyguard+STAY_ON | isIdleTimerDisabled | — |
| 旧机下限 | Win7 SP1 | 5.0 (4.4 legacy) | 12 (9 legacy)，越狱后 iPad 1/iOS5.1.1 也是原生节点 | iOS5 Safari |

> **iPad 1 (A1219, iOS5.1.1) 越狱原生节点**: 把它越狱并装上自行构建的原生 app，就成为搭载
> 完整 C++ 核心的一等节点 —— 查看门口视频、听声音、快捷回复、开锁，接外麦还能对讲。硬件上限:
> 没有摄像头=无法发送自己的视频，没有内置麦克风=不接外麦时仅收听。步骤见
> [deploy/provision/ios/ipad1-jailbreak.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.md)。
> 不越狱时，Web 版 (door.html/monitor.html) 可作 best-effort 使用。

## 仓库结构 & 构建

- 核心/测试: `cmake -S core -B build && cmake --build build && ./build/doorbell_tests`
- 主机模拟实机: `./build/doorbell_host --help`（在 Mac/Linux 上唤起子机）
- 各平台 App 由 GitHub Actions（`.github/workflows/build.yml`）CI 构建 →
  Windows/Android 产物可从 Artifacts 下载。
- iOS/tvOS: `xcodebuild -project ios/Doorbell.xcodeproj -scheme Doorbell|DoorbellTV`
  （core 由 run-script 用 CMake 自动构建。SIP 需先执行 `tools/build_pjsip_ios.sh`。
  签名/kiosk/分发见 deploy/provision/ios/provision.zh.md）
- 开发用套件: `deploy/dev/{asterisk,mosquitto}/docker-compose.yml`

## 配置 = 单一 CRDT

全部配置为 LWW-Map CRDT（docs/zh/config-schema.md 为正准）。通过管理页面（任意节点的
`http://<ip>:47180/admin/`）或 API 写入即在毫秒级传播到整个 fleet。事实源是分布式的 —
只要有 1 台存活，配置就能恢复。
