# Capability and release-status matrix

This page is the status authority for platform and deployment claims. A feature being present in
source does not by itself make a device or release production-ready.

## Status terms

| Term | Meaning |
|---|---|
| Implemented | The path exists in the current source and has relevant automated contract coverage. |
| Build-verified | The exact target artifact passed its target build, ABI, dependency, and packaging gates. |
| Hardware-certified | A recorded device/OS/firmware combination passed the commissioning and soak checklist. |
| Unsupported | The path is absent, deliberately disabled, or must not be advertised by a client. |

Build verification is artifact-specific. Hardware certification is device-specific; it cannot be
inferred from compilation, an emulator, a codec list, or a platform version.

## Current matrix

| Target or capability | Current status | Evidence and limit |
|---|---|---|
| Core mesh, CRDT, HTTP APIs, event/rule engine, call lifecycle, MJPEG/fMP4 container, ABI v2 | Implemented | Core tests and `core/include/doorbell/doorbell.h`; schema-v2 `call_answered`/`call_ended` are call-ID scoped and production clients use `db_platform_v2`. |
| SIP in a release artifact | Conditional | Release artifacts must report `pjsip`. A `stub` build is development/display-only and unsupported for calling. |
| Android API 21+ | Implemented; build lane defined | `modern` Gradle tier, NDK r27, unit tests and lint. No blanket hardware certification. |
| Android modern critical-memory recovery | Bounded exact-device smoke passed; not hardware-certified | On a moto g64y 5G/API 34, a real `RUNNING_CRITICAL` trim kept the same process and foreground Activity, recorded encoder release, then recreated `c2.mtk.avc.encoder` and served valid 640×360 fMP4 after the 30-second protection window. See [the 2026-08-31 evidence record](../evidence/android-modern-memory-pressure-smoke-2026-08-31.md). OOM kill, in-call audio, power, thermal, and soak remain open. |
| Android API 19 armv7/NEON | Implemented; build lane defined; zero supported SKUs | Dedicated `legacy19` tier and NDK r25c. The source-controlled qualification list is empty. A device remains uncommissioned until its exact fingerprint and evidence artifact pass the codec, recovery, thermal, SIP, and eight-hour soak gates in `android/README.md`. CI's debug-key `debug-contract` APK is not a release. |
| Windows x86/x64 WPF | Implemented; hosted contract/stub compile and opt-in self-hosted release gates defined; validation pending | Hosted CI does not upload its explicit stub build. Only the commissioned self-hosted real-PJSIP x86/x64 job may upload a release bundle. There is still no evidence here of a completed VM or Toughpad hardware certification run. |
| iOS 12+ | Implemented; hosted simulator and unsigned device-link gates defined; signed-device validation required | Hosted CI builds keyed real-PJSIP simulator and iPhoneOS archives, the iOS 12 simulator contract, and an unsigned arm64 device binary. Camera/audio, supervised kiosk, recovery, signing, installation, and soak still require the release device. |
| iOS 9 arm64 | Unsigned device-link proof defined; not install/device-validated | It shares modern Swift through availability adapters. The tracked gate builds an unsigned `iphoneos` arm64/9.0 Release binary and verifies ABI v2, minimum OS, real-PJSIP symbols, and back-deployed Swift libraries. It does not sign, install, launch, or exercise hardware. |
| iOS 9 armv7 | Formal profile/gate implemented; not commissioned | The historical Xcode 7/SDK, real-PJSIP, stock-IPA and jailbreak-package gates exist under `ios-compat`, but no commissioned runner artifact or real-device result is recorded. |
| iOS 5.1 armv7 compatibility shell | Implemented; hosted contracts and opt-in licensed self-hosted artifact gate defined; hardware certification pending | `ios-kiosk` plus `ios-compat`; only the licensed runner creates/uploads the armv7 app/package. iPad 1 has a built-in microphone and speaker but no camera. |
| iPad 1 Core fMP4/H.264 playback | Bounded exact-device smoke passed; not hardware-certified | An Android 14 door station fed Core `/stream.mp4`; the iPad 1 foreground renderer sustained 15–16 fps with 20–33 ms observed latency, survived Wi-Fi rejoin and safe-mode exit, and returned on matching cancellation. Process-crash call identity/UI recovery passed, but without the optional helper the relaunched process remained background-only and video did not resume unattended. See [the 2026-08-31 evidence record](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md). |
| iPad 1 external IP-camera MJPEG/snapshot | Implemented with limits | Explicit `media_sources` binding only. HTTP(S) MJPEG and snapshot are played directly in the shell; URL credentials are forbidden, `secret_ref` is resolved only into ephemeral Basic/Bearer headers, and platform TLS validation applies. JPEG stays local (`jpeg_core_forwarding:false`), so it is not a fleet camera feed. |
| iPad 1 RTSP/TCP H.264 ingest and forwarding | Implemented; host/loopback contract verified; hardware-unqualified | The bounded path parses SDP/`sprop-parameter-sets`, handles single NAL/STAP-A/FU-A RTP, waits for the next IDR after loss, and forwards Annex-B to Core. Runtime remains degraded as `rtsp_ingest_pending` and does not advertise `rtsp_h264_forwarding` until DESCRIBE/SETUP succeed and Core accepts an actual IDR. No real camera has completed iPad 1 qualification. |
| Optional iOS/rooted-Android keepalive helper | Implemented; host-tested; hardware-unqualified | Fixed local Unix transports, fixed compiled launch profiles, peer/PID checks, persisted `off|auto|on`, maintenance lease, atomic status, 2/5/10/30/60-second backoff, and crash-loop safe mode are implemented under `tools/helper`. Persisted `auto`/`on` cold-launch after helper restart; `off` disarms without killing an already-running app. Configured mode is only a request; measured availability/effective mode governs advertising. The iOS 5 lane produces a reproducible staged DEB that leaves launchd disabled; completed device qualification is still absent. |
| tvOS listen-only direct SIP monitor | Implemented in source; tracked Debug simulator build; hardware-unqualified | The tracked job builds unsigned arm64 `DoorbellTV` Debug for `appletvsimulator` with the real-PJSIP dependency. It does not build a tvOS Release/device artifact, sign, install, or prove real Apple TV audio/video behavior. |
| tvOS SIP answer/transmit | Unsupported | Apple TV has no microphone; the UI intentionally hides Answer and does not advertise transmit. |
| Browser WebRTC calls | Conditional | Requires configured Asterisk WebSocket/WebRTC and a secure browser context. MJPEG panels do not imply microphone support. |
| Web SOS active-page and Push presentation | Implemented; browser/deployment qualification still applies | Open pages poll replicated SOS and render it by default. `emergency.web_active_page_alerts:false` disables raw-state presentation only; a positive matching `device_alert` or delivered Push can still render. With raw state enabled, rule TTL expires decoration/sound but leaves the safe red overlay until clear. Visual/sound/volume/sticky/TTL/colors are validated and preserved in Push; OS notifications may limit custom color/audio controls. `?group=` selects one persisted group for poll and Push. Complete subscription secrets are XChaCha20-Poly1305 sealed in CRDT. Core `delivery_result` is dispatch evidence, not presentation proof. Push still requires HTTPS/localhost, a subscription, and a configured backend. |
| Native and Web semantic UI manifests | Implemented with durable native cache and local-Web scope limit | Core persists each peer's last-valid native manifest/capabilities; configured offline devices appear as `cached_contract:true` and can be validated/queued against that contract, but need a later renderer apply report. The distinct `web_ui.manifest` is local to the serving node and is not a remote Web catalog. |
| Cross-platform conformance harness | Golden model plus source smoke | It replays reference traces for declared profiles and checks narrow ordered source literals. It does not run native/browser artifacts and is not rendering, timing, hardware, or release evidence. |

## Release gates

A release is blocked unless every applicable item is satisfied:

1. English-source and generated-i18n checks pass, plus the target's tests and lint.
2. Native artifacts record toolchain, OS/API floor, architecture, dependency hashes, source
   revision, build identity, and signing identity where applicable.
3. Product artifacts link real PJSIP; SIP-stub artifacts are marked development-only.
4. Artifacts for different OS/API floors, architectures, SIP backends, or signing profiles are
   isolated and never substituted across lanes.
5. Secrets are stored through platform secure storage and persistent configuration contains only
   `secret:` references. Legacy plaintext input is migration-only and must be scrubbed.
6. The exact hardware/OS/firmware passes media, audio, call, kiosk, restart, power-loss, network-loss,
   thermal, and long-duration soak checks before being marked certified.
7. Public pull requests do not run on trusted signing or jailbreak hosts. Signing, jailbreak
   installation, and hardware qualification remain controlled release operations.

The current repository does not provide completed evidence for any Android API 19 SKU, a Windows
VM/Toughpad validation run, iOS 9 armv7 commissioning, iOS 9 arm64 signed-device validation, a
tvOS Release/device run, or iPad 1 camera/audio/enclosure qualification. The local
`ios-legacy-0.2.0-final` tag exists, but `ios-compat` is still untracked in this working tree and
fresh-clone/device/rollback gates are incomplete; retain `ios-legacy` for now.
