# Design Philosophy — Why This Kind of Doorbell

> English (this page) / 日本語: [Design-Philosophy-ja](Design-Philosophy-ja) / 中文: [Design-Philosophy-zh](Design-Philosophy-zh)

Design goals are not release claims. Current implementation, build, hardware-certification, and unsupported status is recorded in the [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md).

This project is not a "replacement for an off-the-shelf doorbell" — it is designed as **part of the home's infrastructure**. A few convictions run through it. Read them in order, as a story.

## 1. Never entrust your life to a server — serverless self-healing

The source of truth for mesh state lives in a P2P mesh. Native nodes gossip and replicate configuration and events; optional integrations remain separate failure boundaries.

- If Home Assistant goes down, implemented mesh-local actions can continue; HA, HomeKit, and HA-hosted media actions do not.
- If Asterisk goes down, commissioned direct-SIP paths can continue; PBX/PSTN/WebRTC paths do not.
- A surviving healthy native node can help restore replicated configuration. Backups and device-local secret recovery are still required.

Only external notifications (Telegram / MQTT) are sent by a single "leader" node to avoid duplicates — but the leader is elected automatically by a deterministic algorithm, and if it falls, another node takes over.

## 2. Never abandon old devices — a ladder of graceful degradation

The device at your entrance does not need to be new. In fact, the devices "sleeping in a drawer" are the ideal candidates. This system deliberately maintains a long degradation ladder.

- Windows: WPF + .NET Framework 4.8 — runs all the way down to a **Windows 7 SP1 Toughpad**.
- Android: minSdk 21 (Android 5.0). A legacy API 19 path exists for 4.4, but its production SKU allowlist is currently empty. The tracked debug-contract build is not a release or hardware-qualification claim.
- iOS: iOS 12 and later (legacy path for 9). Retired iPhones/iPads become door stations and indoor stations.
- An **iPad 1 (A1219/A1337, iOS 5.1.1)** has a compatibility shell. It has a built-in microphone and speaker but no camera, and it is not outdoor-rated. The bounded RTSP/RTP-over-TCP H.264 and Annex-B path is host/loopback-tested, including SDP/sprop, single NAL/STAP-A/FU-A and next-IDR recovery; it stays degraded until an IDR is actually accepted and has no real-camera iPad qualification. Audio, recovery, thermal/weather-resistant enclosure, power, and the optional host-tested root helper still require exact-device commissioning ([provisioning](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.en.md)).
- Video follows the same philosophy: MJPEG is the compatibility baseline. H.264 is an upper tier used only after the platform reports a working path; otherwise the session falls back to MJPEG (see [Decisions](Decisions)).

## 3. Native on every platform — why not Electron

On low-spec old devices, Electron/web wrappers are too heavy and cannot reach deep OS features like camera, audio, kiosk mode, and power control. So the architecture is a **shared C++ core (doorbell-core) + a thin native shell per platform** (WPF / Android / Swift). Logic lives in one place; only UI and OS integration are platform-specific. The shells see nothing but the C ABI in [core/include/doorbell/doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h).

## 4. The phone network as the ultimate redundancy

A network that can remain available when app push is not has actually been in your home all along — the telephone network. With a commissioned Asterisk/Hikari Denwa HGW path and matching rules, a bell press can ring indoor extensions and a mobile phone (PSTN) in parallel. During a call, configured DTMF codes can trigger actions such as unlocking. This is not "putting a phone on top of a smart home" — it is designing a separately tested telephone path as another line of defense.

## 5. "Better redundant than missed" — duplicate rather than drop

The cost of missing a visitor once far outweighs the annoyance of a notification arriving twice, so the rule engine can dispatch independent SIP, Telegram, HA, and chime actions in parallel. These actions remain rule-driven: an administrator can narrow recipients, silence channels, or remove an action entirely. `quiet_hours` is one possible condition, not a guarantee that every other channel will run.

## 6. A safety boundary — no automatic calls to police or fire services

SOS active/clear state is always replicated to every Core node and restored after reconnection. What any device displays or sounds, and whether Web Push, Telegram, MQTT, or a user-defined SIP destination is used, is entirely rule-driven; an administrator may intentionally configure zero recipients or a silent presentation. Automatic dialing of police or fire services is deliberately not implemented because of false-alarm risk and the need for human judgment.

Open Web pages have a separate safety control. `emergency.web_active_page_alerts` defaults to `true`, so they render replicated SOS active/clear state even when the rule set has zero recipients or Push-only targeting. Turning it off does not block a positively matched `device_alert` or an actually delivered Push. Operationally, a Core `delivery_result` proves only that dispatch was attempted; the client's runtime per-channel report proves presentation.

When that raw-state path is on, a rule TTL may stop custom sound and decoration but cannot erase the safe red overlay while SOS remains active; only clear or switch-off does that. Explicit targets do not leak across surfaces: native-only selectors do not reach Web, Web-only groups do not reach native shells, and only a legacy action without `targets` keeps the all-target compatibility behavior. A Web page uses one persisted `?group=` value for both polling and Push.

## 7. Where secrets live, and the trusted-LAN boundary

- Secrets such as bot tokens and SIP passwords are **never placed in the configuration CRDT in plain text**. Only `secret:` references are replicated; the actual values are stored in each device's secure store (DPAPI / Keystore / Keychain). Even in the admin UI they are write-only, never displayed.
- A Push subscription must remain a complete opaque value, so its endpoint and `p256dh`/`auth` keys are sealed together in a schema-v2 CRDT record with XChaCha20-Poly1305 under a mesh-PSK-derived key. Configuration/export never reveals them in plaintext; startup reseals legacy raw records or removes them fail-closed.
- Node HTTP/video is a trusted-LAN interface, not an Internet security boundary. Do not expose it publicly; use a maintained VPN or authenticated TLS reverse proxy. Treat panel URLs and tokens as secrets and keep them out of logs and public config ([security guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/security.md)).

## 8. No recording

This system is a doorbell, not a surveillance camera. It does not record continuously; it deals only in event-time snapshots and live video watched by whoever needs it. If you want recordings, record freely on the go2rtc/HA side — that capability is simply placed outside the boundary.

---

Next: for the feature overview see [Features](Features), for implementation internals see [Architecture](Architecture), and for the history behind individual design choices see [Decisions](Decisions).
