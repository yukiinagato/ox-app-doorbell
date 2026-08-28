# FAQ — Common Questions and Realistic Answers

> 日本語: [FAQ](FAQ) / 中文: [FAQ-zh](FAQ-zh)

## Failures and troubleshooting

### Q1. The chime doesn't ring. Where do I start?

Isolate in order: (1) On the admin dashboard, are the door station and indoor station **online**, with no time-sync warning? (2) Is a press **recorded** in the event history — if it is, "the ring arrived, the problem is in the actions"; if not, it is a device/mesh problem. (3) Is the call rule enabled, does it match the target door, and is the chime being suppressed by quiet_hours? (4) If only the phone fails to ring, check the Asterisk side (`pjsip show endpoints` / `pjsip show registrations`).

### Q2. What happens if Home Assistant goes down?

**The doorbell keeps working in full.** Ring display, chimes, indoor intercom, Telegram, and the phone are untouched. Only HA-mediated features are lost (HomeKit notifications, HA automations, go2rtc video). When HA comes back, the MQTT bridge reconnects automatically and re-publishes discovery and all states.

### Q3. And if Asterisk goes down?

Intercom and monitoring use direct SIP that bypasses Asterisk, so **they just keep working**. What dies is only the phone leg (extensions, calls to mobiles, DTMF unlock) and web-browser calling. → [Architecture](Architecture-en)

### Q4. Anything to do after recovering from a power outage?

In principle, no. Each device auto-starts (shell replacement / Device Owner / SAM), rejoins the mesh, and the configuration converges on its own because it is a CRDT. Until NTP sync completes, time-dependent features (schedules, night mode) may be off — wait for the dashboard's "time not synced" warning to clear. If the HGW/Asterisk is slow to recover, phone-leg re-registration relies on retries (60-second interval).

### Q5. Notifications are oddly slow after a ring

Only the leader sends Telegram/MQTT. Right after a leader change there can be a gap of a few seconds. If it is consistently slow, check whether the leader has landed on a weak battery-powered device, and steer leader eligibility to a mains-powered device with `caps_override: { "mains_power": true }`.

### Q6. The visitor language doesn't revert to Japanese / reverts on its own

By design: after `ui.visitor_lang_revert_s` seconds of inactivity (default 60) it auto-reverts to Japanese, and a ring extends the timer. If it will not revert, check whether rings or touches keep coming, or whether the setting is extremely large. A visitor choosing `lang=ja` reverts it immediately.

### Q7. I enabled H.264 (smooth video) but nothing shows

That device may have no hardware encoder. With `codec: auto`, a failed hardware probe means it has fallen back to MJPEG, and `/stream.mp4` returns 503. Rewrite the go2rtc source line for mjpeg (`#video=h264#hardware`). Also, `/stream.mp4` starts its encoder only after a subscriber attaches, so the first view takes a few seconds.
→ [deploy/ha/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/ha/README.ja.md)

### Q8. Pressing *1 during a call doesn't unlock the door

On the PSTN→HGW leg, DTMF is often inband and model-dependent. Test whether Asterisk's DSP detection (the current setup) picks it up; if not, try rfc4733.
→ the notes in [deploy/asterisk/README.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/README.ja.md)

## Operations

### Q9. Is it recording?

**No.** Continuous recording is outside the design boundary ([Design-Philosophy](Design-Philosophy-en)). What remains is only event-time snapshots and the event history. If you want recordings, record `/stream.mjpeg` or `/stream.mp4` on the go2rtc/HA side — the system will not stop you.

### Q10. What about Windows Update?

Windows Update on door stations is blocked by provisioning (and the watchdog pushes back its pop-ups). Do not neglect it — **apply it manually on maintenance days** (`deploy/provision/windows/provision.cmd` §6). It is the operational middle ground between "an unattended update bricks the entrance" and "unpatched forever".

### Q11. The app on an iOS device suddenly won't launch

Almost certainly the **annual expiry of the Ad Hoc profile**. Reinstall a re-signed ipa with Apple Configurator. The deadline is announced by the in-app display and Telegram's 30-day advance warning. The permanent fix is App Store (unlisted) publication (planned for Phase 7).
→ [deploy/provision/ios/provision.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md)

### Q12. A device was stolen/lost. What should I do?

(1) In the admin UI's "System" tab, **reissue the PSK** → re-pair all remaining devices (the stolen device can no longer join the mesh). (2) Rotate the SIP password and the Telegram bot token. (3) Rotate the panel token. Note that on-device secrets live in the secure store (DPAPI/Keystore/Keychain) — nothing is in the configuration CRDT in plain text. The theft itself is noticeable via the "⚠ offline" notification (within 30 seconds).

### Q13. How do I back up? How many devices can I add?

Admin UI "System" → Export gives you the full JSON from any node. Day-to-day survivability, however, is guaranteed by distribution — one surviving device is enough to restore the configuration. The practical limits on device count are rather the Asterisk/HGW concurrent call count (usually 2) and Ad Hoc's UDID cap (100 devices/year).

## Devices and compatibility

### Q14. What can an iPad 1 (iOS 5) do?

Open the web panels in Safari and add them as Web Clips: `door.html` = ring panel (no audio, notification only), `monitor.html` = call monitor. Two-way calling (`call.html`) needs a modern browser + the WebRTC gateway, so it is not possible. Set auto-lock to "never" and keep it permanently powered.

### Q15. What are the minimum supported OS versions?

Windows 7 SP1 (needs .NET Framework 4.8 + the TLS1.2 patch — provisioning sets this up) / Android 5.0 (4.4 via the legacy path) / iOS 12 (9 via legacy) / browsers down to iOS 5 Safari.
→ the per-device support table in [docs/ja/overview.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/ja/overview.md)

### Q16. Can I monitor on an Apple TV?

Apple TV works primarily through HomeKit (camera display in the Home app, home hub). The native tvOS app supports video display; SIP monitoring is not yet implemented (TODO). If you want a full-featured TV monitoring endpoint, use Android TV (full-screen on ring + direct monitoring + D-pad replies).

### Q17. I want to call from a browser but the microphone won't work

A browser's getUserMedia is **HTTPS-only**. The stations' panels are plain HTTP, so either put up a reverse proxy like Caddy with an internal CA, or set Chrome's insecure-origin exception on the specific home devices only.
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. I silenced the chime at night, but it disagrees with Asterisk's night branching

quiet_hours is judged by **the app's corrected clock**, while the dialplan's GotoIfTime is judged by **the Asterisk server's clock**. If you configure night behavior in both places, align the times and verify NTP.

### Q19. Does pressing SOS call the police?

**No.** Recipients are the family (Telegram/all-node alarm) and, if configured, user-defined phone numbers only. The decision to report is made by a human, by design. Dismissal requires the kiosk PIN.
→ [Usage-Residents](Usage-Residents-en) / [Design-Philosophy](Design-Philosophy-en)

### Q20. What if multiple entrances ring at the same time?

The bottleneck is the HGW extension's concurrent call count (usually 2). On the app side, the leader arbitrates and serializes outbound calls, and you can additionally control it with a Queue in the dialplan. The in-home side (chimes, indoor stations, Telegram) runs in parallel for every entrance as usual.
