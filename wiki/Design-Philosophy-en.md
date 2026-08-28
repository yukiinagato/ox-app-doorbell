# Design Philosophy — Why This Kind of Doorbell

> 日本語: [Design-Philosophy](Design-Philosophy) / 中文: [Design-Philosophy-zh](Design-Philosophy-zh)

This project is not a "replacement for an off-the-shelf doorbell" — it is designed as **part of the home's infrastructure**. A few convictions run through it. Read them in order, as a story.

## 1. Never entrust your life to a server — serverless self-healing

An ordinary smart doorbell turns into a dead slab the moment its hub, cloud, or "center" such as Home Assistant dies. Here, the source of truth lives in a **P2P mesh**. All devices gossip as equals, and both configuration and events are replicated to every node.

- If Home Assistant goes down: ring display, chimes, indoor intercom, and panels keep working.
- If Asterisk (the PBX) goes down: intercom survives, because it uses direct SIP (UDP 47190) that bypasses Asterisk. The only limb that dies is "calling out to phones".
- If a single device survives: the full configuration can be restored from it. Backups are still nice to have, but day-to-day survivability does not depend on them.

Only external notifications (Telegram / MQTT) are sent by a single "leader" node to avoid duplicates — but the leader is elected automatically by a deterministic algorithm, and if it falls, another node takes over.

## 2. Never abandon old devices — a ladder of graceful degradation

The device at your entrance does not need to be new. In fact, the devices "sleeping in a drawer" are the ideal candidates. This system deliberately maintains a long degradation ladder.

- Windows: WPF + .NET Framework 4.8 — runs all the way down to a **Windows 7 SP1 Toughpad**.
- Android: minSdk 21 (Android 5.0). A legacy path exists for 4.4.
- iOS: iOS 12 and later (legacy path for 9). Retired iPhones/iPads become door stations and indoor stations.
- Even below that: an **iPad 1 (iOS 5 Safari)** can serve as a ring panel and a call monitor, by adding the web panels (door.html / monitor.html) as Web Clips.
- Video follows the same philosophy: the baseline is MJPEG, which "displays everywhere". H.264 is an upper tier used only by capable devices; incapable ones silently fall back to MJPEG (see [Decisions](Decisions-en)).

## 3. Native on every platform — why not Electron

On low-spec old devices, Electron/web wrappers are too heavy and cannot reach deep OS features like camera, audio, kiosk mode, and power control. So the architecture is a **shared C++ core (doorbell-core) + a thin native shell per platform** (WPF / Android / Swift). Logic lives in one place; only UI and OS integration are platform-specific. The shells see nothing but the C ABI in [core/include/doorbell/doorbell.h](https://github.com/yukiinagato/ox-app-doorbell/blob/main/core/include/doorbell/doorbell.h).

## 4. The phone network as the ultimate redundancy

A network that keeps working through a blackout has actually been in your home all along — the telephone network. Combining Asterisk with a Hikari Denwa HGW, a bell press rings **indoor extensions and your mobile phone (PSTN) away from home simultaneously**. Even where smartphone push notifications cannot reach, the phone still rings. During a call, DTMF codes (*1 etc.) can trigger actions such as unlocking. This is not "putting a phone on top of a smart home" — it is "designing the phone network in as the last line of defense".

## 5. "Better redundant than missed" — duplicate rather than drop

The cost of missing a visitor once far outweighs the annoyance of a notification arriving twice. A single bell press runs SIP calls, Telegram, an HA event, and indoor chimes **in parallel**. During hours when you want silence, quiet_hours can suppress just the chime, but by default phone, Telegram, and HA are `never_suppress` — visitors and emergencies always get through, even in the middle of the night.

## 6. A safety boundary — no automatic calls to police or fire services

The indoor station's SOS (long-press alarm) alerts **the family** via an all-node alarm + siren + Telegram 🚨 + MQTT. But automatic dialing of police or fire services is deliberately not implemented — because of the cost of false alarms, and because a machine cannot judge the situation. The decision to call emergency services always rests with a human; the system's job is to deliver the information for that decision (video, notifications, optional SIP calls to user-defined numbers) as fast as possible.

## 7. Where secrets live, and the plain-text LAN trade-off

- Secrets such as bot tokens and SIP passwords are **never placed in the configuration CRDT in plain text**. Only `secret:` references are replicated; the actual values are stored in each device's secure store (DPAPI / Keystore / Keychain). Even in the admin UI they are write-only, never displayed.
- On the other hand, HTTP and video streams on the home LAN are plain text. This is a pragmatic trade-off under the assumption of "a same-L2 home network" — the mesh itself is protected by PSK-based HMAC/AEAD, the admin UI by a password, and panels/streams by tokens, but TLS remains an option for those who want to put up a reverse proxy (Caddy etc.) (see [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)).

## 8. No recording

This system is a doorbell, not a surveillance camera. It does not record continuously; it deals only in event-time snapshots and live video watched by whoever needs it. If you want recordings, record freely on the go2rtc/HA side — that capability is simply placed outside the boundary.

---

Next: for the feature overview see [Features](Features-en), for implementation internals see [Architecture](Architecture-en), and for the history behind individual design choices see [Decisions](Decisions-en).
