# Physical device availability inventory

Observed on 2026-09-22, approximately 23:14–23:21 Asia/Tokyo. This is a read-only
availability inventory, not a platform qualification result. No production
source, canonical task status or device configuration was changed.

Read the repository device record, Codex device-access memory, the Claude
project MEMORY index and the relevant iPad/mini 3/iPhone/build runbooks.
`inventory.json` records source-document hashes, observation times, read-only
commands, exit codes and selected metadata. `connection-checks.json` records the
effective Air 1 SSH settings, saved host-pin presence and current device list.

## Current observations

| Target | Current access and identity | Installed Doorbell | Process / API observation | Qualification availability |
|---|---|---|---|---|
| iPad Air 1 | Existing `doorbell-ipad-air1` alias connects directly to `10.10.38.199:44`; strict saved host verification. Device reports `iPad4,2`, ARM64 CPU type 16777228, iOS 12.5.8 (16H88). | 0.1.36, build 37; bundle resolved with `uicache -l`, then selected Info.plist fields read. | Doorbell PID 925 matches the resolved bundle path. GET `/api/status` returns HTTP 401. | **Available for subsequent explicitly scoped native/UI tests.** SSH and HTTP response are verified; authenticated Core state, SIP/media and screen behavior are not qualified here. |
| iPad 1 | Direct SSH to `10.10.38.147:22`, existing known-host pin, recorded authentication and required legacy RSA compatibility. Device reports `iPad1,1`, ARM CPU type 12/subtype 9 (armv7), iOS 5.1.1 (9B206). | 0.3.23, build 26; `/Applications/Doorbell.app/Info.plist`, minimum iOS 5.1. | UIKit Doorbell job PID 30018 and existing keepalive PID 19. GET `/api/status` returns HTTP 401. | **Available for subsequent iOS 5 checks.** Sparse shell is accounted for; no app restart or helper action performed. |
| iPad mini 3 | Recorded address `10.10.38.79`; both recorded SSH ports 44 and 22 refuse connections. Existing pins are present, but no SSH session reached authentication. No iOS USB device was listed. | Not read in this inventory. Historical app/OS values are not substituted for current evidence. | GET `10.10.38.79:47180/api/status` returns HTTP 401. This proves the recorded HTTP endpoint answers, not the physical model/current executable. | **Partial access only.** HTTP responds; native inspection/redeployment cannot currently use the recorded LAN SSH or an attached USB path. The device is not declared offline merely because SSH is unavailable. |
| iPhone 17 | Existing paired CoreDevice `54DB00FE-62A0-5739-9679-B7C513DFCEC4`, local-network transport. Fresh details report `iPhone18,3`, arm64e, iOS 27.0 (24A437), booted and Developer Mode enabled. | 0.1.16, build 17 from the device's application list. | Two successful process-list reads found no Doorbell executable. The historical `10.10.38.80:47180` address timed out; its current DHCP address was not inferred from that old address. | **Available to CoreDevice for read-only inspection; app is not running.** No launch, termination, install, unlock or permission change was attempted. On-demand CoreDevice tunnel connection succeeded; later idle/disconnected tunnel state is not treated as loss of pairing. |
| Android / recorded Moto | `adb devices -l` succeeds with zero attached devices. Only the documented Moto address `10.10.39.174:47180` was checked; it timed out. | Not read. | No authenticated ADB target or current app response established. | **No available Android runtime target established.** API 19 and modern Android physical qualification remain unperformed, independent of local build tools. |
| Windows / recorded test node | Documented `10.10.38.43` (`ox-nas.local`) accepts TCP connections on its recorded RDP 3389 and SMB 445 ports. | Not read. | Recorded Doorbell API port 47180 times out. No remote Windows shell/session was opened. | **Host endpoint reachable; app/OS qualification unavailable through the checked channels.** Open ports do not prove current Windows edition/architecture or app state. |
| tvOS / Apple TV | No Apple TV appeared in the current paired CoreDevice list or iOS USB list; no physical endpoint is documented in the reviewed access runbooks. | Not read. | Not observed. | **No physical tvOS target established.** Existing simulator build evidence is separate. |
| iPad mini 1 / iOS 9 armv7 lane | No usable endpoint/pin/device identity for this target was found in the reviewed device-access records or current connected-device lists. | Not read. | Not observed. | **No physical target established.** Historical SDK availability does not supply a device. |
| Other saved iPhone | CoreDevice lists `iPhone14,7` with an unavailable tunnel. | Not read. | Not observed. | Not an available qualification target in this inventory. |

## Interpretation and next test boundaries

The user was correct that LAN SSH provides real test access: both Air 1 and
iPad 1 were reached without USB. Air 1's existing alias retained
`StrictHostKeyChecking=true`, its dedicated known-host file and existing key.
iPad 1 used its existing known-host entry with strict checking; no installer
options that disable host verification were reused.

HTTP 401 is a successful reachability observation, not an authenticated state
read or an application functional PASS. Installed app version/build and a live
process are separately recorded. This inventory does not assume the live Core
revision matches the installed file merely because a process exists. No login
attempt was made against the administration APIs, so Core revision/owner/media
state remains unread.

The next physical test work can use the verified Air 1 and iPad 1 access paths.
Mini 3 needs its existing access path recovered or the device attached before
native checks; this inventory deliberately did not modify its service or reboot
it. iPhone 17 requires a separately scoped foreground/run test and current build
before it can qualify these changes. Android, the Windows application, physical
tvOS and iPad mini 1 need an actually accessible corresponding test target.
These gaps do **not** close or waive any pending task or device gate.

## Actions excluded from this inventory

No device/app restart, installation, service reload, role change, pairing change,
boot/configuration edit, permission request, call, unlock, SOS, backup, screenshot
request or network-range scan was performed. The SSH sessions executed metadata
reads only. Existing recorded credentials were supplied privately for the one
authorized legacy SSH login; no credential value, private key or boot contents
were printed or saved in evidence. Only selected plist fields were retained;
device application bundles/data were not copied or backed up.

The first iPhone process query used an unsupported CoreDevice predicate and
failed before returning its result; it was replaced with successful JSON process
listing and local filtering. No device state changed. Historical memories were
used as access hints, and their older OS/app values were superseded by fresh
device metadata where available.
