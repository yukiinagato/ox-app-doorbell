# Architecture Deep Dive

> 日本語: [Architecture](Architecture) / 中文: [Architecture-zh](Architecture-zh)

This page digs into the implementation. For the canonical configuration reference see
[docs/ja/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/config-schema.md),
and for ports see [docs/ja/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/network-ports.md).

## Overall layout

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

All devices run the shared C++ core (doorbell-core); the platform shells (WPF P/Invoke / JNI / Swift) see only the C ABI in
[doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h).
UI events flow to the shells as JSON callbacks (`{"t":"chime",...}` etc.).

## mesh — discovery, gossip, leader election

- **Discovery**: multicast beacons on UDP 47171 (HELLO with HMAC). The iOS shell additionally uses Bonjour. A static `cluster.seed_peers` list is available as a safety net.
- **Transport**: TCP 47172. All traffic protected by PSK-based AEAD (`secure_channel`).
- **gossip/sync**: the configuration CRDT and the event log are anti-entropy-synced between nodes. A new node pulls the full state when it joins.
- **Leader election**: a deterministic algorithm elects a leader per duty. Only the leader performs external sends (MQTT / Telegram), and if the leader disappears, another node takes over automatically. Capabilities (mains power, outbound internet reachability, etc.) are declared via measurement plus `caps_override` and used as election qualifications.
- Implementation: `core/src/mesh/`.

## Configuration = LWW-Map CRDT + HLC

Configuration is a flat Last-Writer-Wins Map of "dot-path key → JSON value". Timestamps use HLC (Hybrid Logical Clock) — causal ordering survives even a device with a broken wall clock. Writes on any node resolve deterministically, and all nodes converge to the same result. The admin UI and in-app settings are all just writes into this CRDT. Secrets (`*_ref: "secret:…"`) replicate only the reference; the values live in each device's secure store.
Implementation: `core/src/crdt/lww_map.cpp` (with property tests).

## Event replication and idempotency

Events (press / motion / reply / offline / emergency / visitor_lang …) are replicated by gossip with `(origin_node, origin_seq)` as their ID — receiving the same event any number of times is idempotent. The response state for a press (who claimed it, the Telegram msg_id, which reply answered it) is LWW-merged as notify, so "answered" is consistent across all devices. Persistence is SQLite (`core/src/store/`).

## Direct SIP intercom (X-Doorbell-Mode)

Station-to-station intercom **does not go through Asterisk**. Each station's sipctl listens on a fixed UDP 47190, and indoor stations/TVs send INVITE directly to `sip:<host>:47190`.

- Header `X-Doorbell-Mode: answer` = two-way intercom / `monitor` = one-way monitoring (the callee sends only its own microphone audio).
- Only IPs of mesh members are accepted. Direct calls work even with no SIP server or accounts configured.
- Asterisk (UDP 5060) is dedicated to the "phone leg": extension REGISTER, the 600 call on ring, PSTN egress via the Hikari Denwa HGW, and DTMF feature codes. If the PBX dies, intercom and monitoring are untouched.
- Answer takeover: "Answer" on an indoor station drops the phone leg first, then establishes the direct intercom.
- Implementation: `core/src/sipctl/` (PJSIP).

## Media pipeline — from the frame bus to each consumer

Camera capture is done by the shell (or inside the core on Windows) and enters the core's **frame bus (FrameBus)** via `db_core_on_camera_frame`. There are currently four consumer chains:

```
 camera → FrameBus ─┬─ MJPEG エンコード → /stream.mjpeg (誰でも映る基調)
                    ├─ /snapshot.jpg (Telegram 写真・HA generic camera)
                    ├─ MotionDetector (動体イベント)
                    └─ (h264 档) 殻の HW エンコーダ → db_core_on_encoded_frame
                                → fMP4 マキサ → /stream.mp4
```

- H.264 encoding uses the platform's hardware (MediaCodec / VideoToolbox / Media Foundation). The core just receives AnnexB, boxes it into fMP4, and serves it (an in-house muxer, no external dependencies).
- `/stream.mp4` spins up the encoder only while subscribers are attached (`db_core_video_encoder_wanted`). go2rtc can consume it with `#video=copy`, eliminating transcoding on the HA side.
- For web calls, browser→door-station video is not WebRTC but the well-worn "getUserMedia → canvas → POST JPEG to `/call-frame`" approach ([Decisions](Decisions-en)).

## Asset distribution

Background images and custom recordings are registered in a sha256 ledger (`assets.<hash>`), with the actual blob stored on the upload node. **The moment the configuration references one**, each node proactively prefetches it via the mesh's FETCH_BLOB (fetchable from any holding node); playback and display thereafter are always from a local file = millisecond response. Tombstoning a ledger entry makes each node reclaim it via grace-period GC. Fetch APIs enforce strict 64-hex-digit validation to prevent path traversal.

## httpd — everything on one port

Each node's TCP 47180 (CivetWeb) serves the admin SPA (`/admin/`), the web panels (`/panel/…`), MJPEG / fMP4 / snapshot, the admin API, and the panel API. Auth: admin = password session, panel/stream = `?k=<token>`. The web UI is embedded into the binary at build time (`embed_webui.py`) — no static file server needed at all.

## Why only the leader sends externally

If every node sent to Telegram/MQTT, the same visitor notification would arrive once per device. But hard-coding a "sender node" makes that one device a single point of failure. The answer is "deterministic election + automatic succession": in normal operation exactly one node sends on behalf of all (zero duplicates), and if that node disappears, another takes over within seconds (zero misses). Because event replication is idempotent, even a double send at the moment of succession does not corrupt the "answered" state, thanks to notify's LWW merge. This is "better redundant than missed", implemented.

Related: for the history behind design choices see [Decisions](Decisions-en); for the feature-level view see [Features](Features-en).
