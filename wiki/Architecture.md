# Architecture Deep Dive

> English (this page) / 日本語: [Architecture-ja](Architecture-ja) / 中文: [Architecture-zh](Architecture-zh)

This page digs into the implementation. For the canonical configuration reference see
[docs/en/config-schema.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/config-schema.md),
and for ports see [docs/en/network-ports.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/network-ports.md).

## Overall layout

```
        +------------------- trusted L2 LAN -------------------+
        |                                                      |
  [door station]          [indoor panel] [Android TV] [browser]|
        |   \        mesh (UDP 47171 beacon / TCP 47172)   /   |
        |    +--------- P2P replicated state ------------+    |
        |         |                |                            |
        |    (leader only)      direct SIP UDP 47190            |
        |     MQTT 1883         (answer/monitor)                 |
        |     Telegram 443                                      |
        +------|-----------------------------------------------+
               v
        [HA + Mosquitto + go2rtc]   [Asterisk] -- [phone gateway] -- PSTN
```

Native clients integrate the shared C++ core through the versioned `db_platform_v2` C ABI in
[doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h).
UI events flow to the shells as JSON callbacks (`{"t":"chime",...}` etc.).

## mesh — discovery, gossip, leader election

- **Discovery**: multicast beacons on UDP 47171 (HELLO with HMAC), with device-local `boot.json` `seed_peers` where multicast is unavailable.
- **Transport**: TCP 47172. All traffic protected by PSK-based AEAD (`secure_channel`).
- **gossip/sync**: the configuration CRDT and the event log are anti-entropy-synced between nodes. A new node pulls the full state when it joins.
- **Leader election**: a deterministic algorithm elects a leader per duty. Only the leader performs external sends (MQTT / Telegram), and if the leader disappears, another node takes over automatically. Capabilities (mains power, outbound internet reachability, etc.) are declared via measurement plus `caps_override` and used as election qualifications.
- Implementation: `core/src/mesh/`.

## Configuration = LWW-Map CRDT + HLC

Configuration is a flat Last-Writer-Wins Map of "dot-path key → JSON value". Timestamps use HLC (Hybrid Logical Clock) — causal ordering survives even a device with a broken wall clock. Writes on any node resolve deterministically, and all nodes converge to the same result. The admin UI and in-app settings are all just writes into this CRDT. Secrets (`*_ref: "secret:…"`) replicate only the reference; the values live in each device's secure store.
Implementation: `core/src/crdt/lww_map.cpp` (with property tests).

## Event replication and idempotency

Events (press / motion / reply / offline / emergency / visitor_lang …) are replicated by gossip with `(origin_node, origin_seq)` as their ID — receiving the same event any number of times is idempotent. The response state for a press (who claimed it, the Telegram msg_id, which reply answered it) is LWW-merged as notify, so "answered" is consistent across all devices. Persistence is SQLite (`core/src/store/`).

Schema-v2 call lifecycle is scoped by `(door, call_id, stage_revision)`. A visitor may cancel only
while the call is ringing; after `answered`/`in_call`, the action is hangup and produces
`call_ended`. A manual Web answer claims one random `dialog_id` and receives an opaque
`dialog_owner`; a competing answer must terminate its losing SIP dialog. Restart recovery restores
a ringing call at its press-origin node, but only the winning dialog owner may restore an in-call
session. If that cannot be proved within ten seconds, Core emits one idempotent global cancel.

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
 camera → FrameBus ─┬─ MJPEG encoder → /stream.mjpeg (compatibility baseline)
                    ├─ /snapshot.jpg (Telegram image / HA generic camera)
                    ├─ MotionDetector (motion event)
                    └─ shell hardware encoder → db_core_on_encoded_frame
                                → fMP4 muxer → /stream.mp4
```

- H.264 encoding uses the platform's hardware (MediaCodec / VideoToolbox / Media Foundation). The core just receives AnnexB, boxes it into fMP4, and serves it (an in-house muxer, no external dependencies).
- `/stream.mp4` spins up the encoder only while subscribers are attached (`db_core_video_encoder_wanted`). go2rtc can consume it with `#video=copy`, eliminating transcoding on the HA side.
- For web calls, browser→door-station video uses `getUserMedia → canvas → POST JPEG to /call-frame` ([Decisions](Decisions)).

## Asset distribution

Background images and custom recordings are registered in a sha256 ledger (`assets.<hash>`), with the actual blob stored on the upload node. **The moment the configuration references one**, each node proactively prefetches it via the mesh's FETCH_BLOB (fetchable from any holding node); playback and display thereafter are always from a local file = millisecond response. Tombstoning a ledger entry makes each node reclaim it via grace-period GC. Fetch APIs enforce strict 64-hex-digit validation to prevent path traversal.

## httpd — everything on one port

Each node's TCP 47180 (CivetWeb) serves the admin SPA (`/admin/`), web panels (`/panel/…`),
MJPEG/fMP4/snapshots, and their APIs. Admin uses a password session. A panel credential is supplied
once in a URL fragment (`#k=`, which HTTP never transmits), exchanged through
`POST /api/panel/session`, and thereafter held in an HttpOnly cookie. Query/form credentials are
rejected; cross-node uploads may use a bearer header. The Web UI is embedded into the binary at
build time (`embed_webui.py`).

## SOS delivery and semantic UI contracts

SOS active/clear state is replicated to every Core node. Presentation and external delivery are
rule-driven and can intentionally have zero recipients. The administrator switch
`emergency.web_active_page_alerts` defaults to true and lets an open Web page render replicated SOS
even for zero-recipient or Push-only rules. When disabled, a positive matching `device_alert` or a
delivered Push can still render. Core `delivery_result` records a dispatch attempt; each client's
runtime per-channel report records whether visual, sound, system-notification, or Web presentation
was applied, suppressed, unsupported, or failed. While the raw path is enabled, a rule TTL expires
custom decoration/sound but leaves the safe red raw-SOS overlay until SOS clear or switch-off.

A legacy alert with no `targets` addresses all native nodes and Web groups. With an explicit
`targets` object, selection is symmetric: Web-only groups address no native shell, and native-only
selectors address no active Web page or Push subscription. Panel `?group=<name>` is validated,
persisted, and reused for both state projection and Push enrollment. Core seals each complete Push
`endpoint`/`p256dh`/`auth` value in one schema-v2 CRDT record with XChaCha20-Poly1305 under a
mesh-PSK-derived key; plaintext is absent from config/export, and legacy raw records are resealed
or removed fail-closed at startup.

Native clients advertise a top-level semantic `ui_manifest`. The serving Core node separately
publishes its built-in Web renderer manifest as `web_ui.manifest`. The latter is local, not a
replicated catalog of remote Web surfaces; Admin must not infer a remote/offline Web editor from a
native peer manifest or invent an unknown manifest. Core does durably cache each peer's last valid
native manifest/capabilities: a configured offline device marked `cached_contract:true` can be
validated and queued against that cache, but only its later renderer report proves application.

## Why only the leader sends externally

If every node sent to Telegram/MQTT, the same visitor notification could arrive once per device.
Hard-coding one sender would instead create a single point of failure. Core therefore uses
deterministic duty election and re-elects after mesh convergence. This normally limits dispatch to
one leader, while replicated event identity and LWW claims bound duplicate state changes during
handover. It is not a zero-miss or delivery-time guarantee: partitions, convergence delay, and the
external provider remain visible through delivery diagnostics.

Related: for the history behind design choices see [Decisions](Decisions); for the feature-level view see [Features](Features).
