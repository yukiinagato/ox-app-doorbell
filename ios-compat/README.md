# iOS compatibility foundation

`ios-kiosk` is the shared Objective-C compatibility shell for iOS 5.1/armv7.
This directory owns neutral build, test, deployment, and recovery contracts.
iOS 9 uses the shared Swift sources and its separate build/signing lane.

Apple's [original iPad specifications](https://support.apple.com/en-euro/112438)
list a built-in microphone and speaker. The A1219/A1337 model has no built-in
camera (Apple's [model guide](https://support.apple.com/en-us/108043) first
lists front/rear cameras for iPad 2). A `door_station` profile therefore has
three supported video modes:

- `ip_camera`: the iPad owns visitor interaction and SIP audio while a trusted LAN
  camera/gateway supplies MJPEG, snapshots, or baseline H.264 over RTSP/RTP interleaved TCP.
  The bounded RTSP path parses SDP and `sprop-parameter-sets`, depacketizes single NAL,
  STAP-A, and FU-A payloads, waits for the next IDR after loss, and forwards complete Annex-B
  access units to Core. This contract is host/loopback-tested, not qualified with a real camera
  on iPad 1.
- The separate indoor playback path has bounded real-device evidence: an Android 14 door station's
  Core fMP4 stream rendered continuously on an iPad 1 foreground `DBVtVideoView` at 15–16 fps,
  including Wi-Fi rejoin and post-safe-mode checks. This does not qualify RTSP ingest or unattended
  post-crash foreground resume; see `docs/evidence/ios5-ipad1-fmp4-smoke-2026-08-31.md`.
- `none`: audio/UI-only door station. Indoor panels show an explicit no-video
  fallback rather than inventing stream URLs.
- `auto`: resolve explicit core peer/config media metadata. Seed addresses are
  transport bootstrap data and are never assumed to be door stations.

`door_station` is a software role, not an outdoor hardware rating. Apple's
specified operating range is 0–35°C at 5–95% noncondensing humidity. A real
entrance installation requires a weatherproof, condensation-controlled,
temperature-managed, continuously powered enclosure.

MiniSIP supplies a compatibility UAC/UAS for direct LAN calls. It intentionally
supports one UDP dialog, PCMU/8 kHz, RTP, and telephone-event DTMF; it is not a
general SIP registrar and does not provide TLS or SRTP. On iOS 5, `auto` selects
MiniSIP. Newer shells may use the common core/PJSIP path or force MiniSIP for a
controlled compatibility deployment.

Indoor call presentation follows the common schema-v2 contract. Replicated
`event/type=press` messages only update cached call data and history; they never
open UI or play a ringtone. Only a locally targeted, unexpired `t=chime` with
`call_id`, `stage_revision`, and `expires_at_ms` opens the incoming screen.
Duplicate or stale revisions are ignored, and cancellation/purpose updates are
applied only when their `call_id` matches the visible call.

ABI-v2 `secure_get`/`secure_put` use the iOS generic-password Keychain with
`AfterFirstUnlock` accessibility. For new pairing, Core stores `mesh.psk`
first, then emits only `{t:"paired", psk_ref:"secret:mesh.psk"}` for atomic
boot-reference persistence; it never gives the shell a new `psk_hex`. A
secure-store failure emits `pairing_persistence_error`, does not emit `paired`,
and must not enter ready. Old `psk_hex` is read only by the one-cycle migration.

## Common commands

```sh
# Strict host C tests, including a real UDP INVITE/ACK/BYE UAS loopback
ios-compat/scripts/test_host.sh

# Reproducible armv7/iOS 5.1 core artifact (does not overwrite app input)
ios-compat/scripts/build_core_ios5.sh

# Verify, then atomically install the artifact for ios-kiosk linking
ios-compat/scripts/build_core_ios5.sh --install

# Build and verify the ARC kiosk shell
ios-compat/scripts/build_app_ios5.sh

# Optional direct app copy for a jailbroken device (DEB install is preferred)
ios-compat/scripts/install_app_ssh.sh [device-ip]
```

Clean builds use the repository revision as `DB_BUILD_ID`. A dirty tree is
rejected because two different sources must not share one artifact identity.
For a local integration check, opt in explicitly:

```sh
DB_ALLOW_DIRTY=1 DB_BUILD_ID=local-integration \
  ios-compat/scripts/build_core_ios5.sh --install
```

Artifacts and manifests are written beneath ignored
`build/ios-compat/artifacts/`. The manifest has stable key order and no build
timestamp. `SOURCE_DATE_EPOCH` and `ZERO_AR_DATE` are applied to archive tools.

## Door profile

See `profiles/ipad1-door.boot.example.json` and
`profiles/ipad1-door.media-source.example.json`. The persisted binding is
`devices.<device_id>.local.camera.source_ref`; definitions live only at
`media_sources.<source_id>`. URLs are never inferred from `seed_peers`, and URL
userinfo is rejected. Credentials remain behind `secret_ref`.

The current iOS 5 shell previews HTTP MJPEG, polls HTTP(S) snapshots, and implements bounded
baseline-H.264 ingest over RTSP/RTP interleaved TCP. It performs OPTIONS/DESCRIBE/SETUP/PLAY,
parses SDP and `sprop-parameter-sets`, handles single NAL/STAP-A/FU-A, suppresses delta frames
after packet loss until the next complete IDR, and forwards Annex-B access units through
`db_core_on_encoded_frame`. An RTSP declaration remains degraded as `rtsp_ingest_pending` and
must not advertise `rtsp_h264_forwarding` until DESCRIBE and SETUP have succeeded and Core has
actually accepted an IDR. The host/loopback contract passes; a real camera on iPad 1 is still a
hardware qualification gate. RTSP is an ingest source, not a direct fMP4 URL. HTTPS multipart
MJPEG is also reported degraded; use the snapshot or a trusted HTTP gateway for that TLS path.
Legacy `boot.json media_source` URLs remain read-only migration input and are reported as
`legacy_boot_source`; new configuration must use `source_ref`.

## Recovery contract

The app can send a main-run-loop heartbeat to
`/var/run/doorbell-keepalive.sock` when `keepalive_helper` is `auto` or `on`.
The fixed-purpose receiver is implemented at `tools/helper/doorbell_keepalive.c`
with non-root macOS/Linux tests, bounded maintenance leases, fixed launch
profiles, atomic status, restart backoff, and crash-loop safe mode. It remains
opt-in and unqualified on iOS hardware. A reproducible armv7/iOS 5.1 DEB now
stages the binary and inactive launchd template without enabling the service;
see `helper/README.md`. Current release and recovery claims must not depend on
it until the exact root-owned installation and device gates pass.

The archival `ios-legacy` tree is intentionally retained unchanged until all migration
gates pass: host tests, deterministic artifact comparison, iOS 5 armv7 link,
device smoke test, rollback package verification, documentation review, and a
main-agent-approved archival tag. No compatibility tag is created here.

The neutral tools preserve the unique legacy workflows: direct app copy,
reproducible DEB packaging/install, Developer Disk Image mounting, and the
MiniSIP live-call CLI. The legacy copies remain unchanged until the final gate.
