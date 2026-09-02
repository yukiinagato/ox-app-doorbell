# iOS compatibility maintainer runbook

This runbook covers the shared `ios-kiosk` Objective-C shell and neutral `ios-compat` tooling for
iOS 5.1/armv7. It does not add features to the archival `ios-legacy` tree. iOS 9 uses the shared
Swift sources and its separate build/signing lane.

## Hardware and deployment facts

The first-generation iPad (A1219/A1337) has a built-in microphone and speaker, but no camera. The
built-in microphone can support audio after real-device MiniSIP/RemoteIO commissioning; do not
require an external microphone or claim successful two-way talk until that test passes. Because it
cannot capture video, a door-station profile must use an explicitly bound external camera or expose
an honest no-video UI.

`door_station` is a software role, not a weather rating. The iPad is not outdoor-rated. An entrance
deployment needs a weatherproof, condensation-controlled, temperature-managed, continuously
powered enclosure, cable strain relief, battery inspection, and a safe maintenance disconnect.
Qualification must cover the actual seasonal temperature and humidity range.

## Prepare the controlled build host

1. Use a licensed local historical Apple SDK and compatibility libc++ toolchain. Never commit the
   SDK, toolchain binaries, signing keys, jailbreak packages, generated archives, or app bundles.
2. Confirm the repository is clean for a release identity. Dirty integration builds require both
   `DB_ALLOW_DIRTY=1` and an explicit unique `DB_BUILD_ID`; they are not release evidence.
3. Keep iOS 5/armv7 artifacts separate from iOS 9 armv7, iOS 9 arm64, modern iOS, simulator, SIP,
   and signing lanes.

## Host and artifact gates

Run from the repository root:

```sh
ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_core_ios5.sh --install
ios-compat/scripts/build_app_ios5.sh
```

`test_host.sh` includes the MiniSIP UDP loopback and Objective-C compatibility contracts.
`build_core_ios5.sh` emits a deterministic archive and manifest under
`build/ios-compat/artifacts/`; `--install` verifies before atomically updating the `ios-kiosk`
link input. Inspect the manifest's source revision, build identity, target, architecture, minimum
OS, dependency identity, and archive digest before proceeding.

For a package-based install, use `ios-compat/scripts/build_deb.sh` and verify the package contents
and rollback package. `ios-compat/scripts/install_app_ssh.sh` is a direct-copy maintenance path,
not a substitute for a reviewed package. Establish unique host access credentials out of band;
never embed them in commands, files, URLs, or documentation.

## Pairing and media configuration

Pair through the application flow. Core first writes `mesh.psk` through `secure_put`, then emits
only `{t:"paired", psk_ref:"secret:mesh.psk"}` for the shell to persist. It never delivers a new
`psk_hex` to the shell. If Keychain persistence fails, require `pairing_persistence_error` and keep
the client out of ready state. Legacy `psk_hex` is migration-only input.

For an external camera, start from the examples in `ios-compat/profiles/`. Persist the binding at
`devices.<id>.local.camera.source_ref` and define the source under `media_sources.<id>`. URL
userinfo is rejected; credentials belong behind `secret_ref`. Seed peers are mesh bootstrap
addresses and are never camera sources.

The current shell directly previews HTTP(S) MJPEG, polls HTTP(S) snapshots, and implements bounded baseline
H.264 ingest over RTSP/RTP interleaved TCP. Its host/loopback contract covers SDP and
`sprop-parameter-sets`, single NAL/STAP-A/FU-A depacketization, loss recovery at the next IDR, and
Annex-B forwarding to Core. An RTSP declaration remains degraded as `rtsp_ingest_pending`; advertise
`rtsp_h264_forwarding` only after DESCRIBE and SETUP succeed and Core actually accepts a complete
IDR. HTTP camera authentication resolves the source's `secret_ref` only at request time into an
ephemeral Basic or Bearer header; platform TLS validation remains enabled, and URL credentials are
rejected. JPEG is rendered locally and is explicitly reported as `jpeg_core_forwarding:false`, so
it does not become the door's Core/mesh camera stream. RTSP is not a direct fMP4 playback URL. No
real camera has passed iPad 1 qualification yet.

The separate Core fMP4 playback route now has bounded exact-device evidence: an Android 14 door
station drove `/stream.mp4`, and the foreground iPad 1 renderer sustained 15–16 fps with observed
20–33 ms latency, including Wi-Fi rejoin and post-safe-mode rechecks. That result does not qualify
the RTSP ingest route or unattended post-crash foreground resume; see
[the device-smoke record](../evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md).

## Hardware commissioning

Record the model, OS build, jailbreak/tool versions, source revision, artifact manifest, package
digest, and enclosure/power configuration. Then verify:

1. cold boot and application launch; pairing and secure-store migration;
2. targeted schema-v2 ring presentation with no duplicate UI or ringtone;
3. built-in microphone input, speaker output, MiniSIP call setup/teardown, DTMF, mute and route
   behavior on the exact iPad;
4. MJPEG/snapshot, explicit no-video, or RTSP/TCP H.264 behavior, including camera/network loss,
   next-IDR recovery, and proof that capability stays degraded until an IDR is accepted;
5. quick reply, cancellation, unlock failure/success UI, SOS presentation, and stale-call rejection;
6. Wi-Fi loss/rejoin, peer loss, process crash, memory pressure, repeated failure, power loss, and
   rollback;
7. a long-duration thermal/memory soak in the final enclosure.

For a controlled memory-warning qualification, temporarily set `debug.ui_dumps` to `true`, keep
the application in the foreground, and invoke `/usr/bin/uiopen doorbell://memorypressure` on the
device. The URL is rejected while diagnostics are disabled or the application is in the
background, and it runs the same release/safe-mode handler as UIKit's real memory warning. Verify
that runtime `memory_pressure.last_source` is `diagnostic_url`, its counter increments, optional
video is released, and the bounded JPEG/audio fallback remains usable. Restore `debug.ui_dumps` to
`false` afterward. This qualifies the handler only; it is not an OOM-kill or long-soak result.

The optional root helper is implemented at `tools/helper/doorbell_keepalive.c` and covered by
non-root host tests, which now run in the `keepalive-helper` CI job and from
`ios-compat/scripts/test_host.sh`. Build its reproducible armv7/iOS 5.1 staged DEB with
`DB_ALLOW_DIRTY=1 DB_BUILD_ID=<reviewed-id> ios-compat/scripts/build_helper_ios5.sh`. The package
stages the binary and inactive launchd template only; it does not enable a root service. Use
`SSHPASS=<commissioned-password> ios-compat/scripts/install_helper_ios5.sh --stage` for inspection.
The installer forwards through `iproxy` on local port 2223 by default
(`DB_IOS_SSH_LOCAL_PORT` overrides it) and keeps the legacy KEX/cipher/MAC options iOS 5's sshd
requires.

Operational rails to know before commissioning:

- the `ios5` profile waits for a boot grace and then for a `SpringBoard` process owned by the app
  UID before any launch, so a cold boot no longer burns three failure slots;
- a running app with no heartbeat is adopted as `launch_pending_no_heartbeat` instead of being
  relaunched, and the app announces `started` from bootstrap setup as well;
- `/var/db/doorbell-keepalive.disable` is a root-only kill switch that forces mode `off` without
  rewriting the persisted mode (`--disable-file` / `--enable-file`);
- after ten launches in latched safe mode the helper stops launching (`launch_inhibited`) and keeps
  only its status/control surface; `--clear-safe-mode` removes the root-owned marker to reset it;
- `install_via_ssh.sh` and `install_deb.sh` take a 300-second maintenance lease around the kill, so
  an app upgrade under an active helper is not counted as a crash;
- `launchctl load` over SSH on iOS 5 commonly answers `Socket is not connected`. The installer
  never reports success without the socket and status file, and exits 40 with a reboot instruction
  instead.

There is still no iOS hardware qualification. If a device explicitly opts in, require
`DB_CONFIRM_ROOT_HELPER=YES` for `--enable`, then work the fourteen-item device checklist in
`ios-compat/helper/README.md` — cold boot ×3, unprovisioned boot, kill, hang, crash loop, launch
cap, maintenance lease, permission rejection, mode wiring, kill switch, upgrade under the helper,
power loss, soak, and rollback. Until those gates pass, recovery claims must continue to work
without the helper.

## Release record

Attach test results and artifact/package hashes to the controlled release record. Do not call the
target build-verified until the exact artifact passes all host/link/package gates. Do not call an
iPad hardware-certified until the exact device/enclosure passes commissioning and soak. The local,
unpushed `ios-legacy-0.2.0-final` tag exists, but `ios-compat` is still untracked in this working
tree, so a fresh clone does not yet contain the migrated tooling. Keep `ios-legacy` unchanged until
the migration is tracked and fresh-clone, device smoke, rollback, documentation, and archival-tag
approval gates are all complete.
