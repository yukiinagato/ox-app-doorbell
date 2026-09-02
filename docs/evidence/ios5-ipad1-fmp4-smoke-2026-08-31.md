# iPad 1 Android-to-fMP4 bounded device smoke — 2026-08-31

This is a bounded device-smoke record, not a hardware-certification or release-signing claim. It
records the exact behavior observed on an iPad 1 indoor panel receiving the current Android door
station's H.264 stream through Core `/stream.mp4` fMP4 packaging.

## Test identity

- source revision: `65b91077bea512fecfeb947ba9acce91a4db239c`
- source state: dirty integration build
- iPad: `iPad1,1` / `K48AP`, iOS 5.1.1 build `9B206`, application `0.3.0`
- installed iPad binary SHA-256:
  `532b06f7dd5ccff32c719d98e9e50b899cfc01fdb065c7f8a7ddbe8c23d3568a`
- iPad artifact-manifest SHA-256:
  `fc0e1a74ffd5e7759bb2d2134db9ef02962116e0784fc4eaa3980f5cb118a312`
- Android source: moto g64y 5G, Android 14, application `0.3.0`, modern debug build
- Android APK SHA-256:
  `2fcf83e008a1e3e11dc50cfe6183f76a9422214815c2ebaff2e9a23d1514bce3`

The local raw evidence record used to produce this summary has SHA-256
`09f7b8b00a0cddd781bfd4bfae509799cd687bf98c8ecf3c89f8adb2006b6eff`.

## Passed observations

- The Android door station created the exact targeted call and the iPad opened
  `DBIncomingScreen`.
- `DBVtVideoView` rendered the Android H.264/fMP4 stream continuously for 20 seconds without
  falling back or oscillating between video views.
- Observed rate was 15.0–15.5 fps, latency 20–33 ms, and jitter 6–8 ms. A separate post-safe-mode
  recheck observed 16.3 fps, 29 ms latency, and 8 ms jitter.
- The no-video label remained hidden and the diagnostic path reported `H.264 LOW-LAT`.
- Matching cancellation returned the iPad to `DBHomeScreen`.
- After Android Wi-Fi loss and rejoin, a new targeted call restored the same fMP4 view.
- Three bounded process failures entered local safe mode; five healthy minutes cleared safe mode,
  after which a new Android call restored the fMP4 view.
- A later live call after that recovery opened `http://10.10.39.174:47180/stream.mp4`, created a
  640×360 VideoToolbox session, logged `first frame displayed`, and rendered 326 consecutive frames
  before matching cancellation. Observed average latency was 26 ms and maximum latency was 71 ms.
- The exact ringing call identity, stage revision, and 64-bit Core expiry survived an iPad process
  `SIGKILL` and the recovered UI returned to `DBIncomingScreen`.

## Open gates

- The optional root helper was not installed. SpringBoard relaunched the killed UIKit process in
  the background, where the foreground-only VideoToolbox renderer correctly remained stopped.
  Unattended foreground video resume therefore remains a helper/device-qualification gate; it is
  not an fMP4 transport or decoder failure.
- The Android APK is debug-signed and both artifacts came from a dirty integration tree.
- Acoustic microphone/speaker quality, DTMF/mute/route behavior, active-call recovery,
  memory-pressure recovery, cold boot, power loss, package rollback, enclosure behavior, and a
  long thermal/memory soak remain open.
- This test used the Android door station's Core fMP4 output. It does not qualify the separate
  iPad-side RTSP/RTP-over-TCP external-camera ingest path.

The result therefore upgrades only the exact foreground Android-to-Core-fMP4-to-iPad renderer
path from host-only evidence to bounded real-device evidence. It does not make the iPad deployment
hardware-certified.
