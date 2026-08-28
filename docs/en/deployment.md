> Japanese original: ../ja/deployment.md (canonical)

# Deployment Guide (checklist for a real-home rollout)

Follow the steps in order and every device will be integrated into your existing HA / Asterisk /
Hikari Denwa environment. Details for each section are in the documents in parentheses.

## 0. Prerequisites

- [ ] The HA host (x86 iGPU or RPi4+) is running the Mosquitto add-on + go2rtc
- [ ] Asterisk has `deploy/asterisk/pjsip.conf` / `extensions.conf` loaded
      (replace `CHANGE_ME_*` and the mobile number, configure the Hikari Denwa HGW extension) —
      instructions in `deploy/asterisk/README.en.md`
- [ ] Token for the Telegram bot (@ox_doorbell_bot) and the family's chat_id list
- [ ] Battery inspection on every device (check for swelling). Remove the battery and power
      directly if possible

## 1. The first device (the administrative starting point)

Any platform works, but an always-powered door station (Toughpad recommended) is best suited.

- [ ] Windows: extract the `doorbell-windows` artifact from GitHub Actions →
      `deploy/provision/windows/provision.cmd` (as Administrator) → as the kiosk user run
      `kiosk-enable.cmd` → log in again (details: `docs/en/win-build-env.md` §Real hardware)
- [ ] First launch generates `%ProgramData%\Doorbell\boot.json` — edit `name` / `role` /
      `door` / `psk_hex` (make your own 64-hex value) / `seed_peers` and restart
- [ ] In a browser open `http://<device IP>:47180/admin/` → first login = set the admin password
- [ ] **Security initialization**: change the kiosk exit PIN (`exit_pin.txt`, default 000000),
      note down the panel token on the "System" tab

## 2. Configuration skeleton (in the admin UI)

- [ ] Doors / buildings: register each entrance (d_front etc.) and building, with JA/EN/ZH labels
- [ ] Integrations: MQTT (HA's Mosquitto), Telegram (token + poll_updates ON), SIP
      (Asterisk IP + each device's extension/password), tz
- [ ] Notification targets: family chat_ids / extensions in households
- [ ] Call rules: ring → SIP 600 + Telegram + chime. Optionally e.g. delivery (p_delivery) only
      gets auto_reply "leave the package" + no phone call — customize as you like
- [ ] Adjust theme / wording / purposes / quick replies / assets (background images, custom audio)

## 3. Adding devices (as many as you like)

- [ ] Admin UI "System" → "Add device" to issue a PIN (valid 10 minutes)
- [ ] Launch the app on the new device → in initial setup enter an existing node's IP + PIN →
      PSK/config are distributed automatically
      (or write psk_hex/seed_peers directly into boot.json)
- [ ] On the Devices tab assign name, assigned door, and role (door_station / indoor_panel / TV)
- Android: `deploy/provision/android/provision.en.md` (Device Owner = full kiosk; has an Android TV section)
- iOS: `deploy/provision/ios/provision.en.md` (supervision + Single App Mode, Ad Hoc signing and annual renewal)
- Legacy devices such as iPad 1: in Safari open
  `http://<any node>:47180/panel/door?k=<token>` and save it as a Web Clip (same for `monitor`).
  Set Auto-Lock = Never
- To jailbreak an iPad 1 (A1219, iOS5.1.1) into a native node, see
  `deploy/provision/ios/ipad1-jailbreak.md` (full core, audio, unlock; two-way talk with an external mic)

## 4. HA / HomeKit

- [ ] The moment it connects to Mosquitto, entities appear automatically in HA (doorbell event /
      motion / device online / emergency / visitor language sensor)
- [ ] Import `deploy/ha/go2rtc.yaml` adjusted to each door station's IP
      (devices with codec=h264 use `#video=copy` — no transcoding)
- [ ] Import the HomeKit Bridge / watchdog / actionable notifications / unlock automation from
      `deploy/ha/configuration-snippets.yaml` and adjust the entity_ids to your setup
- [ ] Confirm doorbell notifications + live view appear in the iPhone Home app. To view from
      outside the home, use an Apple TV / HomePod as the home hub

## 5. Verification (each time you add a device)

- [ ] Ring → indoor extensions + mobile ring / Telegram photo + buttons / HA notification / indoor chime
- [ ] Reply via a Telegram button → large text + TTS at the door station
- [ ] "Answer" from the indoor panel → the phone leg drops and a two-way call starts (incl. video)
- [ ] During the call press *1 on the mobile → the HA lock opens
- [ ] Unplug a device's LAN cable → offline notification to Telegram/HA within 30 seconds
- [ ] **Even with HA and Asterisk stopped**: ring display, chime, indoor intercom, and panels keep working

## 6. Operations

- Updates: distribute GitHub Actions artifacts (on Windows the watchdog tolerates
  stop → replace → restart. Android uses DO silent install). Tag before updating for easy rollback
- iOS Ad Hoc signing **must be renewed once a year** — follow the in-app expiry display and the
  Telegram warning 30 days ahead (a permanent fix is App Store publication = planned Phase 7)
- Configuration backup: admin UI "System" → Export (full export from any node)
- If a device is stolen: reissue the PSK in the admin UI → re-pair all devices, rotate the SIP
  passwords and bot token
- Windows Update is blocked — apply manually on maintenance days (see `provision.cmd` §6)
