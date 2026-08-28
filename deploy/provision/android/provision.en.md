> Japanese original: provision.ja.md (canonical)

# Provisioning an Android Door Station (kiosk / Device Owner)

Target: the door-station app in `android/` (`jp.keihan.doorbell`). minSdk 21 — repurpose scrap
tablets/phones running Android 5.0+ as door stations. This is the counterpart of the Windows
procedure `deploy/provision/windows/provision.cmd`.

## 1. Preparation (on the device)

1. **Factory-reset** the device (Settings → System → Reset). Becoming Device Owner is only
   possible "right after setup with no accounts added".
2. During initial setup, **do not add a Google account** (skip it).
3. Enable Developer Options (tap the build number 7 times) → turn **USB debugging** ON.
4. Connect Wi-Fi to the home LAN (the mesh assumes a single segment — docs/en/network-ports.md).

## 2. Installation

```sh
# ビルド (開発機):
cd android && ./gradlew assembleRelease   # または assembleDebug
adb install -r app/build/outputs/apk/release/app-release.apk
```

## 3. Becoming Device Owner (required for full kiosk)

```sh
adb shell dpm set-device-owner jp.keihan.doorbell/.AdminReceiver
```

On success it prints `Success: Device owner set to package jp.keihan.doorbell`.

- `java.lang.IllegalStateException: Trying to set the device owner, but device owner is
  already set` → redo the factory reset from step 1 (an existing account/DO remains).
- With Device Owner, the app is **fully pinned** via `setLockTaskPackages` + `startLockTask`:
  status bar, home, back, and recents are all disabled.
- **Lock screen**: with DO it is disabled automatically at startup (`setKeyguardDisabled` +
  screen-always-on while charging + deferral of system-update popups). **On non-DO devices,
  manually set Settings → Security → Screen lock = None** (if the device enters the lock screen,
  the ring screen gets blocked — the ring Activity itself appears over the lock screen via
  showWhenLocked, but the normal idle screen is covered).

## 4. Placing boot.json

On first launch, defaults are generated at `filesDir/boot.json`. Edit and replace it:

```sh
adb shell "run-as jp.keihan.doorbell cat files/boot.json"   # 確認 (debug ビルドのみ run-as 可)
cat > boot.json <<'EOF'
{ "name": "genkan-front", "role": "door_station", "door": "d_front",
  "listen_port": 47172, "http_port": 47180, "psk_hex": "<64hex>",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": true }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"
adb shell rm /sdcard/boot.json
```

For release builds (run-as unavailable), inject it via the admin webui
(`http://<device>:47180/admin/`) or use a managed configuration via DO (late Phase 3).

## 5. Replacing HOME (the launcher) and autostart

MainActivity carries `android.intent.category.HOME`. If kiosk=true:

```sh
# 既定ホームに設定 (機種の設定 UI: 設定→アプリ→既定のアプリ→ホームアプリ → ドアホン)
# DO 化済みなら adb からも可:
adb shell cmd package set-home-activity jp.keihan.doorbell/.MainActivity
adb reboot   # 再起動して自動起動 (BOOT_COMPLETED + HOME) を確認
```

## 6. Admin entrance (exiting kiosk)

- **Tap the transparent area in the top-right corner (200dp square) 7 times within 5 seconds**
  → PIN entry.
- The PIN is the SHA-256 hex in `filesDir/exit_pin.txt`. If absent, the default is `000000` —
  **always change it at installation time**:

```sh
printf '%s' '123456' | shasum -a 256 | cut -d' ' -f1 > exit_pin.txt
adb push exit_pin.txt /sdcard/ && adb shell "run-as jp.keihan.doorbell cp /sdcard/exit_pin.txt files/"
```

- 5 failures lock it for 10 minutes (in-process). On success, the lock task is released and the
  app closes.

## 7. Removing kiosk entirely (decommissioning)

```sh
adb shell dpm remove-active-admin jp.keihan.doorbell/.AdminReceiver   # DO 解除 (API による)
# 解除できない機種は端末初期化が確実
adb uninstall jp.keihan.doorbell
```

## 8. Android TV (indoor monitor)

Installing the same APK on an Android TV makes it an indoor monitor: when the doorbell is pressed,
a visitor-monitor screen overlays whatever you are watching in full screen, showing the door
camera's live video + the door microphone's audio. You can respond by picking a quick reply with
the TV remote (D-pad).

### 8.1 Connecting and installing

```sh
# TV 側: 設定 → デバイス設定 → 開発者向けオプション (ビルド 7 連打) → USB/ネットワークデバッグ ON
adb connect <TVのIP>:5555
adb install -r app/build/outputs/apk/release/app-release.apk
```

### 8.2 boot.json (a TV is an indoor_panel)

```sh
cat > boot.json <<'EOF'
{ "name": "living-tv", "role": "indoor_panel",
  "listen_port": 47172, "http_port": 47180, "psk_hex": "<64hex>",
  "seed_peers": ["10.0.1.10:47172"], "ui_lang": "ja", "kiosk": false }
EOF
adb push boot.json /sdcard/boot.json
adb shell "run-as jp.keihan.doorbell cp /sdcard/boot.json files/boot.json"   # debug ビルド
adb shell rm /sdcard/boot.json
```

kiosk is **false** (the TV is normally used as a TV). From the admin UI, set
`devices.<tv_node_id>.local.tv = true` as a marker (docs/en/config-schema.md).

### 8.3 Permissions (required so the app can overlay the foreground on a visit)

Android 10+ restricts starting screens from the background. On a TV, granting "Display over other
apps" exempts the app (doable entirely via adb):

```sh
adb shell appops set jp.keihan.doorbell SYSTEM_ALERT_WINDOW allow
# 監聴に SIP は使わないが確認: 通知 (常駐サービス用, Android 13+)
adb shell pm grant jp.keihan.doorbell android.permission.POST_NOTIFICATIONS 2>/dev/null || true
```

For a TV that can become Device Owner (right after a factory reset), §3's DO route also works, but
since watching TV is the primary use, the appops above is usually enough.

- Residency: a foreground service (one notification) + BOOT_COMPLETED start. TVs kill background
  apps leniently, but on first use open the app once from the launcher to start the resident
  service.
- Whether it rings on a visit is governed by the fleet's trigger_rules (chime action) — when
  devices is omitted, all indoor_panels are targeted, so the TV rings by default.

### 8.4 Audio listen-in and Asterisk

The TV's listen-in does **not go through Asterisk**. The TV sends a direct INVITE to the door
station's SIP listener (UDP `sip.direct_port`, default 47190) with `X-Doorbell-Mode: monitor`, and
the door station returns only its microphone audio one-way (no audio from the home side is sent).
Therefore:

- **No Asterisk-side configuration changes** (no dialplan changes, no TV extension account).
- TV listen-in works even in homes where the config `sip.server` is unset.
- Even while the door station is in an Asterisk call (ringing out), additional monitor calls are
  accepted (up to 2).
- If you tighten the LAN firewall, open UDP 47190 (SIP) and UDP 4000-4099 (RTP) between stations
  (docs/en/network-ports.md).

### 8.5 Verification

1. Press the door station's call button (or `curl -X POST http://<門口機>:47180/api/press`).
2. The visitor monitor appears over the TV picture, with video + the door's audio.
3. Pick a reply with D-pad up/down and confirm → the door station shows it on the panel + reads it
   via TTS → "Sent".
4. Press BACK to close → the monitor call ends (door-station log: monitor call ended).
