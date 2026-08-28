[日本語](ipad1-jailbreak.ja.md) | [English](ipad1-jailbreak.en.md) | [中文](ipad1-jailbreak.zh.md)

# Turning an iPad 1 (A1219, iOS 5.1.1) into a doorbell node

Steps to turn a first-generation iPad (2010, A4, 256MB, **no camera, no microphone**)
into a **first-class node of the doorbell mesh** with a jailbreak plus a self-built
native app. The full C++17 core (doorbell-core) runs on armv7/iOS5.1 — this really
works (proven on A0/B).

## What this device can and cannot do (hardware limits)

| | Possible? | Reason |
|---|---|---|
| See the live video at the door | ✅ | Receives MJPEG, decodes on the A4 |
| Hear the audio at the door | ✅ | Direct call to the door station over mini SIP, plays through the speaker |
| Quick replies / unlock (on-screen) | ✅ | C ABI + SIP DTMF `*1` |
| Config sync & events as a mesh node | ✅ | Full core on board |
| **Send your own voice (two-way talk)** | ⚠️ external mic required | No built-in mic. Works if you plug in a headset (TRRS) / dock mic |
| **Send your own video** | ❌ not possible | No camera physically present |

## 0. Prerequisites (on the host Mac)

The build artifacts and toolchain are already prepared in the repo under `tools/` and `ios-legacy/`:
- `tools/sdk/iPhoneOS7.1.sdk` — extracted from the Xcode 5.1 DMG (sysroot; gitignored)
- `tools/toolchain/ios5-armv7/` — self-built modern libc++/libc++abi/libunwind (regenerate with `tools/build_libcxx_ios5.sh`)
- `ios-legacy/lib/libdoorbell_all.a` — armv7/iOS5.1 build of the core (`ios-legacy/scripts/build_core_ios5.sh`)
- `ldid` (`brew install ldid`)

To rebuild the SDK: `hdiutil attach` the Xcode 5.1 (or 4.x) DMG and copy
`.../iPhoneOS.platform/Developer/SDKs/iPhoneOS7.1.sdk` into `tools/sdk/`.

## 1. Jailbreak the iPad 1 (untethered)

**Legacy iOS Kit** (LukeZGD) — an untethered jailbreak tool for the iPad 1 that runs on modern macOS.
1. `git clone https://github.com/LukeZGD/Legacy-iOS-Kit && cd Legacy-iOS-Kit`
2. Connect the iPad 1 over USB → `./restore.sh` → pick **Jailbreak (untethered)** from the menu.
   (If needed, first restore to 5.1.1 — Restore/Downgrade in the menu. For the NVRAM-clear
   procedure see the Kit's wiki.)
3. When done, the iPad has **Cydia** installed.
- Alternatives: Absinthe 2.0 / redsn0w 0.9.12b1 (the untethered tools of that era, if you have a host that runs them).

## 2. Post-jailbreak groundwork

1. In Cydia, install **OpenSSH** (to push the app over SSH).
2. Install **AppSync Unified** (to allow ldid pseudo-signed apps).
   - Add the source `https://cydia.akemi.ai/` → install AppSync Unified.
   - If the source is down, install via the Kit's App Management or `dpkg -i` the .deb manually.
3. Note the iPad's IP (Settings > Wi-Fi). Default SSH: `root@<ip>` / password `alpine`
   (**always change it with `passwd`**).

## 3. Build the app and push it (host Mac)

```bash
cd app-doorbell
bash ios-legacy/scripts/build_core_ios5.sh   # core .a (first time / on update)
bash ios-legacy/scripts/build_app.sh          # produce Doorbell.app + ldid pseudo-signing
# push (either one)
scp -r ios-legacy/build/Doorbell.app root@<ipad-ip>:/Applications/
ssh root@<ipad-ip> "uicache"                  # show it on the home screen
#   ── or use Legacy iOS Kit's Install IPA
```

## 4. Initial setup on the iPad

1. Launch "Doorbell" on the home screen.
2. First-run settings (in-app or `/var/mobile/.../boot.plist`):
   - `role` = `indoor_panel`
   - `seed_peers` = one or more `IP:47172` of existing nodes (on the same L2, one is enough to reach the whole mesh)
   - `psk_hex` = cluster PSK (the value issued by "Add device" in the admin UI, or the same as existing nodes)
   - direct SIP target of the door station = `<door-station-IP>:47190`
   - whether an external mic is present
3. Once it joins the mesh, settings (theme, quick replies, subjects, language) sync automatically.

## 5. External microphone (only if you want two-way talk)

Since there is no built-in mic, **speaking** requires an external one:
- Headphone jack: a headset with a mic (TRRS). Whether the iPad 1's 3.5mm jack accepts a
  headset mic depends on the unit/accessory — if recognized, RemoteIO picks up the input.
- Dock connector: a mic-capable dock accessory.
If no mic is present / recognized, it runs "listen only" (you hear the door, your voice is silent).

## 6. Verification

- Ring → the iPad shows the door video full-screen and you hear the door's audio.
- Quick-reply button → large text + text-to-speech on the door station.
- Unlock button → the HA lock opens via the door station (DTMF `*1`).
- Unplug the LAN cable / Wi-Fi → it leaves the mesh within tens of seconds, rejoins on recovery.
- With an external mic: your voice comes out of the door speaker.

## Notes

- A jailbroken device is meant for this doorbell only, on the LAN (never expose it externally). Always change the SSH password.
- Keep it powered and always on (the app disables the idle timer). Watch for battery swelling (if possible, remove the battery and power it directly).
- Do not update the OS (stay on 5.1.1). To update the app, re-run §3.
