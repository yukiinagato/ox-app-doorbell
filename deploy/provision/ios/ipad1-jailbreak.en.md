[日本語](ipad1-jailbreak.ja.md) | English | [繁體中文](ipad1-jailbreak.zh.md)

# Provisioning an iPad 1 compatibility node

This procedure is for a controlled, jailbroken iPad 1 (A1219/A1337) running iOS 5.1.1. It is not a
claim of hardware certification. Follow the [maintainer runbook](../../../docs/en/ios-compat-maintainer.md)
and record the exact device, artifact, package, jailbreak environment, and test results.

## Hardware limits

The iPad 1 has a built-in microphone and speaker but no camera. Use the built-in microphone only
after MiniSIP/RemoteIO input and two-way audio pass on that exact device. For video, configure an
explicit external MJPEG/snapshot/RTSP camera source or use no-video mode. Bounded RTSP/RTP-over-TCP
H.264 ingest and Annex-B forwarding pass the host/loopback contract, including SDP/sprop,
single NAL/STAP-A/FU-A, and next-IDR recovery after loss. Runtime stays degraded until DESCRIBE,
SETUP, and an actually accepted IDR; no real camera has passed iPad 1 qualification.

The distinct Core fMP4 playback path has a bounded real-device smoke: an Android 14 door station
rendered at 15–16 fps on the foreground iPad 1, including Wi-Fi rejoin and post-safe-mode rechecks.
This does not qualify external-camera RTSP ingest or unattended post-crash foreground video resume;
see `docs/evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md`.

The shell directly plays HTTP(S) MJPEG and snapshots. Camera credentials remain behind
`secret_ref` and are resolved only into ephemeral Basic/Bearer request headers; URL credentials
are rejected and platform TLS validation remains enabled. This JPEG path is local preview only
(`jpeg_core_forwarding:false`), not a Core/mesh camera feed.

The device is not outdoor-rated. Entrance use requires a weatherproof, condensation-controlled,
temperature-managed, continuously powered enclosure plus battery, cable, and thermal inspection.

## Controlled installation

1. Prepare the jailbreak using its maintained upstream documentation and establish unique host
   access credentials. Do not use or document a shared/default credential.
2. From a controlled host, run:

   ```sh
   ios-compat/scripts/test_host.sh
   ios-compat/scripts/build_core_ios5.sh
   ios-compat/scripts/build_core_ios5.sh --install
   ios-compat/scripts/build_app_ios5.sh
   ios-compat/scripts/build_deb.sh
   ```

3. Verify the artifact manifest, package contents, package digest, and rollback package. Install
   with `ios-compat/scripts/install_deb.sh`; the SSH copy script is a maintenance fallback only.
   That fallback writes a root-owned maintenance-restart marker before terminating the app so an
   intentional update is not counted as a crash-loop failure.
4. Pair from the application. Confirm Core stores `mesh.psk` in Keychain before emitting only
   `{t:"paired", psk_ref:"secret:mesh.psk"}`, and `boot.json` contains that reference plus non-secret
   bootstrap fields. A `pairing_persistence_error` must remain not-ready. Never paste a PSK into it.
5. If using an external camera, adapt the examples in `ios-compat/profiles/`. Keep credentials
   behind `secret_ref`; URL userinfo and camera inference from seed peers are forbidden. For RTSP,
   verify the source remains degraded until an IDR is accepted and drops back to next-IDR recovery
   after packet loss.

## Acceptance

Verify cold boot, targeted ring without duplicates, cancel/stale-call handling, built-in microphone
and speaker, MiniSIP setup/teardown and DTMF, media/RTSP/no-video behavior, Wi-Fi and peer loss, crash and
memory pressure, power loss, rollback, kiosk maintenance access, and a long thermal/memory soak in
the final enclosure.

The optional root keepalive helper is implemented, host-tested, and available as a reproducible
armv7/iOS 5.1 staged DEB. The package installs only the binary and inactive launchd template; use
`ios-compat/scripts/install_helper_ios5.sh --stage` and do not enable it during normal app
provisioning. There is still no completed iPad helper qualification. Recovery must work without it
until an explicitly approved `DB_CONFIRM_ROOT_HELPER=YES ... --enable` run proves its root-owned
plist, UID/GID and socket permissions, maintenance lease, crash/hang safe mode, rollback, and soak
on the exact device. Keep the device on an isolated trusted LAN and never expose its SSH, MiniSIP,
mesh, HTTP, or camera endpoints directly to the Internet.
