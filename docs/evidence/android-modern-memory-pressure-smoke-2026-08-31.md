# Android modern memory-pressure recovery smoke — 2026-08-31

This is a bounded exact-device smoke, not a release-signing, OOM-kill, call-audio, or long-soak
claim. It verifies the current Android application's controlled response to a real system
`onTrimMemory(RUNNING_CRITICAL)` callback and its ability to recreate the H.264 encoder afterward.

## Test identity

- device: moto g64y 5G (`cancunf`), Android 14 / API 34
- application: `jp.keihan.doorbell` version `0.3.0`, modern debug build
- installed APK SHA-256:
  `2fcf83e008a1e3e11dc50cfe6183f76a9422214815c2ebaff2e9a23d1514bce3`
- configured role: `door_station`
- trigger: `adb shell am send-trim-memory jp.keihan.doorbell RUNNING_CRITICAL`

## Passed observations

- The application process remained PID `2188` before and after the trim callback.
- `MainActivity` remained the top resumed activity.
- The atomic runtime mirror recorded
  `memory={state:critical,trim_level:15,action:released_avc_encoder}`.
- Core remained `running`, SIP remained `available`, process recovery reported zero crashes, and
  safe mode remained off.
- After the implementation's 30-second codec pause, a ten-second `/stream.mp4` subscription
  received 929,152 bytes. The stream began with a valid ISO BMFF `ftyp` box followed by `moov`.
- The recovered runtime reported `c2.mtk.avc.encoder`, `active`, 640×360, 24 fps, certified, and not
  degraded. The process and resumed activity remained unchanged.

The captured bounded fMP4 sample had SHA-256
`dfe7585cf41ee754648aaf7808c1e4f5fe60aa0f8294aa786541b4f28422f4ce`. The captured post-recovery
runtime JSON had SHA-256
`7a9df45617832dee3d35f92622a3a1cda0826e655a893d0f0f9a4a3c1bc8e019`.

## Open gates

- This did not force an operating-system OOM kill or native abort.
- It did not run during an established SIP call and does not prove audio continuity.
- It does not replace codec-hang, reboot, power-loss, thermal, battery, rollback, or long-duration
  soak qualification.
- The installed APK is debug-signed and is not a release artifact.

The result upgrades only Android modern critical-trim encoder release/recreation on this exact
device from source/contract evidence to bounded real-device evidence.
