# 架构深入

> 日本語: [Architecture](Architecture) / English: [Architecture-en](Architecture-en)

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

所有设备都搭载共享 C++ 核心 (doorbell-core)，平台外壳（WPF P/Invoke / JNI / Swift）
只看 [doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h)
的 C ABI。UI 事件以 JSON 回调（`{"t":"chime",...}` 等）流向外壳。

## mesh —— 发现・gossip・选主

- **发现**: UDP 47171 的组播 beacon（带 HMAC 的 HELLO）。iOS 外壳并用 Bonjour。
  作为保险也可以用 `cluster.seed_peers` 的静态列表。
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
- `/stream.mp4` 只在有订阅者时才转编码器 (`db_core_video_encoder_wanted`)。
  go2rtc 可以用 `#video=copy` 接收，HA 侧无需转码。
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
管理 = 密码会话，panel/stream = `?k=<token>`。webui 在构建时
嵌入二进制 (`embed_webui.py`) —— 连静态文件分发服务器都不需要。

## 为什么只有 leader 才对外发送

如果所有节点都向 Telegram/MQTT 发送，同一条来客通知会按台数重复送达。可要是
「固定发送负责人」，那 1 台就成了单点故障。答案是「确定性选主 + 自动接任」:
平时只有 1 台代表发送（零重复），那 1 台消失后数秒内由别的节点
接任（零遗漏）。由于事件复制是幂等的，即使在交接瞬间发生了双重发送，
notify 的 LWW 合并也不会破坏「已应答」状态。这就是「宁重勿漏」的实现形态。

相关: 设计判断的来龙去脉见[决策记录](Decisions-zh)，功能视角见[功能总览](Features-zh)。
