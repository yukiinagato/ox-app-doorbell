# Feature Overview

> English (this page) / 日本語: [Features-ja](Features-ja) / 中文: [Features-zh](Features-zh)

A short summary of what each feature can do. For usage see [Residents](Usage-Residents), [Admins](Usage-Admin), and [Visitors](Usage-Visitors); for how things work see [Architecture](Architecture). Capability status is qualified by the [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md).

## Calling (ringing)

A visitor rings with the door station's large button or a purpose button. The event enters the rule engine, which dispatches the configured actions. Rules can branch per door, purpose, and time. → [Usage-Admin](Usage-Admin)

`purpose_first` selects a purpose before ringing; `ring_then_purpose` rings first and allows purpose
selection or skipping afterward. A visitor can cancel while ringing, but an established call uses
End call/hangup. Manual Web answers are scoped to one `dialog_id` owner so competing browsers
cannot both own the call; recovery restores ringing at the origin and in-call only for that owner.

## Purpose buttons (visit_purposes)

Purpose choices are editable and can be used as rule conditions (`when.purposes`). Presentation in a shell or integration depends on that target's implemented UI/action path. → [Usage-Visitors](Usage-Visitors)

## Visitor language switching

The door station can show configured language buttons. Visitor-language state is replicated and quick-reply labels/TTS select that language with fallback. The configurable idle timer reverts to Japanese. → [Usage-Visitors](Usage-Visitors)

## Intercom (three modes) and answer takeover

Direct SIP (UDP 47190) can bypass Asterisk for implemented monitor/answer paths when both exact artifacts link real SIP and media is available. PBX-independent operation must be commissioned on the deployment hardware. → [Architecture](Architecture)

## Monitoring

From an indoor station or Android TV, a one-way call to the door station with `X-Doorbell-Mode: monitor` — check the door's audio and video without being noticed. When the bell rings, the TV automatically brings up full-screen live video plus monitoring.

## Quick replies

Canned phrases like "We are out at the moment" (multilingual, customizable, ordered) can be sent from an indoor station / TV remote / Telegram inline buttons / HA / web pages → shown in large text on the door station and read aloud. Speech falls back in order: custom recording (registerable per visitor language) → system TTS → notification tone.

## Auto-reply (auto_reply)

As a rule action, an implemented door shell can display and speak a configured quick reply. → [Usage-Admin](Usage-Admin)

## Phone integration (Asterisk + Hikari Denwa)

A bell press rings indoor extensions and your mobile (PSTN) simultaneously. In-call DTMF feature codes are supported (*1 = unlock etc., actions configurable). The distribution logic can be freely changed on the dialplan side.
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md)

## Notifications

- **Telegram**: pushes each ring with a photo + purpose + visitor-language badge. Inline buttons reply instantly.
- **Home Assistant** (MQTT Discovery): doorbell event / motion / device online / bridge liveness / emergency / visitor-language sensors appear automatically. Actionable-notification snippets are included.
- **Indoor chime**: supports custom sounds (`asset:<sha256>`).
- Only the leader node sends externally, preventing duplicate notifications.

## SOS (emergency call for help)

SOS active/clear state replicates to every Core node, while visual, sound, system notification,
Web Push, Telegram, and MQTT delivery are rule-driven and may intentionally target nobody. The
administrator switch `emergency.web_active_page_alerts` defaults to true, so an open Web page still
shows replicated SOS for zero-recipient or Push-only rules; when disabled, a positive matching
`device_alert` or delivered Push can still show it. Core `delivery_result` describes dispatch
attempts; per-client channel reports describe actual presentation. With raw-state display on, rule
TTL expires custom decoration/sound but not the safe red overlay, which remains until clear. A Web
page persists its `?group=` value for both polling and Push. Explicit native-only targets do not
reach Web, and Web-only targets do not reach native shells; legacy no-target actions reach all.
Complete Push subscriptions are XChaCha20-Poly1305 sealed in CRDT and excluded from plaintext config/export. No
automatic calls to police or fire services are implied. → [Design Philosophy](Design-Philosophy)

## Motion detection

Motion is detected from the door station camera's frame bus and fed into rules (e.g. night-only Telegram + HA). Sensitivity and minimum interval are adjustable per device.

## Video — MJPEG baseline + H.264 smooth tier

MJPEG is the compatibility baseline. A platform may publish fMP4 (`/stream.mp4`) only after its encoder path is active and runtime status says it is ready; hardware certification is device-specific. → [Decisions](Decisions)

## HomeKit integration

Via go2rtc + HA's HomeKit Bridge, doorbell notifications and live video appear in the iPhone Home app. With a home hub (Apple TV / HomePod) you can also watch while away.
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

## Theme push, text editing, personalization

Change background colors / background images, text strings (i18n_overrides), purposes, quick replies, and custom recordings from an indoor station or the admin UI, and the CRDT syncs them to every device in milliseconds. Night mode (dimming + red shift), a screensaver, and burn-in-protection pixel shift are also configurable.

Per-device semantic sizing/color overrides are constrained by each renderer's manifest. Native
clients publish top-level `ui_manifest`; the serving Core publishes a distinct local
`web_ui.manifest`. Last-valid native peer contracts are durably cached, so a configured offline
device can be validated/queued when marked `cached_contract:true`, but still needs a later apply
report. Admin cannot edit an offline/remote Web surface when its Web manifest is unknown and does
not fabricate one from a native peer manifest.

## Asset distribution (assets)

Background images and custom recordings (≤3MB) are tracked in a sha256 ledger, and **each device proactively prefetches them the moment they are referenced** (mesh FETCH_BLOB) — playback and display are always from local files, responding in milliseconds. The admin UI shows per-node cache coverage.

## Kiosk anti-theft

- Windows: shell replacement + watchdog foreground guard (pushes back Update pop-ups) + on-screen keypad PIN
- Android: Device Owner full pinning + keyguard disabled
- iOS: supervised + Single App Mode (exit only via Configurator + supervision certificate)
- Offline events may drive Telegram/HA only when matching rules and commissioned integrations
  select them; there is no universal 30-second or delivery guarantee.

## Web panels (legacy support)

Legacy web panels are best-effort until tested on the exact Safari/device. `call.html` requires a
modern secure browser context and configured Asterisk WebRTC.

The iPad 1 compatibility shell has access to the built-in microphone/speaker but no camera. It
requires exact-device commissioning and an explicit external-camera or no-video profile. Its
bounded RTSP/RTP-over-TCP H.264 ingest and Annex-B forwarding are host/loopback-tested, including
loss-to-next-IDR recovery; capability remains degraded until an actual IDR is accepted, and real-camera
iPad qualification is pending. Separately, a bounded Android-to-Core-fMP4-to-iPad device smoke
passed at 15–16 fps on the foreground iPad 1 renderer; unattended post-crash foreground resume is
still open. The optional root helper is implemented and
host-tested, and its iOS 5 lane has a reproducible staged DEB that leaves launchd disabled; it
remains opt-in and hardware-unqualified. See
[iPad 1 provisioning](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.en.md).

## Current artifact gates

- Android API 19 currently has an empty formal SKU allowlist: zero supported SKUs. Its CI artifact
  is a debug-contract build, not a distributable release.
- tvOS has only a tracked unsigned Debug simulator build with real PJSIP; there is no tracked
  Release/device artifact or Apple TV hardware verification.
- iOS 9 arm64 has an unsigned device-link proof. The formal armv7 signing/hardware gate has not
  been commissioned.
- Cross-platform conformance is a golden behavioral model plus source-smoke contracts, not proof
  that every runtime artifact executed the traces.
- iPad 1 has a microphone/speaker but no camera and is not outdoor-rated. Its hardware, enclosure,
  audio, and rollback gates remain open.
- The local, unpushed `ios-legacy-0.2.0-final` tag exists, but `ios-compat` is still untracked in
  this working tree and fresh-clone/device/rollback gates are open. Retain `ios-legacy` unchanged.
