# Recovery and rollback

Self-healing means replicated state can converge after a node or optional integration returns. It
does not mean every platform can recover from force-stop, kernel failure, power loss, bad signing,
or hardware damage without commissioning.

Per-device `devices.<id>.local.recovery.helper_mode` is a requested `off|auto|on` policy. Admin
defaults it to `auto` and writes an authenticated atomic batch; Core rejects other values. The
platform forwards the fixed `MODE` command, and the helper atomically persists it across restart.
Always compare configured mode with measured helper availability and effective runtime mode. A
configured `on` cannot turn a missing, rejected, or unqualified helper into a capability.
Persisted `auto` and `on` both start armed after helper/OS restart and may cold-launch the fixed app;
`off` alone disarms persistent supervision. Changing to `off` does not terminate an already-running
app. Android `DISABLE` is a transient disarm permitted in `auto`, not a persisted mode change.

## Failure boundaries

| Failure | Expected path | Operator gate |
|---|---|---|
| Activity/view restart | A ringing call is recoverable only by its press origin; an in-call dialog only by the recorded `dialog_owner`. Recovery uses exact `door`/`call_id`/`stage_revision`. Monitor sessions never own visitor calls. | Verify no duplicate ring, stale call, lost lifecycle event, or losing dialog ending the winner. |
| Process crash or hang | Platform-specific supervisor may restart with bounded backoff and a circuit breaker. | Test crash, hang, memory pressure, and repeated-failure safe mode. |
| OS force-stop or service suppression | In-process recovery may be unable to act. | Provision and verify a platform-supported external supervisor, or record the limitation. |
| Node/network loss | Peers mark the node unavailable; replicated configuration/events converge after return. | Test partition, reconnect, clock skew, and duplicate delivery. |
| HA/Asterisk outage | Mesh-native ring state, local chime/rules, and direct SIP paths may continue when configured. External HA/PSTN/WebRTC actions do not. | Test the exact deployment; do not generalize from core tests. |
| Corrupt local configuration | Use the platform's atomic previous generation where implemented, then rejoin from a healthy peer. | Verify secret references still resolve; never copy plaintext secrets into the file. |
| Lost or stolen device | Rotate PSK and all reachable integration/panel credentials, then re-pair. | Verify the removed node and old tokens are rejected. |

## Backup and rollback procedure

1. Export replicated configuration from a healthy node. The export excludes secret values.
2. Record the source revision, build ID, artifact manifest/checksums, target OS/API, architecture,
   SIP backend, dependency hashes, and signing identity for every installed artifact.
3. Keep the prior signed/installable package and its manifest in a separate lane. Do not overwrite
   an existing release directory.
4. Restore the application artifact, then restore configuration and device-local secrets through
   separate approved paths.
5. Re-run pairing, capability/runtime-status, media/audio, call, kiosk, power-loss, and network-loss
   checks before returning the node to service.

## Platform notes

- Android's foreground service, alarm, boot receiver, and crash marker are in-process/OS-managed
  defenses; they do not recover from every force-stop. A helper is separate provisioning and must
  be commissioned per device.
- Windows has a watchdog service implementation with bounded restart/safe mode, but elevated VM and
  target-device validation remains a release gate. Its safe mode keeps Core, ringer, SOS, controls,
  and real-PJSIP audio available; it disables custom visuals/animation and H.264 and uses bounded
  low-resolution MJPEG when a JPEG source exists.
- Modern iOS relies on supervised Single App Mode plus the app's runtime supervisor; signing expiry
  is an operational failure and must be scheduled.
- iOS 5 safe mode keeps Core, MiniSIP audio, ringer, SOS, and controls. It disables H.264
  ingest/decode and custom visuals, then uses bounded low-resolution HTTP(S) MJPEG/snapshot direct
  playback when configured, otherwise reports audio-only. JPEG remains local and is not forwarded
  into Core. A local crash/OOM safe mode exits after five uninterrupted healthy minutes and restores
  the measured media capabilities in the running process. A root-helper safe-mode assertion remains
  authoritative until the helper clears it.
- The optional iOS 5/rooted-Android helper is implemented and host-tested. The iOS 5 lane has a
  reproducible staged DEB that deliberately leaves launchd disabled; both platforms remain
  separately provisioned and hardware-unqualified. Do not depend on it until the exact root-owned
  service, app UID/socket permissions, maintenance lease, safe mode, rollback, and device soak pass.
