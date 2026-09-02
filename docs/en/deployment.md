# Deployment guide

Use this checklist only after selecting targets in the [capability matrix](capability-matrix.md).
Compilation is not hardware certification. Commission each exact device, OS/firmware, media path,
enclosure, and signed artifact before relying on it.

## 1. Prepare the trusted network and integrations

- Place nodes on a trusted LAN and restrict the ports listed in [network ports](network-ports.md).
  Use a maintained VPN or authenticated TLS reverse proxy for remote access; do not expose node
  HTTP, mesh, MiniSIP, MQTT, or camera endpoints directly to the Internet.
- Configure Asterisk, MQTT/Home Assistant, Telegram, go2rtc, and HomeKit only if required. Treat
  each as an optional failure boundary and test behavior with it stopped.
- Inspect device batteries and power supplies. An entrance device needs a suitable outdoor
  enclosure; a software `door_station` role is not a weather rating.

## 2. Build and qualify artifacts

- Run the common checks in [overview](overview.md), then the exact platform build and release gate.
- Product artifacts must link real PJSIP and identify their target, architecture, minimum OS/API,
  dependency hashes, source/build identity, and signing identity where applicable.
- Keep modern Android and API 19 NDK/PJSIP caches separate. Do not mark API 19 hardware-certified
  until its exact fingerprint passes `android/README.md` commissioning.
- Treat Windows VM/Toughpad and iOS 9 hardware validation as pending until a controlled run is
  recorded. Use [the iOS compatibility runbook](ios-compat-maintainer.md) for iOS 5.

## 3. Pair without plaintext secrets

1. Start one qualified native node and create or join the cluster through the application/admin
   pairing flow.
2. Invite each additional device with the bounded pairing flow and verify its identity before
   approval.
3. Confirm Core successfully called `secure_put("mesh.psk", …)` before emitting
   `{t:"paired", psk_ref:"secret:mesh.psk"}`, and that the shell persisted only that reference plus
   non-secret bootstrap fields in `boot.json`. `pairing_persistence_error` must remain not-ready.
4. Enter SIP, MQTT, Telegram, WebRTC, and camera credentials through secure-storage-aware UI/API
   paths. Configuration must contain `secret:` references, never values.
5. For Web Push, provision the VAPID private value—and the optional sender bearer value—under the
   same replicated references in every intended `web_push` leader candidate's local secure store.
   Then atomically save the HTTPS sender URL, VAPID public key/subject, and secret references shown
   in [the configuration schema](config-schema.md). Confirm status reports a non-empty Push leader
   and `delivery_backend:true`; `configured:true` by itself is not readiness.
6. Because shipping shells publish `wan:false` without a configured endpoint probe, test HTTPS
   egress to the exact sender from each intended candidate and only then set that node's explicit
   `caps_override.wan:true`. Record the test and remove the override after network changes. A Push
   leader also requires measured `tls12`, `mains_power`, `wall_clock_sane`, and `web_push_ready`.

Never copy a cluster PSK, password, token, URL userinfo, or signing secret into `boot.json`, CRDT
JSON, a command line, a log, or documentation. Legacy `psk_hex` is migration input only.

## 4. Configure roles and behavior

- Assign node name, `door_station` or `indoor_panel`, door/building, language, rules, and only the
  capabilities measured by that shell.
- Configure camera sources explicitly. A seed peer is not a camera. iPad 1 has a built-in
  microphone/speaker but no camera; use an explicit MJPEG/snapshot/RTSP source or honest no-video
  mode. Its bounded RTSP/TCP H.264 ingest and Annex-B forwarding are host/loopback verified, but
  runtime must stay degraded until an IDR is accepted and real-camera hardware qualification is pending.
- Configure panel tokens as scoped secrets and distribute them only through an approved channel.
- Keep safety actions explicit: SOS does not automatically contact emergency services; unlock and
  external notifications require the configured controller/integration.
- Configure SOS targets, channels, and presentation explicitly. Review the non-blocking dry-run
  warnings for zero recipients, silence, unsupported/unavailable or rolling-upgrade-unknown
  channels, and missing Push subscriptions/backend. Record the administrator's
  `emergency.web_active_page_alerts` choice. For each Web group, verify that `?group=` drives both
  polling and Push, native-only targets do not reach Web, raw-SOS remains after rule TTL until
  clear, and config/export contains no plaintext Push endpoint or key material.

## 5. Commission every node

Verify and record:

- artifact manifest/signature and runtime `sip_backend`, capabilities, status, and UI manifest;
- targeted ring, cancel, purpose update, answer, hangup, quick reply, DTMF/unlock success and
  failure, SOS activation/cancel, and stale/duplicate event rejection;
- camera/audio routes, rotation, color, MJPEG fallback, codec startup/stall behavior, and AEC on the
  actual hardware;
- integration behavior both available and unavailable;
- Core `delivery_result` dispatch evidence separately from each client channel's actual
  presentation/permission/limitation report;
- Wi-Fi/LAN loss, peer loss, process crash/hang, memory pressure, service suppression, reboot,
  power loss, repeated-failure safe mode, and rollback;
- kiosk escape/maintenance procedure, thermal behavior, battery/power safety, and long-duration
  soak in the final enclosure.

The optional iOS root keepalive helper is implemented, host-tested, and has a reproducible staged
armv7/iOS 5.1 DEB that does not enable launchd. Treat it as unavailable unless its explicit opt-in
workflow and the exact binary, root-owned launchd configuration, permissions, maintenance lease,
safe mode, rollback, and device soak are commissioned.

## 6. Operate and recover

Keep the prior signed artifact and manifest in a separate rollback lane. Export replicated config
regularly, but remember exports omit secret values. Track signing/profile expiry and maintenance
windows. Follow [recovery](recovery.md) for rollback and [security](security.md) for credential
rotation after device loss or suspected disclosure.
