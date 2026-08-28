# Decision Record (ADR-style)

> 日本語: [Decisions](Decisions) / 中文: [Decisions-zh](Decisions-zh)

Major design decisions, recorded as "context → options → decision → rationale".
For philosophy-level discussion see [Design-Philosophy](Design-Philosophy-en); for implementation see [Architecture](Architecture-en).

## D1: Two video tiers — MJPEG baseline + H.264 tier

- **Context**: devices range from a Win7 Toughpad to the latest iPhone. No single codec covers both ends.
- **Options**: (a) MJPEG everywhere, (b) H.264 everywhere, (c) two tiers.
- **Decision**: (c). The baseline is MJPEG (`/stream.mjpeg`) — displays on every device and browser (the iPad 1's jailbroken native app / Safari included). Only devices with a hardware encoder add HW-encoded fMP4 (`/stream.mp4`) via `codec: auto/h264`.
- **Rationale**: MJPEG decodes even on old-device CPUs and has zero implementation quirks. The H.264 tier grants smooth 720p call quality and "no HA transcoding (go2rtc `#video=copy`)" to capable devices only. `auto` silently falls back to MJPEG when hardware-encoder probing fails — the degradation ladder itself.

## D2: Station-to-station intercom over direct SIP (PBX-independent)

- **Context**: originally the intercom was also routed through Asterisk. But that makes the PBX a single point of failure.
- **Options**: (a) unify on Asterisk, (b) a custom protocol, (c) direct calls in standard SIP.
- **Decision**: (c). Each station listens on a fixed UDP 47190, with the `X-Doorbell-Mode` header distinguishing answer/monitor. Peer IPs resolve from the mesh's member roster (members only).
- **Rationale**: intercom and monitoring survive a PBX outage (the self-healing policy). Staying with SIP lets the PJSIP implementation be shared with the phone leg and avoids inventing a custom protocol. No dialplan changes needed either. Asterisk's role was purified into one thing: "the leg into the phone network".

## D3: No Telegram calls or FaceTime for video calls from outside

- **Context**: wanting a "video call" with the door from outside the home (surveyed in plan §17).
- **Options**: (a) Telegram video call, (b) FaceTime, (c) HomeKit remote viewing + PSTN audio, (d) VPN + the in-house stack, (e) Telegram video note (short clips).
- **Decision**: (c) as standard, (d) for advanced users, (e) as a supplement. **(a) and (b) rejected**.
- **Rationale**: Telegram's calling API is not open to bots, so an auto-answering door station cannot be built. FaceTime is Apple-only and has no automation API whatsoever, so unattended answering on a kiosk device is impossible. HomeKit (video) + Hikari Denwa (audio) satisfies "see and talk" using only existing, well-worn paths. With a VPN, the full in-house UI works as-is.

## D4: No intercom (two-way audio) over HomeKit

- **Context**: the Home app can notify and show live video, yet the answer button cannot talk.
- **Options**: (a) implement full two-way audio as a HomeKit Doorbell, (b) viewing only.
- **Decision**: (b). HomeKit is limited to "notification + live video"; voice answering goes through the phone (PSTN) or the in-house app.
- **Rationale**: routing two-way audio streams through HA's HomeKit Bridge is constrained, and stable intercom quality cannot be guaranteed. Rather than adding one more unreliable intercom, entrusting audio to the phone leg that reliably connects better serves "better redundant than missed".

## D5: No new dependencies — in-house fMP4, in-house MQTT client

- **Context**: off-the-shelf libraries exist for both fMP4 muxing and MQTT.
- **Options**: (a) link ffmpeg/libmosquitto etc., (b) implement the necessary minimum in-house.
- **Decision**: (b). fMP4 is an in-house muxer that just "boxes H.264 AnnexB"; MQTT is an in-house client speaking only 3.1.1 QoS0 (`core/src/bridge/mqtt_client.cpp`).
- **Rationale**: targets span Win7 x86 to iOS — every added dependency makes builds and distribution on old platforms more fragile. Only a thin slice of each spec is used, and in-house code is lighter to test, port, and maintain long-term. TLS alone is delegated to the platform frameworks (SPI `https_request`); rolling our own crypto is avoided.

## D6: iOS distribution in stages — Ad Hoc → App Store

- **Context**: it is just a handful of devices in one home, yet iOS puts up a signing wall.
- **Options**: (a) free-team 7-day signing, (b) Ad Hoc, (c) App Store (unlisted), (d) ABM custom app.
- **Decision**: (b) Ad Hoc first (UDID registration + yearly re-signing). (c) is planned for Phase 7 as the permanent solution.
- **Rationale**: (a) means re-signing every week — unfit for permanent operation. (b) needs only a yearly ritual, and forgetting is prevented by the in-app expiry display and Telegram's 30-day advance warning. Once device counts and operations settle, publishing to the App Store (unlisted) and eliminating re-signing entirely is the end state.

## D7: Asterisk WebRTC gateway for browser calls only (optional feature)

- **Context**: browsers cannot speak SIP/UDP directly.
- **Decision**: native-device intercom is complete with D2's direct calls; **only if you want browser calling** does Asterisk act as a WebRTC gateway (JsSIP + WebSocket). If unused, no configuration is needed. Browser→door-station video also skips WebRTC negotiation in favor of the well-worn canvas→JPEG POST approach.
- **Rationale**: keep WebRTC's complexity (ICE/DTLS/SFU) out of the core's mandatory path.
  Details: [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md).

## D8: Strings in a single YAML, generated into each platform's format

- **Context**: string formats differ per platform — resx (WPF) / strings.xml (Android) / Swift.
- **Decision**: [i18n/strings.yaml](https://github.com/yukiinagato/ox-app-doorbell/blob/main/i18n/strings.yaml) (Japanese originals + en/zh) is the single source, and `tools/gen_i18n.py` generates each format. Runtime overrides (i18n_overrides) ride the same key scheme in the CRDT.
- **Rationale**: hand-syncing three languages across multiple platforms is guaranteed to break down. Generated files are tracked with do-not-edit headers, and duplicate or missing keys surface in CI (the repair commit is in the development history — see git log, not [FAQ](FAQ-en)).
