# FAQ — Common Questions and Realistic Answers

> English (this page) / 日本語: [FAQ-ja](FAQ-ja) / 中文: [FAQ-zh](FAQ-zh)

For platform and hardware answers, the [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md), [security guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/security.md), and [recovery guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/recovery.md) take precedence.

## Failures and troubleshooting

### Q1. The chime doesn't ring. Where do I start?

Isolate in order: (1) On the admin dashboard, are the door station and indoor station **online**, with no time-sync warning? (2) Is a press **recorded** in the event history — if it is, "the ring arrived, the problem is in the actions"; if not, it is a device/mesh problem. (3) Is the call rule enabled, does it match the target door, and is the chime being suppressed by quiet_hours? (4) If only the phone fails to ring, check the Asterisk side (`pjsip show endpoints` / `pjsip show registrations`).

### Q2. What happens if Home Assistant goes down?

Implemented mesh-local paths can continue. HA automations, HA/HomeKit notifications, and any HA-hosted media stop. Telegram and PBX paths have their own dependencies. Test the exact deployment rather than assuming full operation.

### Q3. And if Asterisk goes down?

Configured direct SIP bypasses Asterisk, so that path can continue when the exact artifacts use real SIP and the peers remain reachable. PBX-routed extensions/mobile calls and browser WebRTC stop with Asterisk. → [Architecture](Architecture)

### Q4. Anything to do after recovering from a power outage?

Verify that every node actually restarted, rejoined, resolved its secure-store references, and reports the expected capabilities. Then test ring/audio/media/integrations; follow the [recovery guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/recovery.md).

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

**No.** Continuous recording is outside the design boundary ([Design Philosophy](Design-Philosophy)). Event snapshots and history remain; external recording is a separately commissioned go2rtc/HA responsibility.

### Q10. What about Windows Update?

Windows Update on door stations is blocked by provisioning (and the watchdog pushes back its pop-ups). Do not neglect it — **apply it manually on maintenance days** (`deploy/provision/windows/provision.cmd` §6). It is the operational middle ground between "an unattended update bricks the entrance" and "unpatched forever".

### Q11. The app on an iOS device suddenly won't launch

Almost certainly the **annual expiry of the Ad Hoc profile**. Reinstall a re-signed ipa with Apple Configurator. The deadline is announced by the in-app display and Telegram's 30-day advance warning. The permanent fix is App Store (unlisted) publication (planned for Phase 7).
→ [deploy/provision/ios/provision.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/provision.ja.md)

### Q12. A device was stolen/lost. What should I do?

Isolate/remove the device, rotate the mesh PSK and every SIP, MQTT, Telegram, WebRTC, media, admin, and panel credential/token it could access, then re-pair remaining nodes. Verify old values and the removed node are rejected. See the [security guide](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/security.md).

### Q13. How do I back up? How many devices can I add?

Admin UI export captures replicated configuration but intentionally omits secret values. Back up artifact manifests/packages and recover device-local secrets separately. Capacity depends on the commissioned devices and integrations.

## Devices and compatibility

### Q14. What can an iPad 1 (iOS 5) do?

Two options.

**(A) Compatibility native shell**: the iPad 1 has a built-in microphone and speaker but no camera. The shell, MiniSIP, direct HTTP(S) MJPEG/snapshot, bounded RTSP-over-TCP H.264, and no-video profiles exist, but audio, recovery, and the final enclosure require exact-device commissioning. The H.264 ingest and Annex-B forwarding path passes the host/loopback contract; capability stays degraded until DESCRIBE/SETUP and an actually accepted IDR, and no real camera has passed iPad qualification. Separately, a bounded Android-to-Core-fMP4-to-iPad smoke passed at 15–16 fps on the foreground renderer; unattended post-crash foreground video resume is still open. The optional root helper is implemented and host-tested, and its iOS 5 lane has a reproducible staged DEB that leaves launchd disabled; it remains opt-in and unqualified on iPad hardware. Steps: [iPad 1 provisioning](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/provision/ios/ipad1-jailbreak.en.md).

The original iPad is not outdoor-rated. Do not treat this compatibility target as a qualified outdoor station until the exact camera, audio, thermal, weather-resistant enclosure, power, recovery, and helper combination has passed hardware commissioning.

**(B) Don't want to jailbreak → the traditional web panel (best-effort)**: open the web panels in Safari and add them as Web Clips: `door.html` = ring panel (no audio, notification only), `monitor.html` = call monitor. Two-way calling (`call.html`) needs a modern browser + the WebRTC gateway, so it is not possible. Either way, set auto-lock to "never" and keep it permanently powered.

### Q15. What are the minimum supported OS versions?

Build targets and qualification are different. See the [capability matrix](https://github.com/yukiinagato/ox-app-doorbell/blob/main/docs/en/capability-matrix.md). In particular, the Android API 19 production allowlist is currently empty, so there are **zero supported API 19 SKUs**. The tracked Android job is a debug-contract build, not a releasable or hardware-qualified artifact.

### Q16. Can I monitor on an Apple TV?

The intended tvOS boundary is listen-only because Apple TV has no microphone. Current tracked evidence is limited to an **unsigned Debug arm64 simulator build linked with real PJSIP**. There is no tracked Release build, signed device artifact, Apple TV run, or hardware/audio qualification, so do not treat tvOS monitoring as release-supported yet. HomeKit camera display/home-hub use is a separate integration.

### Q17. I want to call from a browser but the microphone won't work

A browser's getUserMedia is **HTTPS-only**. The stations' panels are plain HTTP, so either put up a reverse proxy like Caddy with an internal CA, or set Chrome's insecure-origin exception on the specific home devices only.
→ [deploy/asterisk/webrtc.ja.md](https://github.com/yukiinagato/ox-app-doorbell/blob/main/deploy/asterisk/webrtc.ja.md)

### Q18. I silenced the chime at night, but it disagrees with Asterisk's night branching

quiet_hours is judged by **the app's corrected clock**, while the dialplan's GotoIfTime is judged by **the Asterisk server's clock**. If you configure night behavior in both places, align the times and verify NTP.

### Q19. Does pressing SOS call the police?

**No.** SOS never calls police or fire services automatically. `emergency_on` and `emergency_off` state is replicated to every Core node, but recipients and presentation are selected entirely by rules. A deployment may target devices, roles, Web subscription groups, Telegram, MQTT, or user-defined SIP destinations; it may also deliberately have zero recipients or be silent.

For an open Web page, `emergency.web_active_page_alerts` defaults to `true`: active/clear state is rendered even when rules have zero recipients or select Push only. If an administrator turns it off, Web still processes a positively matched `device_alert` or a Push that is actually delivered. While it is on, a rule TTL can stop custom decoration/sound but the safe red overlay remains until clear. Explicit native-only targets do not reach Web; the page's persisted `?group=` selects both poll and Push delivery. Clearing SOS requires the configured PIN/permission. In diagnostics, `delivery_result` records only a Core dispatch attempt; the client runtime's per-channel report is the evidence that a visual, sound, or system notification was actually presented.
→ [Usage-Residents](Usage-Residents) / [Design Philosophy](Design-Philosophy)

### Q20. What if multiple entrances ring at the same time?

The bottleneck is the HGW extension's concurrent call count (usually 2). On the app side, the leader arbitrates and serializes outbound calls, and you can additionally control it with a Queue in the dialplan. Mesh-local and external actions are still selected by their matching rules; do not assume that chimes, indoor displays, or Telegram run for every entrance unless the configured rules say so.
