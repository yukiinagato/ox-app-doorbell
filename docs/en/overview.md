# System overview

ox-app-doorbell is a multi-node home doorbell/intercom. Native clients share the C++ core for mesh
membership, replicated configuration/events, rules, HTTP APIs, media publication, and SIP control.
Platform shells provide UI, camera/audio, secure storage, HTTPS, kiosk integration, and measured
runtime capabilities through the versioned `db_platform_v2` ABI.

English is canonical. See [capability status](capability-matrix.md), [deployment](deployment.md),
[configuration](config-schema.md), [security](security.md), [recovery](recovery.md), and
[network ports](network-ports.md).

## Roles and failure boundaries

| Role | Responsibility |
|---|---|
| `door_station` | Visitor UI, ring events, and the media/audio paths actually present on that device. The role does not imply a camera, microphone, outdoor rating, or hardware certification. |
| `indoor_panel` | Targeted ring presentation, monitoring/answer controls, replies, and emergency UI as implemented by the shell. |
| Browser panels | HTTP panel/API clients. Audio calling is conditional on a secure browser context and configured Asterisk WebRTC. |
| Optional integrations | MQTT/Home Assistant, Telegram, Asterisk/PSTN, go2rtc/HomeKit. Their outage still affects actions that depend on them. |

Replicated mesh state can converge without a central database. With suitable rules and real PJSIP,
mesh-native chime/ring state and direct intercom can survive an HA or PBX outage. Telegram, HA,
PSTN, browser WebRTC, and PBX-routed calls still depend on their corresponding services.

## Implemented contracts

- versioned call IDs, targeted schema-v2 chimes, cancellation, recovery reporting, and stale-event
  rejection;
- LWW-map configuration and event replication, runtime capabilities/status, rules, admin/panel APIs,
  assets, MJPEG/snapshots, and fMP4 packaging for encoded H.264 supplied by a verified platform;
- direct or registered SIP when the exact artifact links a real backend; `sipctl_stub` is never a
  product calling path;
- platform secure storage referenced by `secret:` identifiers; persistent config and exports do
  not carry new plaintext credentials;
- bounded platform recovery mechanisms whose limitations are reported rather than hidden.

In the schema-v2 lifecycle, a manual-answer client binds the exact
`door`/`call_id`/`stage_revision` to an answer-mode SIP dialog only. On connection,
`call_answered` records one deterministic `dialog_owner`, cancels the ring timeout, and changes the
matching call to `in_call`; visitor cancellation is then rejected. A losing simultaneous answer
hangs up without ending the winner, and monitor sessions never claim ownership. Owner hangup emits
`call_ended`. Restart recovery belongs to the press origin while ringing and to `dialog_owner`
while in-call; failure within ten seconds emits one global idempotent recovery cancellation.

SOS state always replicates, but recipient/channel presentation is rule-driven and may be empty.
Open Web panels process replicated SOS by default. An administrator can set
`emergency.web_active_page_alerts:false` to disable that raw-state path without disabling a
matching positive `device_alert` or Web Push. Core delivery events describe dispatch attempts;
specifically, `delivery_result` is not presentation proof. Clients separately report per-channel
presentation and limitations. While the raw path is enabled,
a rule TTL expires custom decoration/sound but the safe red raw-SOS overlay remains until clear or
the switch is disabled.

Core durably caches each peer's last-valid native UI manifest/capabilities. A configured offline
device marked `cached_contract:true` can be validated and queued against that cached contract,
but only a later renderer report proves application. Web manifests remain local to the serving
Core node. A legacy alert with no `targets` object addresses all native nodes and Web groups.
Explicit selectors are symmetric: Web-only groups address no native shell, while native-only
selectors address no active Web page or Push subscription. A Web page reads `?group=<name>` and
uses that persisted group for both state polling and Push enrollment. Complete Push subscription
secrets are sealed together in a schema-v2 CRDT record with XChaCha20-Poly1305 under a
mesh-PSK-derived key and never appear as plaintext in configuration/export.

Capabilities are measured and advertised by each shell. A codec being enumerated, a source file
compiling, or an OS version being targeted is not certification.

## Indoor camera preview scheduling

Preview work is bounded by what the panel can present, not by the number of configured doors. One
camera receives a large, aspect-aware tile; two or three divide the usable viewport; larger fleets
use compact tiles and an explicit scroll/page selection. Android refreshes at most three visible
tiles per cycle. Modern iOS pages four tiles, while iPad 1 pages three (one in safe mode). Hidden
tiles do not fetch or decode snapshots.

A `press` or `motion` event promotes that door into the active set. Promotion is unique and
most-recent-first; an event burst can replace only the bounded number of active slots, so it never
starts work for every triggering camera. Residents can override the event set by scrolling on
Android or advancing the numbered camera page on iOS. This is a dashboard scheduling policy only:
all configured doors remain available for direct monitoring.

## Platform summary

| Platform | Source/build scope | Qualification status |
|---|---|---|
| Android | API 21+ modern tier; API 19 armv7/NEON legacy tier with separate NDK/PJSIP caches | A moto g64y 5G/API 34 bounded critical-trim/fMP4 recovery smoke passed. The API 19 qualification list remains empty (zero supported SKUs); CI debug-contract APKs are not releases. |
| Windows | .NET Framework 4.8 WPF shell and x86/x64 native cores | Release gates exist; Windows VM and Toughpad hardware validation remain outstanding. |
| iOS | iOS 12+ Swift shell; iOS 9 arm64 compatibility target; iOS 5.1 armv7 Objective-C shell | iOS 9 arm64 has an unsigned link proof only; armv7's formal gate is uncommissioned. iOS 5 uses `ios-kiosk` and staged `ios-compat` tools. |
| tvOS | Visual monitor/reply plus direct-SIP listen-only source path | Tracked CI proves only an unsigned Debug simulator build with real PJSIP; no Release/device or hardware qualification. No microphone, Answer/transmit unsupported. |
| Web | Admin and resident/visitor panels, same-origin media, active-page SOS, and optional Push | WebRTC calls and Push are conditional; legacy Safari support is best-effort until device-tested. Web and native semantic manifests are separate, and remote Web manifests are not replicated. |

The first-generation iPad has a built-in microphone and speaker but no camera. It can be considered
for an indoor role or an explicitly configured external-camera/no-video door profile only after
real-device testing. It is not outdoor-rated and requires a weatherproof, condensation-controlled,
temperature-managed enclosure for entrance use. Bounded RTSP/TCP H.264 ingest and Annex-B
forwarding are host/loopback verified, but stay degraded until an actual IDR is accepted and remain
unqualified with a real camera on iPad 1. HTTP(S) MJPEG/snapshot direct playback resolves only a
`secret_ref` into ephemeral authorization headers and does not forward JPEG into Core. The optional
fixed-purpose root helper is implemented and host-tested, with a reproducible staged DEB that leaves
launchd disabled; it remains opt-in and unqualified on iOS hardware. Separately, a bounded
Android-to-Core-fMP4-to-iPad smoke passed at 15–16 fps on the real iPad 1 foreground renderer;
unattended post-crash foreground video resume and the broader hardware gates remain open.

## Repository verification entry points

```sh
cmake -S core -B build -DDB_WITH_PJSIP=OFF
cmake --build build -j4
./build/doorbell_tests
python3 tools/gen_i18n.py --check
python3 tools/check_english_source.py
```

Target build commands and release gates are in the platform READMEs and the
[capability matrix](capability-matrix.md). A passing host-core build is not evidence that a signed,
SIP-enabled, hardware-specific artifact passed its release gates.

`tools/conformance/run.py` is a golden reference-model replay plus narrow source-anchor smoke test.
It is useful for protocol drift, but it does not execute client artifacts or prove rendering,
timing, signing, or hardware behavior.
