# Provisioning iOS Stations (supervised SAM kiosk / Ad Hoc distribution) + tvOS monitor

Target: the iOS app in `ios/` (`jp.keihan.doorbell` — serves as both door station and indoor
panel) and the tvOS app (`jp.keihan.doorbell.tv` — a monitor). Repurpose scrap iPhones/iPads
running iOS 12+ as door stations and indoor panels. Counterpart of the Android procedure
`deploy/provision/android/provision.en.md`.

## 0. Build and signing overview

- Build: `xcodebuild -project ios/Doorbell.xcodeproj -scheme Doorbell -sdk iphoneos`
  (requires an Apple Developer Program team — just pick a Team under Signing & Capabilities in
  Xcode. In CI, use `-allowProvisioningUpdates` or manual profiles).
  The core (C++) is built automatically by a run-script via CMake — the dev machine only needs
  `cmake` and `python3`. Build the lane-matched PJSIP artifact first with
  `tools/build_pjsip_ios.sh`. A SIP-stub build is development/display-only and must not be
  distributed as a calling release.
- Distribution is **Ad Hoc** (assuming a small number of home devices):
  1. Register each device's UDID in Apple Developer (limit 100 devices/year).
  2. Xcode → Product → Archive → Distribute App → **Ad Hoc** → export the ipa.
  3. Install the ipa with Apple Configurator (device connected to the Mac via USB).
- **Watch the certificate expiry**: Ad Hoc provisioning profiles **expire after 1 year**, and the
  app stops launching once expired. **Annual re-signing and re-installation is mandatory** —
  a calendar reminder is strongly recommended (check the expiry date in Xcode's Organizer or under
  Profiles on developer.apple.com). For a hardened long-term setup, move to App Store distribution
  (unlisted app) or Apple Business Manager + Custom App distribution.
- Verification without a developer account is possible with a "free team + 7-day signing"
  (weekly re-signing required — unsuitable for permanent installation).

## 1. Preparation (on the device)

1. **Factory-reset** the device (Settings → General → Transfer or Reset). **Supervision requires
   a reset** — the device is erased when you "Prepare" it in Apple Configurator.
2. Leave initial setup to Apple Configurator's "Prepare" wizard
   (skip Apple ID sign-in).
3. Connect Wi-Fi to the home LAN (the mesh assumes a single segment — docs/en/network-ports.md).
4. Settings → Display & Brightness → **Auto-Lock = Never** (only selectable on supervised
   devices). The app also prevents screen-off via `isIdleTimerDisabled`, but this doubles the
   insurance.

## 2. Supervision + SAM (Single App Mode) — kiosk hardening

As the resident kiosk mechanism equivalent to Android's Device Owner, iOS uses
**Single App Mode on a supervised device** (Guided Access can be exited manually, so it is only a
fallback).

In Apple Configurator (free on the Mac App Store):

1. Connect the device via USB → "Prepare" → supervise it (create an organization; keep the
   supervision identity certificate — needed for later configuration changes).
2. "Add" the app (Ad Hoc ipa) → install from Apps.
3. **Single App Mode**: "Actions" → "Advanced" → "Start Single App Mode" → choose Doorbell.
   From then on, only this app runs even after reboots (home/Notification Center/Control Center
   are all locked out). Exiting also requires Configurator (physical access + the supervision
   certificate = anti-theft).
4. Recommended additional profiles (Configurator → create profile):
   - Software-update deferral (the door station won't fall into an update screen on its own)
   - No passcode requirement (the ring screen is never blocked by the lock screen — under SAM the
     device never drops to the lock screen anyway)

The app's hidden admin entrance (7 taps top-right → PIN keypad) works even under SAM. Before
enabling SAM, provision a unique PIN hash through the approved maintenance path; do not deploy a
shared or factory value. A correct PIN shows maintenance info (node id / peers / data dir) and temporarily releases
the auto screen-off. By SAM's nature, exiting the kiosk itself is only possible from
Configurator.

## 3. Placing boot.json

On first launch, defaults are generated at `Documents/boot.json`. Before Core starts, iOS/iPadOS
requires the operator to choose **Door station** or **Indoor panel**. A legacy profile without an
explicit `setup_complete:true` is shown once for confirmation as well. Door station additionally
requires a door ID and receives a random `door-xxxxxxxx` default; the screen reappears whenever
the saved role is invalid or a door-station ID is missing. Indoor panel intentionally stores no
door assignment. Ways to edit the resulting profile (any works):

- **File sharing via Finder / Apple Configurator**: the app currently does not expose File
  Sharing, so injection via the admin webui is the primary route (below).
- **Admin webui**: on another node already in the mesh, open `http://<ip>:47180/admin/` →
  Devices → invite this device with a join PIN.
- Do not hand-write a PSK. After pairing, the non-secret persistent shape is:

```json
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_ref": "secret:mesh.psk",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
```

Core writes `mesh.psk` to Keychain first, then emits only
`{t:"paired", psk_ref:"secret:mesh.psk"}` for boot persistence; the shell never receives a new
`psk_hex`. `pairing_persistence_error` must remain not-ready. Never place a PSK, SIP password,
token, or other credential in `boot.json`.

**seed_peers is mandatory on iOS**: iOS 14+ requires a special entitlement for multicast
send/receive (com.apple.developer.networking.multicast — granted by application to Apple), so do
not rely on the core's UDP-beacon auto-discovery. With one seed on the same L2, gossip connects
everyone. On first launch a "Local Network" permission dialog appears — **always allow it**
(denying it means no mesh connectivity at all; changeable later under Settings → Privacy →
Local Network).

## 4. tvOS monitor (DoorbellTV)

- Apple TV 4K/HD (tvOS 15+). Build with `-scheme DoorbellTV`; Ad Hoc works like iOS
  (pair the Apple TV over the network via Xcode → Devices and Simulators).
- The role is the same as Android TV: a resident monitor with role=indoor_panel. On a visit it
  shows a full-screen ring (door live MJPEG + quick replies picked with the Siri Remote). The SOS
  alarm full-screen display + siren + PIN cancel (keypad drawn on screen, operated with the
  remote) also appear.
- **Limitations**:
  - The source implements direct-SIP **listen-only audio** alongside video and quick replies. The
    tracked CI job proves only an unsigned arm64 DoorbellTV **Debug** build for the tvOS simulator
    with real PJSIP; it does not produce a tvOS Release/device artifact. Apple TV has no
    microphone, so Answer is intentionally hidden and audio transmit/two-way talk is unsupported.
  - tvOS has no permanent local storage (the OS purges Caches at will). The boot.json
    equivalent is kept in UserDefaults, and the CRDT config / event DB live in Caches — if wiped,
    they are restored automatically from the mesh (self-healing). Do not use a lone Apple TV for
    long-term event history.
  - Foreground-only (tvOS apps cannot stay resident in the background). If sent back to the Home
    screen, it will not receive rings — operate it by "leaving Doorbell TV on screen" +
    Settings → General → Screen Saver = Never.

## 5. Verification checklist

1. Launch → idle screen (clock + call button). `name · vX.Y.Z` appears bottom-left.
2. The admin webui dashboard (on another node) lists this device as Online (mesh joined).
3. Door station: tap Call → ring screen + chime on indoor panels/TV. Also check the purpose
   buttons and language bar.
4. Indoor panel: quick reply → large text + speech at the door station (AVSpeechSynthesizer).
5. Indoor panel: Monitor → the door audio is audible / Answer → two-way call (speakerphone works
   thanks to VoiceProcessingIO's AEC).
6. tvOS: treat the tracked Debug simulator build as a source/build contract only. Before deployment,
   create and record a separately signed device artifact, then verify Monitor audio/video and that
   there is no Answer/transmit control on the exact Apple TV.
7. Long-press SOS → verify the recipients/channels selected by the active rules, then PIN cancel.
8. Power loss → power restore: confirm automatic recovery (SAM relaunches automatically).
