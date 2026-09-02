# Android targets

The Android shell has one shared source tree and two build tiers. Build exactly one tier per
Gradle invocation because AGP selects the NDK at module scope.

| Tier | Install floor | NDK | Bundled ABIs | PJSIP root |
|---|---:|---:|---|---|
| `modern` | API 21 | 27.1.12297006 | arm64-v8a, armeabi-v7a, x86_64 | `core/third_party/pjsip/android/api21/<abi>` |
| `legacy19` | API 19 | 25.2.9519653 | armeabi-v7a | `core/third_party/pjsip/android/api19/<abi>` |

```sh
# Modern
PJSIP_TIER=api21 ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/27.1.12297006" \
  ../tools/build_pjsip_android.sh
./gradlew -PdoorbellTier=modern assembleModernDebug testModernDebugUnitTest lintModernDebug

# API 19 legacy
PJSIP_TIER=api19 ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/25.2.9519653" \
  ../tools/build_pjsip_android.sh
./gradlew -PdoorbellTier=legacy19 \
  assembleLegacy19Debug testLegacy19DebugUnitTest lintLegacy19Debug
```

These commands and hosted CI produce debug-key **debug-contract** APKs. They are not release
artifacts. The current Gradle `release` build type also points at the debug signing configuration;
do not publish it until a controlled release lane injects an approved signing identity and records
the artifact/toolchain/dependency manifest. Keep modern and legacy outputs separate.

The PJSIP build emits `doorbell-build.properties`. CMake rejects an artifact whose ABI,
`APP_PLATFORM`, or NDK generation does not match the selected APK tier. API 19 is intentionally
armv7/NEON only. Adding KitKat x86 or non-NEON ARM is a separate commissioning decision; it must
not be inferred from this build.

Android also configures core with `DB_REQUIRE_PJSIP=ON`. JNI has a compile-time guard, publishes
`sip_backend: pjsip`, and the final shared object contains the real `pjsua_create` symbol. There is
no product-APK path that silently substitutes `sipctl_stub.cpp`.

## AVC behavior

The Camera1 encoder probes real `MediaCodec.configure/start` combinations instead of trusting the
codec list. API 16-20 buffer arrays and `INFO_OUTPUT_BUFFERS_CHANGED` are handled separately from
API 21 accessors. Only CTS-defined planar, semi-planar, packed, and TI semi-planar byte layouts are
used. Unknown proprietary/tiled color formats are never guessed.

An encoder becomes active only after it emits Baseline SPS and an IDR within two seconds. AVCC and
Annex-B output are normalized before entering the core. A failed candidate is released and the
next codec/color candidate is tried. Resolution commissioning falls back through 480x360,
320x240, and 176x144. MJPEG remains the safety path when all verified AVC candidates fail.

The incoming screen tries the peer's endless fMP4 stream first. Its bounded reader accepts the
repository's `moov/avcC`, `dbts`, `moof/trun`, and `mdat` shape, then feeds Annex-B access units to
a surface decoder. Invalid boxes, a non-Baseline stream, decoder failure, or no first frame within
2.5 seconds causes a one-way fallback to bounded MJPEG for that viewing session.

API 19 support is **not a blanket hardware claim**. A KitKat device remains
`active_uncommissioned` until both independent gates pass:

- the installed APK produces and atomically persists a real 1.5--2 second Baseline SPS/PPS/IDR
  measurement bound to its APK hash, source identity, exact firmware fingerprint, and codec
  identity; and
- the same exact SKU, firmware, and codec has a source-controlled entry in
  `app/src/legacy19/assets/api19-h264-qualified.json`. That entry names a bounded JSON evidence
  artifact under `api19-qualification/` and pins the artifact's raw SHA-256. The artifact must
  record passing 480x360/15 fps Camera1 capture, 600 kbps Baseline encoding with a one-second GOP,
  bounded fMP4 decode, real PJSIP UAC/UAS/RTP, and a simultaneous soak lasting at least eight
  hours.

The checked-in qualification list is currently empty, so no API 19 SKU is represented as release
qualified. Neither `boot.json`, remote configuration, codec enumeration, nor an arbitrary hash can
self-certify a device.

JNI uses `db_core_create_v2`. Its HTTPS callback accepts only HTTPS, keeps the platform trust and
hostname checks, and explicitly enables TLS 1.2 on API 19. Secret values are encrypted with an
AndroidKeyStore-protected master key; `mesh.psk` is referenced from boot as
`psk_ref: "secret:mesh.psk"` and is never newly persisted as `psk_hex`. A legacy plaintext PSK is
migrated before core starts, then both boot generations are scrubbed. `device_info` returns a
cached battery/network/gateway snapshot and every platform-returned buffer is released through
the ABI v2 callback.

Measured capabilities, runtime state, and the semantic UI manifest are published to core. Atomic
local mirrors are kept in `files/runtime-status.json` and `files/core-contract.json` for recovery
diagnostics. The UI manifest advertises the Android renderer's API 19-safe semantic properties
(`scale`, `font_scale`, `foreground`, `background`, `accent`, `border`, and `radius`) for call,
cancel, purpose, ring, reply, close, SOS, and offline elements. The renderer restores a captured
Drawable baseline before each application, wraps rather than mutates an OEM drawable, and uses
accent as the pressed/focused boundary. It enforces text and control-boundary contrast, a 48 dp
effective touch floor, last-known-good rollback, and a minimum scale of 1.0 for safety controls.

Android advertises measured `device_alert_channels` and channel support/availability. SOS
presentation reports one result per requested channel, including applied visual/sound, permission
or platform limitations, and TTL expiry. Core's `delivery_result:local_shell:dispatched` only says
the event reached the shell callback; it is not the same as this presentation report.

Only a targeted schema-v2 `chime` opens or updates the incoming screen. Replicated `press` and
`purpose_selected` events update call metadata only; stale/expired or duplicate call-stage chimes
are ignored, so mesh delivery cannot create a second incoming UI or ringtone.

The resident's Answer action binds the exact `door`/`call_id`/`stage_revision` only when its
bidirectional SIP INVITE starts. Core receives `call_answered` after that leg's real `in_call`
callback and `call_ended` after its real `idle` callback. The receive-only monitor leg never binds
or reports visitor-call lifecycle state. Core's projected `dialog_owner` arbitrates simultaneous
answers. If another node owns the same call, Android clears its binding before hanging up the
losing SIP leg, so the resulting `idle` callback cannot report `call_ended` for the winner.

## Lifetime and recovery

`DoorbellService` owns the core, Camera1 session, and encoder. Activity pause/resume does not stop
upstream video. Core startup uses bounded exponential retry. The process uses a foreground
`START_STICKY` service, `BOOT_COMPLETED`, `MY_PACKAGE_REPLACED`, a small crash marker, and an alarm
restart. Bitmap decode dimensions and fMP4/JPEG input sizes are bounded; critical trim-memory
events release the AVC encoder and nonessential image/audio caches.

These in-process mechanisms cannot recover from force-stop and cannot reliably detect a native
hang or LMK exit. Those cases require the separately provisioned helper described in
[`KEEPALIVE_HELPER.md`](KEEPALIVE_HELPER.md). Android 4.4 has no native lock-task kiosk: HOME and
immersive mode are soft kiosk only.

## Commissioning gate

Do not add an entry or evidence artifact to the source-controlled qualification list until the
exact device, firmware, encoder candidate identity, and decoder identity pass:

- valid Baseline SPS/PPS and first IDR within two seconds;
- simultaneous encode, decode, SIP, and MJPEG, followed by an eight-hour memory/thermal soak;
- reboot/power-loss, Java exception, native abort, kill, memory pressure, codec hang, and network
  loss recovery;
- correct planar/semi-planar colors and rotation;
- helper maintenance lease and restart circuit breaker, when the helper is enabled.

At minimum test a Qualcomm KitKat ARM device, an Exynos planar device, the deployed OEM SKU, and a
modern control device. MediaCodec enumeration or an emulator alone is not acceptance evidence.

A bounded modern-control smoke now exists for a moto g64y 5G/API 34: a real
`RUNNING_CRITICAL` trim kept the same foreground process, released AVC, and recreated
`c2.mtk.avc.encoder` to serve valid 640x360 fMP4 after the 30-second protection window. See
[the device-smoke record](../docs/evidence/android-modern-memory-pressure-smoke-2026-08-31.md).
This does not qualify an API 19
SKU or replace OOM-kill, in-call audio, power, thermal, and long-soak gates.
