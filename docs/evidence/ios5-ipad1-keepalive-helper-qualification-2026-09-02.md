# iPad 1 root keepalive helper — device qualification record — 2026-09-02

This is a bounded device-qualification record for the optional root keepalive helper
(`tools/helper/doorbell_keepalive.c`, `ios-compat/helper/`). It records what was observed on the
exact device and root environment below, and what was changed as a result. It is not a
hardware-certification or release-signing claim.

## Test identity

- device: `iPad1,1` (K48AP), iOS 5.1.1 build `9B206`, jailbroken, MobileSubstrate present
  (`MobileSafety.dylib`, `patcyh.dylib`), SSH root over USB (`iproxy -u <udid> 2223 22`)
- application: `ios-kiosk` build installed through `ios-kiosk/scripts/install_via_ssh.sh`
  (binary SHA-1 `5f574794523bc5f11521a6125fde2346ec9f7480` during checks 1–14; the identifier
  rename to `jp.ox.doorbell` landed afterwards)
- helper package under test: `doorbell-keepalive.deb` SHA-256
  `cd531c3709e69a12e6a4050c14811d6e231d5c4e19e0b29713d82545d7345848` (helper 0.3.4 with the
  fixes listed below; earlier boots used `32a8f55f…` and `d2149fdc…`)
- source revision at the end of the run: `351b2e8` on `pairing-ux/integ`
- launchd label during the run: `jp.keihan.doorbell.keepalive` (renamed to
  `jp.ox.doorbell.keepalive` in the same branch afterwards)

## Result table (checklist from `ios-compat/helper/README.md`)

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Cold boot ×3 | **pass** (boots 2, 3, 4; boot 1 exposed the activation finding) | Boot 2 20:05:43: launchd PID 19, `activation_nudges 1` → `healthy`, HTTP 401 in 114 ms, `restart_count_5m 0`, `safe_mode false`. Boot 3 20:14:40: same, HTTP in 21 ms. Boot 4 20:21:41 (soak start): same. |
| 2 | Unprovisioned boot | **pending** | Requires the bootstrap-setup screen; not exercised on this provisioned device. |
| 3 | Kill | **pass** | 19:41:39 `killall Doorbell` → log `process_exited; restart scheduled after 2000 ms`, one relaunch (PID 214 → 373), `restart_count_5m 1`. |
| 4 | Hang | **pending** | No diagnostic hook to freeze the kiosk main loop; not exercised. |
| 5 | Crash loop | **pass** | Three kills inside five minutes: `restart_count_5m` 1 → 2 → 3, `safe_mode true`, marker `/var/db/doorbell-keepalive-safe-mode.json` written 20:18, log ladder `2000 ms` → `5000 ms` → `10000 ms in safe mode`. |
| 6 | Launch cap | **partial** | The ladder was observed on the device (`2000 → 5000 → 10000 → 30000 → 60000 ms in safe mode`, 16+ cycles) but neither 9- nor 13-minute kill loops reached ten safe-mode launches: iOS itself relaunches the `voip` app, so only nudges ran and — before the fix — they were uncapped. Nudges now obey the ladder and count toward the cap (host test `test_nudges_in_safe_mode_count_toward_the_launch_cap`); reaching `launch_inhibited` on the device needs a ≥ 12-minute run and is left for the soak review. |
| 7 | Maintenance lease | **pass after fix** | First run: kill under `--control begin 25` was not charged during the lease, but expiry charged `process_exited` (`restart_count_5m 1`). Root cause: every heartbeat cleared `maintenance_exit_grace`. Fixed; rerun: `maintenance_exit; no failure charged`, `restart_count_5m 0` after expiry, supervision resumed. |
| 8 | Permission rejection | **pass** | Socket `srw-rw---- root mobile /var/run/doorbell-keepalive.sock`; `SAFE_MODE_CLEAR` over the socket answers `{"ok":false,"error":"root_required"}`. Non-app UIDs cannot open the 0660 socket. |
| 9 | Mode wiring | **pass** | `boot.json` `keepalive_helper` `auto` → `off`: helper `configured_mode off`, `state off`, mode file `off`; back to `auto`: `healthy`, mode file `auto`. Survived helper restart/reboot (boot 4 came up `auto`). |
| 10 | Kill switch | **pass** | Log: `kill switch engaged at /var/db/doorbell-keepalive.disable` then `released` within one tick; rerun captured `mode off`, `state disabled_by_file`, `configured_mode auto` unchanged while engaged; release → `healthy` with no failure. |
| 11 | Upgrade under the helper | **pass** | `install_via_ssh.sh` took the lease (`state maintenance`), swapped the app, released it (`last_reason maintenance_ended`), `restart_count_5m 0`. |
| 12 | Power loss | **pending** | Physical power cut not possible remotely. |
| 13 | Soak | **running** | Started 20:21:41 at boot 4; evaluate after 24 h (log cap 262144 bytes, no spurious relaunch). |
| 14 | Rollback | **pass** | `--disable` removed the active definition (`/Library/LaunchDaemons` empty), the app kept serving (HTTP 401), staged binary and template survived under `/usr/local/`. |

## Findings and changes made during qualification

1. **iOS relaunches the app itself after a reboot, in the background.** The kiosk declares the
   `voip` background mode, so after every cold boot the process was already present before the
   helper's boot grace expired; the helper's own launcher never ran. SpringBoard never activated
   that process: Core started and listened (TCP connects on 47172/47180) but HTTP requests hung,
   no heartbeat arrived, the screen stayed on the launcher or the post-boot lock screen, and the
   theme background never rendered. A second `uiopen doorbell://` against the running process
   activated it (PID 373 → `healthy`, HTTP 401 in 18 ms). Change: bounded **activation nudge** —
   while a present app stays silent and SpringBoard is up, re-run the fixed launcher every
   `--activate-interval-ms` (15 s); no failure charged, no backoff, `DOORBELL_ACTIVATE=1`,
   `activation_nudges` in status. Host test added. On boots 2–4 exactly one nudge fronted the app.
2. **Installer assumptions about the iOS 5 busybox.** `openssl sha256` (no such subcommand on
   OpenSSL 0.9.8zg → `openssl dgst -sha256`), `id` (→ `/etc/passwd`), `touch` (→ `: > file`),
   `/usr/sbin/chown` (→ `chown`). `ps`, `awk`, `cut`, `stat`, `head`, `tail` are also absent.
3. **Multiple USB devices.** An unpinned `iproxy` attached to a different iPad; the installer
   now honours `DB_IOS_UDID` and recognises a pinned forward.
4. **Maintenance grace revoked by heartbeats** (check 7) — fixed as described above.
5. Boot 1 (before the nudge existed) reached `launch_pending_no_heartbeat` with
   `app_process_present true`; this is the unprovisioned-boot signature the README describes, but
   here the app was provisioned and merely inactive. The nudge distinguishes the two by outcome:
   a provisioned app heartbeats after the nudge, an unprovisioned one stays silent.

## Later boots (identifier rename)

Boot 5 (21:02, after a hard reset — the device did not return from the 20:45 reboot over USB for ~15 min; cause not established) and boot 6 (21:0x) ran with the renamed daemon `jp.ox.doorbell.keepalive`: loaded (PID 19), nudges fronted the app, `healthy`. Two more findings: `uicache` must run as `mobile`, not root (a root run left SpringBoard unable to launch the renamed app until a respring); and the kiosk's own **local safe mode** (three unclean exits in five minutes, latched in NSUserDefaults) disables every H.264 strategy (`DBIncomingScreen.m`), so after crash-loop testing the indoor panel plays MJPEG only until that key is cleared — worth an automatic clear after a healthy period (follow-up).

## Still open

- Checks 2, 4, 6 (this run), 12 and the 24 h soak (13) as noted in the table.
- The post-boot lock screen: the nudge fronts the app as soon as the device is unlocked; whether
  the app is fronted while the screen is locked was not established in this run.
