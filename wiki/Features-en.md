# Feature Overview

> 日本語: [Features](Features) / 中文: [Features-zh](Features-zh)

A short summary of "what each feature can do". For usage see [Usage-Residents](Usage-Residents-en) / [Usage-Admin](Usage-Admin-en) / [Usage-Visitors](Usage-Visitors-en); for how things work see [Architecture](Architecture-en).

## Calling (ringing)

A visitor rings with the door station's large button (generic) or with one tap on a purpose button. The event enters the rule engine, which runs SIP calls / Telegram / HA events / indoor chimes / auto-reply in parallel, exactly as configured. Rules can branch per door, per purpose, and per time of day. → [Usage-Admin](Usage-Admin-en)

## Purpose buttons (visit_purposes)

Visit / Parcel delivery / Mail / Sales & collection / Meter reading & construction / Other — 6 defaults, freely editable. A courier completes the whole ring with one tap on "Parcel delivery". The purpose is shown everywhere — indoor stations, TV, Telegram, HA, admin UI — and can also be used as a rule branch condition (`when.purposes`). → [Usage-Visitors](Usage-Visitors-en)

## Visitor language switching

The door station shows language buttons (Japanese/English/Chinese — chosen via `ui.languages`). When a visitor switches, a badge propagates to all nodes, and **quick replies are displayed and spoken in the visitor's language**. After 60 seconds of inactivity (configurable) it automatically reverts to Japanese. → [Usage-Visitors](Usage-Visitors-en)

## Intercom (three modes) and answer takeover

Direct SIP (UDP 47190), bypassing Asterisk, in three modes: (1) audio only, (2) door video + two-way audio, (3) two-way video both ways (symmetric MJPEG). Even after answering on the phone, pressing "Answer" on an indoor station **takes over** the call — the phone leg is dropped and indoor intercom takes its place. Works even when the PBX is down. → [Architecture](Architecture-en)

## Monitoring

From an indoor station or Android TV, a one-way call to the door station with `X-Doorbell-Mode: monitor` — check the door's audio and video without being noticed. When the bell rings, the TV automatically brings up full-screen live video plus monitoring.

## Quick replies

Canned phrases like "We are out at the moment" (multilingual, customizable, ordered) can be sent from an indoor station / TV remote / Telegram inline buttons / HA / web pages → shown in large text on the door station and read aloud. Speech falls back in order: custom recording (registerable per visitor language) → system TTS → notification tone.

## Auto-reply (auto_reply)

As a rule action, the door station can display and speak a quick reply automatically, with no human answering. The classic recipe: "for parcel delivery, auto-play 'Please leave the package' and don't ring the phone". → [Usage-Admin](Usage-Admin-en)

## Phone integration (Asterisk + Hikari Denwa)

A bell press rings indoor extensions and your mobile (PSTN) simultaneously. In-call DTMF feature codes are supported (*1 = unlock etc., actions configurable). The distribution logic can be freely changed on the dialplan side.
→ [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md)

## Notifications

- **Telegram**: pushes each ring with a photo + purpose + visitor-language badge. Inline buttons reply instantly.
- **Home Assistant** (MQTT Discovery): doorbell event / motion / device online / bridge liveness / emergency / visitor-language sensors appear automatically. Actionable-notification snippets are included.
- **Indoor chime**: supports custom sounds (`asset:<sha256>`).
- Only the leader node sends externally, preventing duplicate notifications.

## SOS (emergency call for help)

Long-press on an indoor station (default 3 s) → all-node alarm UI + siren + Telegram 🚨 + MQTT (HA integration possible). Dismissing requires the kiosk PIN. No automatic calls to police or fire services. → [Design-Philosophy](Design-Philosophy-en)

## Motion detection

Motion is detected from the door station camera's frame bus and fed into rules (e.g. night-only Telegram + HA). Sensitivity and minimum interval are adjustable per device.

## Video — MJPEG baseline + H.264 smooth tier

The default is MJPEG, which displays on every device and browser. Devices with a hardware encoder can serve HW-encoded fMP4 (`/stream.mp4`) via `codec: auto/h264` — call video becomes smooth, and transcoding on the HA side becomes unnecessary (go2rtc `#video=copy`). The encoder stops when there are zero subscribers — a power-saving design. → [Decisions](Decisions-en)

## HomeKit integration

Via go2rtc + HA's HomeKit Bridge, doorbell notifications and live video appear in the iPhone Home app. With a home hub (Apple TV / HomePod) you can also watch while away.
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

## Theme push, text editing, personalization

Change background colors / background images, text strings (i18n_overrides), purposes, quick replies, and custom recordings from an indoor station or the admin UI, and the CRDT syncs them to every device in milliseconds. Night mode (dimming + red shift), a screensaver, and burn-in-protection pixel shift are also configurable.

## Asset distribution (assets)

Background images and custom recordings (≤3MB) are tracked in a sha256 ledger, and **each device proactively prefetches them the moment they are referenced** (mesh FETCH_BLOB) — playback and display are always from local files, responding in milliseconds. The admin UI shows per-node cache coverage.

## Kiosk anti-theft

- Windows: shell replacement + watchdog foreground guard (pushes back Update pop-ups) + on-screen keypad PIN
- Android: Device Owner full pinning + keyguard disabled
- iOS: supervised + Single App Mode (exit only via Configurator + supervision certificate)
- All platforms: a Telegram/HA notification within 30 seconds of going offline (detecting device theft or disconnection)

## Web panels (legacy support)

`door.html` (ring) / `monitor.html` (call monitor) work even on an iPad 1 with iOS 5 Safari.
`call.html` (two-way calling) requires a modern browser + the Asterisk WebRTC gateway (an optional feature).
