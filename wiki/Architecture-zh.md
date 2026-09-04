# 架构深入

> English: [Architecture](Architecture) / 日本語: [Architecture-ja](Architecture-ja) / 繁體中文 (本頁)

深入实现的内部。规范的配置参考见
[docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md)，
端口见 [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md)。

## 整体构成

```
        +-------------------- 同一 L2 LAN ---------------------+
        |                                                      |
  [門口機 Win/Android/iOS]  [室内機]  [Android TV]  [ブラウザ] |
        |   \        mesh (UDP 47171 beacon / TCP 47172)   /   |
        |    +----------- P2P mesh = 真実源 ---------------+    |
        |         |                |                            |
        |    (leader のみ)    直接 SIP UDP 47190                |
        |     MQTT 1883       (対講・監聴)                      |
        |     Telegram 443                                      |
        +------|-----------------------------------------------+
               v
        [HA + Mosquitto + go2rtc]   [Asterisk] -- [ひかり電話 HGW] -- PSTN/携帯
```

native client 透過 [doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
的 versioned `db_platform_v2` C ABI 整合共用 C++ core。UI event 以 JSON callback
（`{"t":"chime",...}` 等）送往 shell。

## mesh —— 发现・gossip・选主

- **發現**: UDP 47171 multicast beacon（HMAC HELLO）；multicast 不可用時使用裝置本機
  `boot.json` 的 `seed_peers`。
- **传输**: TCP 47172。用 PSK 的 AEAD 保护全部通信 (`secure_channel`)。
- **gossip/sync**: 在节点间反熵同步配置 CRDT 和事件日志。新节点在加入时
  吸取全量。
- **选主 (leader)**: 用确定性算法按 duty 选出 leader。对外发送
  (MQTT / Telegram) 只由 leader 执行，leader 消失则自动换人。
  capability（是否常时供电、能否向外网出站等）通过实测 + `caps_override` 申报，
  用作选主的资格。
- 实现: `core/src/mesh/`。

## 配置 = LWW-Map CRDT + HLC

配置是扁平的「点路径 key → JSON 值」Last-Writer-Wins Map。
时间戳用 HLC (Hybrid Logical Clock) —— 即使有实时钟走偏的设备，
因果顺序也不会被破坏。无论在哪个节点写入，胜负都被确定性地决定，所有节点
收敛到同一结果。管理界面也好、应用内设置也好，全都是对这个 CRDT 的写入。
秘密（`*_ref: "secret:…"`）只复制引用，实体放在各设备的 secure store 中。
实现: `core/src/crdt/lww_map.cpp`（附属性测试）。

HTTP Admin endpoint 与 native `db_platform_v2` caller 使用同一条 Core write path。因此 native settings
screen 不必调用 loopback HTTP，也能取得和 Admin 相同的 key validation、已解析的 semantic-UI contrast warning
及 result document。batch 最多包含 256 个互不重复的 set/delete operation，只有所有 operation 都通过
validation 时才作为一个 commit 写入。C ABI 还公开 backward call-history paging、Core 接受的 IANA time-zone
list、持久的 microphone mute，以及已配置的 door-unlock action。

`admin.password_hash` 复制 salted BLAKE2b-256 digest，让 Web Admin 和 native settings 使用同一个
credential 而不复制 plaintext。但 rate-limit 不会复制：五次 bad guess 只会在**同一个 Core node**的 Web 与
ABI check 之间创建十分钟的 in-memory lockout。部署时不可把它当作 fleet-wide 的 brute-force throttle。
unset credential 会被纳入 published SOS policy，避免 active SOS 无法 clear。

schema-v2 call lifecycle 以 `(door, call_id, stage_revision)` 為範圍。訪客只能在 ringing 時 cancel；
進入 `answered` / `in_call` 後，hangup 才會發出 `call_ended`。Web 手動接聽以一個隨機
`dialog_id` claim 並取得 opaque `dialog_owner`，競爭失敗的 SIP dialog 必須終止。restart 時 ringing
call 由 press-origin node 還原；in-call session 只有勝出的 dialog owner 能還原。若 10 秒內無法證明，
Core 只發出一次冪等的全域 cancel。

## 事件复制与幂等

事件（press / motion / reply / offline / emergency / visitor_lang ……）以
`(origin_node, origin_seq)` 为 ID，通过 gossip 复制 —— 同一事件
收到多少次都是幂等的。对 press 的应答状态（谁 claim 了、Telegram 的 msg_id、
用哪条回复回答的）作为 notify 进行 LWW 合并，「已应答」在所有设备上一致。
持久化用 SQLite (`core/src/store/`)。

## 直连 SIP 对讲 (X-Doorbell-Mode)

站间对讲**不经过 Asterisk**。各子机的 sipctl 固定监听 UDP 47190，
室内机/TV 直接向 `sip:<host>:47190` 发 INVITE。

- 头部 `X-Doorbell-Mode: answer` = 双向对讲 / `monitor` = 单向监听
  （接收侧只发送自己麦克风的语音）。
- 只接受 mesh 成员的 IP。即使没配置 SIP 服务器和 accounts，直连呼叫也能用。
- Asterisk (UDP 5060) 专职「电话腿」: 内线 REGISTER、按铃时的 600 号呼叫、
  经光纤电话 HGW 的 PSTN 出局、DTMF 功能码。PBX 死了对讲和监听也毫发无损。
- 应答接管: 室内机的「应答」先挂断电话腿，再建立直连对讲。
- 实现: `core/src/sipctl/` (PJSIP)。

## 媒体管线 —— 从帧总线到各消费者

摄像头采集由外壳（Windows 则在 core 内）执行，通过 `db_core_on_camera_frame`
进入核心的 **帧总线 (FrameBus)**。消费者目前有 4 路:

```
 camera → FrameBus ─┬─ MJPEG エンコード → /stream.mjpeg (誰でも映る基調)
                    ├─ /snapshot.jpg (Telegram 写真・HA generic camera)
                    ├─ MotionDetector (動体イベント)
                    └─ (h264 档) 殻の HW エンコーダ → db_core_on_encoded_frame
                                → fMP4 マキサ → /stream.mp4
```

- H.264 的编码用平台的 HW (MediaCodec / VideoToolbox / Media Foundation)。
  核心只是接收 AnnexB、装箱成 fMP4 再分发（自制 muxer，无外部依赖）。
- `/stream.mp4` 只在有订阅者时才转编码器 (`db_core_video_encoder_wanted`)，并且刻意不 pre-warm。
  go2rtc 可以用 `#video=copy` 接收，HA 侧无需转码。
- 每个 H.264 access unit 都立即成为 fMP4 fragment，不等待下一 frame 再确定 duration。track 每条 stream
  只保留一个最新 fragment；慢 reader 会跳过中间 fragment，Core 会记录跳过次数。private `dbts` box 携带
  compatibility player 计算 live-edge 所需的 capture timestamp，generic fMP4 player 可安全忽略它。
- iOS 5 player 在 H.264 持续显示前保留 MJPEG；只在 warm-up frame 得到该设备的 latency 后才收紧有界的
  live-edge gate。它绝不会丢弃 first/only frame，在没有可信 server clock 时禁用 age drop，并在 display
  stall 时回退 MJPEG。这是 compatibility renderer 的行为，不是 universal latency promise。
- 网页通话中浏览器→门口机的影像不是 WebRTC，而是「getUserMedia → canvas → 把 JPEG
  POST 到 `/call-frame`」这一成熟老办法（[决策记录](Decisions-zh)）。

## 资产分发

背景图片、自定义语音以 sha256 登记在台账 (`assets.<hash>`)，实体 blob 放在
上传目标节点。**在被配置引用的时刻**，各节点通过 mesh 的
FETCH_BLOB 主动预取（只要是持有节点，从哪里都能取），此后的播放、显示
永远走本地文件 = 毫秒级响应。把台账置为 tombstone 后，各节点以带宽限期的 GC
回收。获取类 API 用 64 位 hex 固定校验防止路径穿越。

## httpd —— 一个端口装下全部

各节点的 TCP 47180 (CivetWeb) 提供 管理 SPA (`/admin/`) / 网页面板 (`/panel/…`) /
MJPEG / fMP4 / snapshot / 管理 API / panel API。认证方式:
管理使用密碼 session。panel credential 只在 URL fragment（`#k=`，HTTP 不會傳送）提供一次，經
`POST /api/panel/session` 交換後使用 HttpOnly cookie。query/form credential 會被拒絕，只有
cross-node upload 可使用 bearer header。webui 在 build 時嵌入 binary (`embed_webui.py`)。

## SOS 配送與 semantic UI contract

SOS active/clear 狀態會複製到所有 Core node；呈現與外部配送完全 rule-driven，也允許零收件者。
管理員開關 `emergency.web_active_page_alerts` 預設 true，即使規則為零收件者或 Push-only，開啟中的
Web page 仍可優先呈現複製的 SOS。設為 false 時，正向 matching `device_alert` 或已送達 Push 仍可呈現。
Core `delivery_result` 只記錄 dispatch attempt；client runtime 的逐 channel report 才說明 visual、
sound、system notification、Web presentation 是 applied、suppressed、unsupported 或 failed。raw path
啟用期間，rule TTL 即使結束 custom decoration/sound，安全紅色 raw-SOS overlay 仍保留至 clear 或
switch-off。

沒有 `targets` 的 legacy alert 對所有 native node/Web group。明確 `targets` 採對稱語意：Web-only group
不對 native shell，native-only selector 不對 active Web page/Push subscription。panel
`?group=<name>` 經驗證、保存後，同時用於 state 投影與 Push enrollment。Core 把完整 Push
`endpoint`/`p256dh`/`auth` 用 mesh-PSK-derived key 與 XChaCha20-Poly1305 seal 成一個 schema-v2 CRDT
record；config/export 不含 plaintext，舊 raw record 在啟動時重新 seal，否則 fail-closed 刪除。

native client 公開 top-level `ui_manifest`，配信中的 Core node 則另以 `web_ui.manifest` 公開 built-in
Web renderer contract。Web manifest 只屬本機，不是 remote Web surface 的複製 catalog；Admin 不可從
native peer manifest 推測 remote/offline Web editor，也不可捏造未知 manifest。Core 會永久 cache peer
的 last-valid native manifest/capability；`cached_contract:true` 的 configured offline device 可依 cache
驗證/queue，但只有後續 renderer report 能證明套用。

## 为什么只有 leader 才对外发送

所有 node 都向 Telegram/MQTT 發送時，同一來客通知可能按裝置數重複；固定一台 sender 又會造成單點
故障。Core 因此使用 deterministic duty election，並在 mesh convergence 後重新 election。通常只由一個
leader dispatch，replicated event identity 與 LWW claim 把 handover 的重複 state change 限制在 bounded
範圍。不過這不是 zero-miss 或 delivery-time 保證；partition、convergence delay、external provider 結果
會如實顯示在 delivery diagnostics。

相关: 设计判断的来龙去脉见[决策记录](Decisions-zh)，功能视角见[功能总览](Features-zh)。
