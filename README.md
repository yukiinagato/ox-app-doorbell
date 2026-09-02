# ox-app-doorbell

A serverless, self-healing doorbell and intercom system for multi-building homes.
It reuses managed Windows tablets, Android devices, Apple devices, and browsers
as door stations, indoor panels, and monitoring displays. The authenticated P2P
mesh is the source of truth. With the required local peers, SIP backend, rules,
and media sources configured, calls, SOS state, and device alerts do not depend
on Home Assistant, MQTT, or Telegram; telephony still depends on the selected
local SIP path.

Documentation: [English](docs/en/overview.md) · [日本語](docs/ja/overview.md) ·
[中文](docs/zh/overview.md)

## Product profiles

| Profile | Minimum target | Intended role | Media status |
|---|---:|---|---|
| Android modern | Android 5.0 / API 21 | door or indoor | Camera2/Camera1, MJPEG, qualified H.264, PJSIP |
| Android legacy19 | Android 4.4 / API 19 | door or indoor, managed sideload | Camera1, MJPEG fallback, H.264 only after per-SKU commissioning, PJSIP |
| iOS modern | iOS 12 | door or indoor | camera, MJPEG/H.264, PJSIP |
| iOS 9 arm64 compatibility | iOS 9, arm64 | door or indoor | shared modern UI; unsigned device-link proof only, signed-device qualification required |
| iOS 5 compatibility | iOS 5.1, armv7 jailbreak | indoor or door | MiniSIP; original iPad uses its microphone/speaker and a LAN IP camera |
| iOS 9 armv7 compatibility | historical SDK/signing lane, not commissioned | planned indoor or door | formal Objective-C compatibility gate exists; no commissioned artifact or hardware result |
| tvOS | tvOS 15 | display, monitor, chime, SOS | no camera or microphone; source supports listen-only SIP, while tracked CI proves only an unsigned Debug simulator build |
| Windows | Windows desktop/tablet | door or indoor | Media Foundation/MJPEG/H.264, PJSIP, service watchdog |
| Web | supported browser | panel, monitor, Admin | active-page alerts plus Web Push when supported; same-origin media proxy |

Capabilities shown by Admin are runtime measurements, not assumptions based on
the OS name. Android 4.4 H.264 support is restricted to commissioned
fingerprint/firmware combinations; the checked-in allowlist currently contains
zero supported SKUs. A bounded moto g64y 5G/API 34 smoke proves modern Android
critical-trim encoder release and same-process fMP4 recovery, but is not an API 19,
OOM-kill, audio, power, thermal, or long-soak qualification. The original iPad has a built-in microphone
and speaker but no camera; a door-station deployment uses a trusted LAN camera
and a weatherproof, condensation-controlled enclosure. Apple did not rate that
device for outdoor installation. A bounded real-device smoke now proves the
foreground Android-to-Core-fMP4-to-iPad H.264 renderer at 15–16 fps; it does not
qualify the separate RTSP ingest path, unattended background relaunch, audio,
power, enclosure, or long-soak gates.

The old `ios-legacy` UI is frozen at the local, unpushed
`ios-legacy-0.2.0-final` archival tag. Neutral iOS 5 build, package, install,
MiniSIP test, and recovery tooling is staged in the currently untracked
`ios-compat` tree; fresh-clone, real-device, and rollback gates have not passed,
so `ios-legacy` remains in this working tree. The
current, test-backed matrix is maintained in
[docs/en/capability-matrix.md](docs/en/capability-matrix.md); a successful
hosted build is a contract check, not legacy-device certification.

## Behavior sources of truth

- `core/include/doorbell/doorbell.h`: versioned C ABI and platform ownership
  contract (`db_platform_v2`).
- Core schema-v2 events and `docs/en/config-schema.md`: call identity, timeout,
  cancellation, SOS state, rules, capabilities, runtime health, media sources,
  secret references, and semantic UI overrides.
- `i18n/strings.yaml`: Japanese, English, and Chinese application strings.
- Runtime `capabilities`, `ui_manifest`, and `runtime` status: features that a
  specific artifact and device actually measured.

Visitor calls default to `purpose_first`; Admin can select
`ring_then_purpose`. A targeted schema-v2 `chime` is the only event that opens
an indoor incoming-call UI. Raw replicated `press` events update state and
history without ringing twice. A visitor cancellation is global and
idempotent; a resident's Ignore action remains local.

For a manual resident answer, the client binds the exact
`door`/`call_id`/`stage_revision` only to an answer-mode SIP dialog and reports
`call_answered` after that dialog is connected. Core records one deterministic
`dialog_owner`; a losing simultaneous answer hangs up without reporting the
winner as ended, and monitor sessions never claim call ownership. Visitor
cancellation is rejected after the transition to `in_call`; owner hangup emits
`call_ended` for that exact call. After restart, a ringing call is recoverable
by its press origin and an in-call dialog by its recorded owner. Either must
recover within ten seconds or Core emits one idempotent global recovery
cancellation.

SOS active/clear state always replicates across Core nodes. Device presentation
and external recipients are rule-driven and may be configured down to zero.
Admin warns about silent, offline, unsupported-channel, or empty results but
does not block the administrator's choice. `emergency.web_active_page_alerts`
separately controls whether open Web panels render replicated SOS state. It
defaults to `true`, so raw active SOS takes precedence over a zero-recipient,
Push-only, or stale negative rule projection. When set to `false`, an open Web
panel still presents a matching positive `device_alert`, and Web Push can still
present SOS when delivered. Active-page and Push presentation honor validated
visual, sound, volume, sticky, TTL, background, foreground, and accent values.
Push preserves those fields; an open panel renders the color/audio presentation,
while browser/OS notification APIs may limit custom colors, sound, or volume.
While raw active-page SOS is enabled, a rule TTL expires its decoration and sound
but the safe red overlay stays until SOS clear or the switch is disabled. A
legacy `device_alert` without a `targets` object addresses all native nodes and
Web groups. Explicit targets are symmetric: Web-only groups address no native
shell, and native-only selectors address no active Web page or Push subscription.
Web pages obtain `?group=<name>` once and use that same persisted group for poll
projection and Push enrollment.

Complete Web Push endpoints and `p256dh`/`auth` keys are sealed in one schema-v2
CRDT record with XChaCha20-Poly1305 under a mesh-PSK-derived key. They never
appear as plaintext in configuration/export; startup reseals legacy raw records
or removes them fail-closed.

Core durably caches each peer's last valid native UI manifest/capabilities.
Configured offline devices can therefore be edited against a status marked
`cached_contract:true`, but apply is not successful until that renderer
reconnects and reports. The separate Web manifest remains local to the serving
Core node and is not a remote/offline Web catalog.

Core `delivery_result` events report dispatch attempts (for example, callback
dispatch or Push-provider acceptance), not proof that a person saw an alert.
Native clients separately report per-channel presentation, permission, expiry,
and limitation results in runtime status.

## Build and test

```sh
# Core and Web contracts
cmake -S core -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDB_WITH_PJSIP=OFF
cmake --build build -j4
./build/doorbell_tests

# Generated localization must be current
python3 tools/gen_i18n.py --check

# Android modern and API 19 lanes use different pinned NDK/PJSIP caches
(cd android && ./gradlew --no-daemon -PdoorbellTier=modern \
  assembleModernDebug testModernDebugUnitTest lintModernDebug)
(cd android && ./gradlew --no-daemon -PdoorbellTier=legacy19 \
  assembleLegacy19Debug testLegacy19DebugUnitTest lintLegacy19Debug)

# iOS 5 compatibility host and armv7 gates
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_app_ios5.sh
```

Release artifacts must contain a real SIP backend and, where advertised, real
H.264 symbols. CI checks ABI layout, configuration round trips, semantic UI
constraints, secret leakage, proxy authentication, and lane-specific artifact
metadata. The cross-platform conformance job replays a golden reference model
and checks narrow source anchors; it does not execute each client artifact or
prove UI timing/rendering. Android CI uploads debug-contract APKs signed with a
debug key, not releases. The tracked Apple job builds modern iOS/tvOS Debug
simulators and an unsigned iOS 9 arm64 device-link proof; hardware, signing, and
long-soak gates remain separate.

## Security and recovery

Secrets are written through Keychain, Android Keystore, or DPAPI and referenced
as `secret:<name>`; do not place credentials in URLs, events, logs, or
`boot.json`. Configuration batches are validated before one atomic CRDT/storage
commit, and clients preserve fields they do not understand.

Every client publishes crash generation, heartbeat, last-exit evidence,
safe-mode state, codec health, and recovery limitations. Recovery uses bounded
queues, component-level restart, 2/5/10/30/60-second backoff, and safe mode
after three failures in five minutes. Where the operating system permits it,
the optional root-helper design uses a fixed-purpose Unix socket and a fixed
app command; it provides no shell or TCP management interface and never reboots
the whole OS automatically. Helper artifacts are not considered available
until their host tests and target-device installation gate pass. Stock
iOS/tvOS instead rely on supervised Single App Mode/MDM and cannot promise
automatic relaunch in every failure mode.

See [AGENTS.md](AGENTS.md) for repository rules and build constraints. Do not
push code, tags, releases, Wiki changes, or deployment state without explicit
authorization.
