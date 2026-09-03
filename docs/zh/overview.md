# 系統總覽

ox-app-doorbell 是多 node 的家用門鈴/intercom。native client 共用 C++ core，處理 mesh、複製
config/event、rule、HTTP API、media 發佈與 SIP control。platform shell 透過 versioned
`db_platform_v2` 提供 UI、camera/audio、secure storage、HTTPS、kiosk 與實測 capability。

English 為正準。參見 [capability](capability-matrix.md)、[deployment](deployment.md)、
[config](config-schema.md)、[security](security.md)、[recovery](recovery.md) 與
[ports](network-ports.md)。

## role 與故障邊界

| role | 責任 |
|---|---|
| `door_station` | 訪客 UI、ring event，以及該裝置實際具備的 media/audio。role 不代表 camera、mic、戶外等級或硬體認證。 |
| `indoor_panel` | 目標式響鈴 UI、monitor/answer、reply 與 emergency UI。 |
| browser panel | HTTP panel/API。音訊通話需要 secure context 與 Asterisk WebRTC 設定。 |
| 選用 integration | MQTT/HA、Telegram、Asterisk/PSTN、go2rtc/HomeKit；依賴它們的 action 在服務中斷時不可用。 |

mesh 狀態可以在沒有中央 DB 的情況收斂。正確 rule 與真實 PJSIP 可讓 mesh ring/local chime/direct
intercom 在 HA/PBX 中斷時繼續；Telegram、HA、PSTN、browser WebRTC 與 PBX call 仍依賴對應服務。

## 已實作 contract

核心已實作契約包括 call ID、targeted schema-v2 chime、cancel/recovery/stale rejection、LWW config/
event、runtime capability/status、rule、admin/panel API、asset、MJPEG/snapshot、verified platform 提供
H.264 後的 fMP4 packaging，以及 secure-store `secret:` reference。`sipctl_stub` 不得用於產品通話。

schema-v2 lifecycle 中，手動接聽 client 只把 exact `door`/`call_id`/`stage_revision` bind 到
answer-mode SIP dialog。接通後 `call_answered` 保存一個決定性的 `dialog_owner`、停止 ring timeout 並
切為 `in_call`；之後拒絕 visitor cancel。同時接聽的 loser hangup 時不結束 winner，monitor 不 claim
ownership。owner hangup 發出 `call_ended`。restart 後 ringing 由 press origin、in-call 由 dialog owner
在 10 秒內復原，失敗只發出一次 global idempotent recovery cancel。

SOS state 始終複製，但 recipient/channel presentation 由 rule 決定，也可為空。Web 預設處理
replicated SOS；`emergency.web_active_page_alerts:false` 只停用 raw-state path，matching positive
`device_alert`/Web Push 仍可顯示。Core `delivery_result` 是 dispatch attempt，client runtime report 才是
各 channel 的 presentation/limitation。raw path 啟用期間，rule TTL 只結束 custom decoration/sound；
安全的紅色 raw-SOS overlay 保留至 clear 或 switch off。

## 室內機相機預覽排程

預覽負載依面板能同時顯示的數量設限，而不是依已配置門口機總數增長。只有一台時使用保持比例的大型
貼片；兩三台平分可用 viewport；更多時改用 compact 貼片與明確的捲動／分頁選擇。Android 每輪最多
更新三個可見貼片，modern iOS 每頁四個，iPad 1 每頁三個（safe mode 為一個）；隱藏貼片不抓取或
解碼 snapshot。

`press` 或 `motion` event 會把對應門口機提升至 active set 最前。提升結果去重並按最新事件排序；即使
同時大量觸發，也只會替換有界的 active slot，不會對全部相機啟動工作。住戶可用 Android 捲動或 iOS
的編號 camera page 覆蓋 event 選擇。這只規範 dashboard 排程；所有已配置門口機仍可直接 monitor。

## 視訊啟動熱路徑

設定為 H.264 的門口機會在尚無觀看者時維持 platform encoder 運行。Core 保留初始化 segment 與最新的
完整 random-access fragment；新的 fMP4 subscriber 會立即收到兩者，同時產生一個可合併的 keyframe
request。Android MediaCodec、Apple VideoToolbox、iOS 5 RTSP ingest（RTCP PLI）及 Windows Media
Foundation 都會直接處理此 request，不重啟 encoder。MJPEG path 在背景建立有界 cache，live stream
追上前可先提供不超過 250 ms 的可信 frame。

室內機會預先準備可重用的 rendering resource：Android 保留一個 stopped AVC decoder，modern iOS
保留一組 `AVPlayer`/`AVPlayerLayer`，iOS 5 保留一個 1-pixel GL/VideoToolbox view，Windows 則隨主視窗
建立 media element。memory pressure 時可釋放這些非必要 reserve。響鈴 preview 會一直作為 availability
layer，直到 H.264 確實顯示 frame；接聽後沿用同一 transport/player，不重新連線。browser viewer 也會
取得相同的 Core-side cached JPEG 或 fMP4 bootstrap。訪客取消只結束 call lifecycle 與響鈴，不會拆除
室內機目前的 preview；transport 由住戶的關閉操作或頁面正常期限結束。這些是縮短啟動延遲的機制，不代表所有硬體已達
固定 glass-to-glass 目標；仍須以實機 timing qualification 為準。

Core 永久 cache peer 的 last-valid native UI manifest/capability。`cached_contract:true` 的 configured
offline device 可依 cached contract 驗證/queue，但只有後續 renderer report 能證明套用。Web manifest
仍只屬 serving Core node。沒有 `targets` object 的 legacy alert 對所有 native node/Web group。明確
selector 採對稱語意：只有 Web group 時不對 native shell，只有 native selector 時不對 active Web
page/Push subscription。Web page 把 `?group=<name>` 的保存值同時用於 state poll 和 Push enrollment。
完整 Push subscription secret 以 mesh-PSK-derived key 與 XChaCha20-Poly1305 一起 seal 成 schema-v2
CRDT record，config/export 不含 plaintext。

## platform 狀態

| platform | 範圍 | 狀態 |
|---|---|---|
| Android | API 21+ modern、API 19 armv7/NEON legacy | moto g64y 5G/API 34 的 bounded critical-trim/fMP4 recovery smoke 已通過。API 19 qualification list 為空 (support SKU 0)；CI debug-contract APK 不是 release。 |
| Windows | .NET 4.8 WPF、x86/x64 core | 有 gate，但 Windows VM/Toughpad 驗證未完成。 |
| iOS | iOS 12+、iOS 9 arm64、iOS 5.1 armv7 | iOS 9 arm64 只有 unsigned link proof；armv7 formal gate 未 commission。iOS 5 使用 `ios-kiosk` + staged `ios-compat`。 |
| tvOS | 畫面 monitor/reply + direct-SIP listen-only source path | tracked CI 只證明 real PJSIP 的 unsigned Debug simulator build；沒有 Release/device。無 mic，不支援 Answer/transmit。 |
| Web | admin/panel/same-origin media/active SOS/optional Push | WebRTC/Push 有條件；native/Web manifest 分開，remote Web manifest 不複製；legacy Safari 為 best-effort。 |

第一代 iPad 有內建麥克風與揚聲器，但沒有相機。完成實機測試後，才可用於 indoor role 或明確配置
外部 camera/no-video 的 door profile。它不是戶外產品；入口使用需要防水、防凝露、溫控 enclosure。
bounded RTSP/TCP H.264 ingest 與 Annex-B 轉送已通過 host/loopback 驗證，但在實際 IDR 被接受前維持
degraded，且 iPad 1 搭配真實 camera 尚未 qualification。HTTP(S) MJPEG/snapshot direct playback 只把
`secret_ref` 解成 ephemeral auth header，不把 JPEG forward 到 Core。optional root helper 已實作並通過
host test，也有不會啟用 launchd 的可重現 staged DEB，但仍是 opt-in，且 iOS 實機 qualification 未完成。
另一項 bounded Android→Core fMP4→iPad smoke 已在真實 iPad 1 foreground renderer 以 15–16 fps 通過；
crash 後 unattended foreground video resume 與整體 hardware gate 仍未完成。

## repository 驗證入口

基本驗證採用 English overview 的 command 與各 platform README/release gate。host core test 通過不代表
signed/SIP-enabled/hardware artifact 已合格。

`tools/conformance/run.py` 是 golden reference-model replay + narrow source-anchor smoke，不執行 client
artifact，也不能證明 rendering、timing、signing 或 hardware。
