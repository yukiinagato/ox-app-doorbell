# iOS kiosk client

`ios-kiosk` is the Objective-C kiosk client for the jailbroken iPad 1 / iOS 5.1 compatibility
target. English is canonical; the previous Chinese design notes are preserved in
[`README.zh.md`](README.zh.md).

The compatibility foundation, host tests, historical-SDK build entry points, and optional
root-helper contract live under `ios-compat`. Use the maintained runbooks rather than instructions
from `ios-legacy`:

- [`../docs/en/ios-compat-maintainer.md`](../docs/en/ios-compat-maintainer.md)
- [`../ios-compat/README.md`](../ios-compat/README.md)
- [`../ios-compat/helper/README.md`](../ios-compat/helper/README.md)

`ios-legacy` is archival and must not receive new features. Do not copy credentials into scripts,
command lines, URLs, or `boot.json`. Pairing must first store `mesh.psk` through the platform
secure-store callback and then expose only `psk_ref: "secret:mesh.psk"`; a
`pairing_persistence_error` is not ready state.

The local, unpushed `ios-legacy-0.2.0-final` tag exists, but `ios-compat` is still untracked in this
working tree. Fresh-clone, iPad hardware, and rollback gates therefore remain open; keep the
`ios-legacy` directory for now.

## Hardware constraints

The iPad 1 has a built-in microphone but no camera. It can receive/listen and use its microphone
when the implemented SIP path is available; it cannot send local camera video. Outdoor use still
requires a separately qualified weatherproof enclosure, protected power, suitable temperature
range, glare control, and moisture management. The repository does not certify such an enclosure.

An explicit IP-camera source can provide HTTP(S) MJPEG/snapshot direct playback or bounded
RTSP/TCP H.264 ingest. HTTP credentials stay behind `secret_ref` and become only ephemeral
Basic/Bearer headers with platform TLS validation; URL credentials are rejected. JPEG is local
preview only (`jpeg_core_forwarding:false`). H.264 capability remains degraded until a complete
IDR is accepted, and no real camera has passed iPad 1 qualification.

Manual resident answer binds exact `door`/`call_id`/`stage_revision` only to an answer-mode SIP
dialog. Monitor does not own the visitor call; a losing simultaneous answer hangs up without
ending the winner. Safe mode retains Core, MiniSIP audio, ringer, SOS, and controls, disables H.264
and custom visuals, and uses bounded low-resolution MJPEG/snapshot when available.

## Build and verification

Use the neutral compatibility scripts:

```sh
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_app_ios5.sh
```

The iOS 5 device lane requires the licensed local historical SDK and compatibility libc++. Do not
commit SDKs, signing material, generated static archives, jailbreak credentials, or device logs
containing secrets. A successful host build is not iOS 5 hardware qualification; complete the
cold-boot, audio, call lifecycle, recovery, long-run, and rollback checks in the maintainer runbook
before marking a release hardware-certified.
