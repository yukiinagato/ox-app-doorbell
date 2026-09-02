# 功能與發佈狀態矩陣

本頁是平台支援聲明的依據。原始碼中存在處理路徑，不代表裝置或發佈成品已可投入正式環境。

## 狀態定義

| 狀態 | 意義 |
|---|---|
| 已實作 | 目前原始碼有該路徑，並有相關自動契約測試。 |
| 建置已驗證 | 該目標成品通過建置、ABI、相依性與封裝 gate。 |
| 硬體已認證 | 已記錄的裝置、OS、韌體組合通過 commissioning 與 soak。 |
| 不支援 | 路徑不存在、刻意停用，或 client 不得宣告該 capability。 |

## 目前狀態

| 對象 | 狀態 | 證據與限制 |
|---|---|---|
| core mesh/CRDT/API/event/rule/call lifecycle、MJPEG/fMP4、ABI v2 | 已實作 | `call_answered`/`call_ended` 受 call ID 約束；有 core tests 與公開 ABI。 |
| 發佈版 SIP | 有條件 | 成品必須回報 `pjsip`；`stub` 僅供開發/顯示，不支援通話。 |
| Android API 21+ | 已實作，有建置 lane | modern tier/NDK r27；不代表所有硬體已認證。 |
| Android modern critical-memory recovery | bounded 實機 smoke 通過；不是 hardware certification | moto g64y 5G/API 34 收到真實 `RUNNING_CRITICAL` trim 後維持同一 process/foreground Activity，記錄 encoder release，30 秒 protection window 後重建 `c2.mtk.avc.encoder` 並提供有效 640×360 fMP4。[2026-08-31 evidence](../evidence/android-modern-memory-pressure-smoke-2026-08-31.md)。OOM kill、in-call audio、power、thermal、soak 仍未驗證。 |
| Android API 19 armv7/NEON | 已實作且有 lane；supported SKU 為 0 | qualification list 為空。exact fingerprint/evidence artifact 通過 codec/recovery/thermal/SIP/8 小時 soak 前都未 commission。CI 的 debug-key `debug-contract` APK 不是 release。 |
| Windows x86/x64 WPF | 已實作，有 hosted contract/stub compile 與 opt-in self-hosted release gate | hosted stub 不 upload；只有 commissioned runner 可 upload real-PJSIP x86/x64 bundle。仍無 VM/Toughpad 硬體認證記錄。 |
| iOS 12+ | 已實作，有 hosted simulator 與 unsigned device-link gate，須簽署實機驗證 | CI 建置 keyed real-PJSIP simulator/iPhoneOS archive、iOS 12 simulator contract 與 unsigned arm64 device binary；camera/audio/SAM/recovery/signing/install/soak 仍是實機 gate。 |
| iOS 9 arm64 | 有 unsigned device-link proof；未 install/實機驗證 | 驗證 unsigned `iphoneos` arm64/9.0 Release binary 的 ABI v2、min OS、real-PJSIP symbols、Swift runtime；不 sign/install/launch 或測硬體。 |
| iOS 9 armv7 | formal profile/gate 已實作；未 commission | historical Xcode 7/SDK、real-PJSIP、stock IPA/jailbreak package gate 已有，但沒有 commissioned runner artifact 或實機結果。 |
| iOS 5.1 armv7 compatibility shell | 已實作，有 host contract 與 licensed self-hosted artifact gate，待硬體認證 | 只有 licensed runner 可 upload armv7 app/package。iPad 1 有內建 mic/speaker、沒有 camera。 |
| iPad 1 Core fMP4/H.264 playback | bounded 實機 smoke 通過；不是 hardware certification | Android 14 門口機透過 Core `/stream.mp4` 提供畫面；iPad 1 foreground renderer 持續 15–16 fps、觀測 latency 20–33 ms，Wi-Fi rejoin 與 safe-mode exit 後均恢復，matching cancel 正常結束。process crash 的 call identity/UI recovery 通過，但 optional helper 尚未安裝，relaunch 為 background-only，unattended video resume 未通過。[2026-08-31 evidence](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md)。 |
| iPad 1 外部 IP camera MJPEG/snapshot | 有限制地實作 | 只允許明確 `media_sources`。shell direct playback HTTP(S) MJPEG/snapshot，`secret_ref` 只解成 ephemeral Basic/Bearer header，使用 platform TLS validation。JPEG 僅本機 (`jpeg_core_forwarding:false`)。 |
| iPad 1 RTSP/TCP H.264 ingest 與轉送 | 已實作、host/loopback contract verified；實機未 qualification | bounded path 解析 SDP/`sprop-parameter-sets`，處理 single NAL/STAP-A/FU-A RTP，loss 後等待 next IDR，並向 Core 轉送 Annex-B。DESCRIBE/SETUP 成功且實際 IDR 被 Core 接受前，維持 `rtsp_ingest_pending` degraded state，不 advertise `rtsp_h264_forwarding`。iPad 1 搭配真實 camera 尚未驗證。 |
| optional iOS/rooted-Android keepalive helper | 已實作並通過 host test；實機未 qualification | `tools/helper` 有 fixed local Unix transport、compiled launch profile、peer/PID check、持久 `off|auto|on`、maintenance lease、atomic status、2/5/10/30/60 秒 backoff 與 crash-loop safe mode。持久 `auto`/`on` 在 helper restart 後 cold launch，`off` 不 kill 已執行 app 而只 disarm。configured mode 只是 request，advertise 依實測 availability/effective mode。iOS 5 lane 會產生不啟用 launchd 的可重現 staged DEB，但仍沒有實機合格證據。 |
| tvOS listen-only direct SIP monitor | source 已實作；tracked Debug simulator build；實機未 qualification | tracked job 只 build unsigned arm64 `DoorbellTV` Debug (`appletvsimulator` + real PJSIP)。沒有 tvOS Release/device artifact、sign/install 或真 Apple TV audio/video 證據。 |
| tvOS SIP Answer/transmit | 不支援 | Apple TV 沒有 mic；UI 刻意隱藏 Answer，且不 advertise transmit。 |
| 瀏覽器 WebRTC 通話 | 有條件 | 需要 Asterisk WebSocket/WebRTC 與 secure context；MJPEG panel 不等於有麥克風。 |
| Web SOS active-page/Push presentation | 已實作；browser/deployment qualification 另計 | open page 預設顯示 replicated SOS。`emergency.web_active_page_alerts:false` 只停用 raw-state 顯示，positive matching `device_alert`/Push 仍可顯示。raw state 啟用時 rule TTL 只結束 decoration/sound，安全的紅色 overlay 保留至 clear；驗證 visual/sound/volume/sticky/TTL/colors 並保留於 Push，但 OS notification 可能限制 custom color/audio。`?group=` 的保存值供 poll/Push 共用，完整 subscription secret 在 CRDT 內以 XChaCha20-Poly1305 seal。Core `delivery_result` 是 dispatch evidence，不是 presentation proof。 |
| Native/Web semantic UI manifest | 已實作 durable native cache；Web scope 僅本 node | Core 永久保存 peer 的 last-valid native manifest/capability；configured offline device 以 `cached_contract:true` 驗證/queue，但仍需 renderer apply report。`web_ui.manifest` 只屬 serving node，不是 remote Web catalog。 |
| cross-platform conformance harness | golden model + source smoke | 只重播 reference traces 與檢查 narrow source literals，不執行 client artifact，也不是 rendering/timing/hardware/release evidence。 |

## 現行 release gate

須完成目標 tests/lint、English-source/i18n check、成品 metadata、真實 PJSIP、lane 隔離、secure
store、簽署，以及逐裝置的 media/audio/call/kiosk/recovery/power/network/thermal/soak。公開 PR
不得使用 trusted signing 或 jailbreak runner。

目前 repository 沒有合格 Android API 19 SKU、Windows VM/Toughpad、iOS 9 armv7 commission、
iOS 9 arm64 signed device、tvOS Release/device 或 iPad 1 camera/audio/enclosure 的完成證據。local
`ios-legacy-0.2.0-final` tag 已存在，但此 working tree 的 `ios-compat` 尚未 tracked，fresh-clone/
device/rollback gates 未完成，因此目前保留 `ios-legacy`。
