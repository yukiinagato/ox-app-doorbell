# Windows client release and recovery notes

The Windows shell targets .NET Framework 4.8 and the versioned `db_platform_v2`
ABI. A production bundle contains both x64 and x86 core DLLs; the AnyCPU WPF
shell selects `lib/win-x64` or `lib/win-x86` before its first P/Invoke.

On first launch, when `setup_complete:true` is absent, or whenever the local role is invalid or a door station has no valid door ID,
the shell blocks Core startup and opens the device setup window. The operator can choose either
door station or indoor panel. Door station receives a random `door-xxxxxxxx` default; indoor panel
has no door assignment. The confirmed profile is atomically written to `boot.json` with
`setup_complete:true`.

## Release build gate

Run from an x64 VS2022 Developer Command Prompt, or let `win/build.cmd` locate
VS2022. Both PJSIP roots must contain the headers and MSVC libraries for their
matching architecture:

```bat
set DB_BUILD_ID=release-2026.08.30-1
set SOURCE_DATE_EPOCH=1788048000
set DB_PJSIP_ROOT_X64=C:\deps\pjsip\x64
set DB_PJSIP_ROOT_X86=C:\deps\pjsip\x86
set DB_SIGN_CERT_SHA1=0123456789ABCDEF0123456789ABCDEF01234567
win\build.cmd
```

For a clean Git tree, `DB_BUILD_ID` and `SOURCE_DATE_EPOCH` may be derived from
the exact commit. A dirty build must provide an explicit build ID. Build IDs are limited to
`[A-Za-z0-9._-]` so they are safe artifact directory names.

The build fails closed unless both native cores link real PJSIP. It then runs an
ABI executable for each architecture. The probes enforce:

- `DB_PLATFORM_V2_VERSION == 2`, field offsets, x64 size 72 and x86 size 40;
- the `create_v2`, call-v2 and SIP-backend exports exist;
- `db_core_sip_backend()` returns `pjsip` for release artifacts.

A display-only developer build may opt in to the stub, and is visibly reported
as unavailable by the UI/runtime status:

```bat
set DB_ALLOW_SIP_STUB=1
set DB_BUILD_ID=dev-stub-local
win\build.cmd
```

Formal bundles require an Authenticode certificate in the runner's certificate
store. Every bundled EXE and DLL is signed with SHA-256 and verified before the
manifest is written. The development-stub lane remains explicitly unsigned.

The build uses `/Brepro`, deterministic C# compilation, `ZERO_AR_DATE`, an
explicit build ID, atomic native-DLL placement and an atomic final directory.
`win/dist/<build-id>/SHA256SUMS` records the build ID, source epoch and SHA-256
of every bundled file. An existing bundle is never overwritten.

## Secrets and pairing

`db_platform_v2.secure_get/secure_put` use machine-scoped DPAPI and atomically
replace opaque files under `%ProgramData%\Doorbell\secure`. Core stores a new
PSK as `mesh.psk` before emitting `paired`; the event contains only its opaque
reference. The shell then atomically rewrites `boot.json` to contain only:

```json
{"psk_ref":"secret:mesh.psk","seed_peers":["host:47172"]}
```

The plaintext `psk_hex` boot field is removed. `boot.json.bak` is the previous
valid generation and is used if the primary file is invalid.

## Pairing UX (onboarding, Add-device panel, QR)

`db_core_pairing_json` is the only source of pairing state; the shell renders
`state` and never derives it from `paired`/`persistence_ready`. An empty snapshot
means "not published yet" and never shows onboarding.

- `Pairing/PairingOnboardingView` replaces the main UI whenever `state` is not
  `ready`: searching status, this device's Add QR from `db_core_qr_encode`, the
  Pairing-PIN entry with a drawn numeric keypad, the two-step "create a new
  Cluster" confirm, the `persist_error` retry, and "set up later". Skipping shows
  a persistent banner on the main UI that reopens onboarding.
- `Pairing/AddDeviceWindow` is the state-`ready` panel, opened from the
  membership status and gated by the admin password in kiosk mode: nearby
  devices with add/ignore, the Pairing-PIN card re-rendered from `pairing.token`,
  bulk add with its warning/stop/count, this device's own QR, and unpair.
  A row only reports success on `device_joined`, never on `invite_result`.
- `Pairing/QrScanWindow` starts `db_core_qr_scan_start` and feeds frames back
  through `db_core_on_camera_frame`. Core owns the Media Foundation capture
  (`core/src/media/camera_win.cpp`) and republishes it as `/stream.mjpeg`, so the
  scanner consumes that local stream instead of opening the device twice. Core
  only starts that capture for `role: door_station`; an indoor panel therefore
  shows the "no camera" message and the operator uses a Pairing PIN or scans from
  another device.
- `db_platform_v2.secure_delete` is wired to the DPAPI store so leaving a Cluster
  removes `mesh.psk` instead of orphaning it, and `boot.json` loses `psk_ref` and
  `seed_peers` on unpair or revoke.

## Watchdog service

Install from an elevated prompt after placing the artifact in its permanent
directory:

```bat
doorbell-watchdog.exe --install "C:\Program Files\Doorbell\app\DoorbellApp.exe"
doorbell-watchdog.exe --clear-safe-mode
doorbell-watchdog.exe --uninstall
```

The LocalSystem service starts the shell in the active console session and
observes `Global\DoorbellAppHeartbeat.v1`. It allows 30 seconds for startup and
treats 20 seconds without a pulse as a hung app. Restarts use
2/5/10/30/60-second backoff. Three failures in five minutes enter a persistent
`--safe-mode`; safe mode remains until explicitly cleared. The service only
terminates/restarts DoorbellApp—it never requests an operating-system reboot.
State and diagnostic logs are stored in `%ProgramData%\Doorbell`.

Safe mode keeps Core, ringer, SOS, controls, and real-PJSIP audio running. It
disables custom background/animation and H.264, and uses bounded low-resolution
MJPEG when a JPEG stream exists; otherwise the call remains audio/control-only.

## Implemented and conditional capabilities

Implemented in the shell and covered by host/static contract tests:

- TLS-1.2-only HTTPS through WinHTTP, system certificate validation, redirects
  disabled, bounded responses, and explicit transport errors;
- DPAPI get/put, device/network/power information, measured CPU/clock/network
  capabilities, runtime status and schema-v1 `ui_manifest`;
- call-ID-aware press, ring-then-purpose selection, cancellation and recovery;
- targeted schema-v2 chime handling (replicated raw `press` never rings twice),
  SIP monitor/answer, DTMF `*1` unlock with explicit failure UI, SOS and local
  system notifications for `device_alert` presentation;
- exact manual-answer lifecycle binding (`door`/`call_id`/`stage_revision`),
  deterministic `dialog_owner` arbitration, loser hangup without ending the
  winner, and monitor exclusion from visitor-call ownership;
- measured `device_alert_channels` plus per-channel presentation/permission/
  limitation/TTL reports. Core `delivery_result:local_shell:dispatched` is only
  callback dispatch evidence, not proof of presentation;
- `devices.<id>.local.ui.elements.<semantic_id>` overrides with only
  `scale`, `font_scale`, `foreground`, `background`, `accent`, `border` and
  `radius`; unknown/unsafe values are rejected and a valid atomic LKG is used
  after a corrupt transient update.

Conditional/scaffolded pending a Windows certification run:

- WPF `MediaElement` attempts remote fMP4/H.264 and falls back to MJPEG when
  `MediaOpened` has not fired within three seconds (or on `MediaFailed`), with
  at most three attempts per incoming/in-call screen. Every attempt and its
  failure reason (HRESULT and message) is appended to `video.log` in the data
  directory and the last outcome is published as
  `runtime.windows.h264_playback_diagnostics`. Runtime capabilities remain false
  until the installer writes `h264-playback.certified`; encoder capability
  likewise needs `h264-encode.certified` after hardware/driver certification.
- Real microphone/speaker/AEC, PJSIP registration and DTMF unlock must be tested
  with the deployment PJSIP archives, SIP server and door controller.
- The service install, cross-session WTS launch, heartbeat ACL, DPAPI machine
  scope, WinHTTP TLS/certificate behaviour, x86 WOW64 load and kiosk foreground
  guard require an elevated Windows x64/x86 VM or target device. They cannot be
  executed on macOS.

Portable checks available on any host are:

```sh
python3 win/tests/test_windows_contracts.py
c++ -std=c++17 win/watchdog/tests.cpp -Iwin/watchdog -o /tmp/watchdog-policy
/tmp/watchdog-policy
```
