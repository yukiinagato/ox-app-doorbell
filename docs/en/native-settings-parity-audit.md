# Native settings vs web Admin: role switching and parity gaps

Read-only audit of the working tree on `feat/native-ui-redesign` (2026-11-12). The tree was being edited while it was read, so line numbers are a snapshot. Nothing was built or run.

How this was produced: Part 1 was read directly. The Part 2 inventories were produced by five parallel readers (one per surface) and are kept next to this file with one row per setting and file:line:

- `inv-admin.md` (239 Admin rows, ids such as `DEV-05` used below), `inv-android.md`, `inv-ios.md`, `inv-kiosk.md`, `inv-win.md` in `(session scratchpad, not kept)/`

I re-checked the claims marked (checked) against the source myself; the rest rely on those inventories. "not verified" is stated where nobody confirmed a point.

File abbreviations

| abbr | file |
|---|---|
| A-SA / A-NS / A-SM / A-NM / A-BS | `android/app/src/main/java/jp/ox/doorbell/` SettingsActivity.kt / NativeSettingsSections.kt / SettingsModel.kt / NativeSettingsModel.kt / BootSetupActivity.kt |
| I-SC / I-SVC / I-SUI | `ios/Doorbell/` SettingsCatalog.swift / SettingsViewController.swift / SettingsUI.swift |
| K-S / K-P | `ios-kiosk/src/Screens/` DBSettingsScreen.m / DBSettingsPages.m |
| W-Cat / W-Act / W-Adm / W-Ed / W-Lst / W-Row | `win/DoorbellApp/Settings/` SettingsCatalog.cs / SettingsWindow.Actions.cs / .Admin.cs / .Editors.cs / .Lists.cs / .Rows.cs |
| JS | `webui/admin/app.js` |

---

# Part 1. Role switching

## 1.1 What a role is today

- Two roles only: `door_station` and `indoor_panel` (`core/src/node/node.h:30`, `core/src/capi/doorbell_capi.cpp:329,348`, `docs/en/overview.md:14-17`). There is no "monitor" role: a TV monitor is `indoor_panel` plus `devices.<id>.local.tv` (`docs/en/config-schema.md:105-113`). tvOS is fixed to `indoor_panel` (`docs/en/config-schema.md:14-15`, `ios/Doorbell/BootConfig.swift:23-27`).
- Source of truth is the local `boot.json` (`name`, `role`, `door`, `setup_complete`). Each shell has the same validator and atomic writer:
  - Android `BootConfig.persistSetup` (`android/.../BootConfig.kt:96-112`), role check :41-42, door regex :44-45
  - iOS `BootConfig.persistSetup` (`ios/Doorbell/BootConfig.swift:137-177`)
  - kiosk `+persistSetupName:role:door:` (`ios-kiosk/src/Core/DBBootConfig.m:361-386`)
  - Windows `BootConfig.PersistSetup` (`win/DoorbellApp/BootConfig.cs:123-142`)
  - All four keep pairing material (`psk_ref`, `seed_peers`), ports and kiosk flags untouched; a door station requires a door id matching `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, an indoor panel gets `door: ""`.
- Core reads role/door once at start. On start it rewrites the replicated self record from boot (`devices.<self>.name/.role/.door`, `core/src/node/node.cpp:7491-7511`) (checked), deletes a door entry it seeded and no longer serves if nobody edited it (`node.cpp:7537-7565`), and seeds `doors.<door>` for a paired door station (`node.cpp:7572-`). So a role change needs a Core restart, and a boot.json change followed by a Core restart is sufficient: no config write is needed.
- `devices.<self>.name/.role/.door` is also the "remotely editable desired identity" (`docs/en/config-schema.md:23-28`). On `config_changed` the shell validates it, persists boot.json and restarts:
  - Android `App.applyReplicatedIdentity` (`App.kt:243-264`) then `RuntimeSupervisor.restartForIdentityChange` (`RuntimeSupervisor.kt:142-166`): Core destroyed and restarted in-process, `MainActivity` relaunched.
  - iOS `AppDelegate.applyReplicatedIdentity` (`AppDelegate.swift:340-360`) then `restartForIdentityChange` (:373-): Core stopped and the app UI rebuilt in-process.
  - kiosk `applyReplicatedIdentity` (`ios-kiosk/src/Support/DBAppDelegate.m:898-930`): name-only is applied in place; role or door writes a maintenance marker, stops Core and exits the process, relaunched by the root helper or by a `launchctl submit` relauncher (`DBAppDelegate.m:933-941`, `DBWatchdog.m:22-58`).
  - Windows: no such handler exists. `config_changed` only refreshes the home screen (`win/DoorbellApp/MainWindow.CallFlow.cs:328-331`); the only callers of `PersistSetup` are first-run setup and local settings. A remote role edit never takes effect on a Windows device.

## 1.2 What else changes with the role

| area | effect | where |
|---|---|---|
| Door id | required for door station, cleared for indoor; Core seeds / reclaims `doors.<id>` | `node.cpp:7507,7537-7590` |
| Camera / capture | camera, encoder, sensor rotation and motion run only on a door station | `node.cpp:3828-3834`; Android `RuntimeSupervisor.kt:314,348,376`; iOS `AppDelegate.swift:192-195` |
| Permissions | iOS asks camera/mic by role at launch (`AppDelegate.swift:186`, `MainViewController.swift:2204`); Android foreground-service type adds CAMERA only for a door station (`ForegroundTypesApi30.kt:24-31`); kiosk enables the mic by default on a door station (`DBBootConfig.m:328`) | |
| Android commissioning | a door station without a current measurement needs commissioning | `RuntimeSupervisor.kt:509` |
| UI | visitor screen vs dashboard; incoming-call UI only on indoor (`App.kt:239`, `AppDelegate.swift:460`); Windows hides the admin entry on a door station (`MainWindow.Shell.cs:44-52`) | |
| SIP | auto-answer defaults on for door station, off for indoor, unless `sip.accounts.<id>.answer_mode` is set | `node.cpp:5245-5247` |
| SOS button | shown per `emergency.button_on_roles` | config-schema.md:246 |
| Device removal | only an indoor panel may remove devices (`-2` otherwise) | `node.cpp:14000`, doorbell.h:594 |
| Unchanged | node id, public key, PSK reference, seed peers, panel identities, kiosk / lock-task mode | persistSetup implementations above |

Role rotation tooling: nothing in `tools/`, `deploy/` or `docs/` (grep "rotat" finds only key rotation). The owner's memory note `project-device-role-rotation.md` describes it as a manual boot.json edit plus app restart over adb/SSH, "no HTTP endpoint for first-run setup".

## 1.3 Web Admin and Core API

- The Devices tab editor writes `devices.<id>.role` and `devices.<id>.door` for any device through an ordinary `POST /api/config/commit` (`DEV-05/06`, JS 5353-5452, entries built at JS 328-366). Role must be one of the two values; a door station needs a syntactically valid door id (free text with a datalist; the door need not exist and uniqueness is not checked); an indoor panel gets `door: ""`. No confirmation, no "target will restart" notice, no pending/applied indicator. The role select preselects `door_station` for anything that is not `indoor_panel`, so every save writes a role.
- There is no role endpoint in Core: under `/api/devices` only `/api/devices/remove` exists (`node.cpp` ~11446, per inv-admin). The raw key writer on the System tab (`SYS-31`) can also write the key.
- Pick-up is the `applyReplicatedIdentity` path in 1.1: works on Android, iOS and the kiosk; ignored on Windows; tvOS not verified (the shared AppDelegate code would accept `door_station` although tvOS is documented as fixed).

## 1.4 What each native settings UI shows for the role today

| shell | this device | other devices | problems |
|---|---|---|---|
| Android | Row "Role" + note "needs a restart" opens the first-run screen again (`A-SA:509-514`; name :504-508, door :515-519; `A-BS:50-71,97-108`). Save persists boot.json, restarts Core, relaunches the UI (`App.kt:174-187,266-277`) (checked) | none: Devices list offers rename / door / remove only (`A-NS:1418-1467`) | Works, but looks like a read-only row; no confirmation; door id is free text, not a picker; the setup screen has no cancel button |
| iOS / iPadOS | Segmented control indoor / door in This device > Identity (`I-SC:236-242`), door id text field only when already door station (:243-253) | read-only with footer "changed on that device" (`I-SC:1487-1488,1496`) | Writes boot.json only and nothing restarts; toast says it applies when the app is reopened (`I-SVC:251-264`, `i18n/strings.yaml:980`) (checked). On a kiosk-style iPad there is no ordinary way to reopen the app. Switching indoor to door fails first: the door id is empty, `persistSetup` returns nil, toast "save failed", and the page is not refreshed so the door field does not appear until some other refresh (`I-SVC:254-260`) (checked from code, not run). No confirmation |
| tvOS | none (`if !ctx.isTV`, `I-SC:236`); About shows the role read-only (:1149) | read-only | Fixed role by design |
| iOS 5 kiosk | read-only row from boot.json (`K-S:481`), door read-only raw id (`K-S:482-483`) (checked) | read-only Info with footer "A device's role is changed on that device" (`K-P:2100-2103,2113`; `i18n/strings.yaml:2519`) (checked) | No role control anywhere, although the restart path already exists. Door can only be changed in Cluster > Devices > this device (`K-P:2105-2110`), with no warning that the device restarts |
| Windows | Choice in Device > Identity (`W-Cat:192-196`); `WriteIdentity` confirms, writes `devices.{self}.*`, persists boot.json, restarts the app (`W-Act:240-266`) (checked) | Edit form with role and door picker (`W-Ed:836-874`), no confirmation | A Windows door station cannot open settings at all: the admin button is collapsed and the hidden corner only unlocks the kiosk (`MainWindow.Shell.cs:50`, `MainWindow.Pairing.cs:117-124`) (checked). So door to indoor is impossible on Windows. Indoor to door silently assigns a random `door-xxxxxxxx`. Config is committed before boot.json. Remote edits are never applied (1.1) |

So the owner's statement is literally true for the kiosk, tvOS and a Windows door station; on iOS the control exists but does not take effect without a manual relaunch; on Android it works but is not recognisable as an editor.

## 1.5 Recommended design (smallest correct one)

No Core or ABI change is needed. Use one flow on every shell, built from code that already exists:

1. Entry: a real "Change role" row in This device, inside the already admin-gated settings. It must also be reachable on a door station (Windows needs the hidden-corner path to open settings, not only unlock the kiosk).
2. Form (one sheet, nothing is written until Confirm): role segmented control; when door station is chosen, a door picker listing configured `doors.*` that no live door station serves, plus "New door" prefilled with the shell's suggested `door-xxxxxxxx`; keep the validated free-text field as the fallback for an unpaired device. When indoor is chosen, show that the door assignment is cleared.
3. Validate with the existing `validRole` / `validDoor`; warn (do not block) when the chosen door is already bound to another `devices.*` with role `door_station`.
4. Refuse while a call, an SOS or pairing is in progress (whether the existing restart paths check this: not verified).
5. Confirm dialog stating: the app restarts now; a door station needs camera and microphone permission; for door to indoor, the door stays in the door list if an administrator edited it and will show as offline.
6. Apply: call the shell's `persistSetup(name, role, door)` (boot.json first), then the shell's existing identity restart: Android `completeBootSetup` / `activateIdentityChange`; iOS update `AppDelegate.boot` and call `scheduleIdentityRestart` (expose it to the settings controller); kiosk set `_identityRestartPending` and call `restartForIdentityChange`; Windows `App.RestartApp("identity_changed")`. Core then republishes `devices.<self>.*` and fixes the door entries itself (1.1). Writing boot.json first also works unpaired and when Core's config writer is unavailable; if persist fails nothing has changed.
7. After restart, request the role's permissions (iOS already does at launch; Android should prompt for camera and, where required, commissioning).

Follow-ups in the same change:

- Windows: add the missing `applyReplicatedIdentity` so Admin / peer edits work, and in `WriteIdentity` persist boot.json before (or instead of) committing config.
- Other devices: replace the read-only role row (`I-SC:1487`, `K-P:2100`) and add one on Android with the same form writing `devices.<id>.role` + `.door` in one batch, with a confirmation that the target restarts. Hide or disable it for targets that cannot apply it (Windows until fixed, tvOS).
- tvOS: keep read-only, with a one-line reason.
- Optional Core hardening (not required): reject a commit that sets `devices.<id>.role = door_station` without a valid `.door` (whether Core validates this today: not verified).

---

# Part 2. Settings parity

## 2.1 Matrix

Cell legend: OK = equivalent editor; PART = present but poorer (reason given); MISS = no native control; n/a = not applicable. tvOS equals iOS unless stated. Three blanket caveats are not repeated in every cell:

- Windows: all cells describe an indoor panel. A Windows door station has no route to settings (1.4), so door-only rows (`device_door`, `cam_*`, `motion_*`) are dead UI.
- tvOS: list delete, reorder and list-row switches are unreachable (no Edit button; `I-SUI:1114-1117,1228,1165-1177`; not verified on hardware); steppers and sliders become coarse pick-lists.
- Per-device settings: every shell writes `devices.<self>.*` only. Admin edits any device (`DEV-07..31`, Theme scope). "self" in a cell means exactly this.

### Site

| Admin item (id, key) | Android | iOS | tvOS | Kiosk | Windows |
|---|---|---|---|---|---|
| Buildings add/edit/delete (`DOORS-01..04`, `buildings.<id>`) | OK, delete has no confirm (`A-NS:779-809`) | OK, delete no confirm (`I-SC:1420-1422`) | add only | OK (`K-P:2045-2051`) | OK (`W-Ed:190-206`) |
| Doors add / label / building (`DOORS-06..08`) | OK, auto id (`A-NS:765-777,742-754`; `A-SA:669-675`) | OK, auto id (`I-SC:1423-1431`) | add only | OK, auto id (`K-P:2022-2044`) | OK (`W-Ed:208-235`) |
| Door delete (`DOORS-09`) | OK (`A-NS:755-762`) | PART: no confirm | unreachable | OK | OK |
| Unlock button auto/show/hide (`DOORS-10`, `doors.<id>.unlock.show_button`) | OK (`A-SA:665-668`) | PART: on/off toggle, no "auto" (`I-SC:792-796`) | same | PART: toggle (`K-S:633-640`) | MISS |
| Unlock command binding (`DOORS-11`, `doors.<id>.unlock.command`) | PART: free text, no list of commands (`A-SA:676-679`) | MISS | MISS | MISS | MISS |
| Door / global notice publish and clear (`DOORS-13..18`) | OK via NoticeDialog, no custom-hours expiry (`A-SA:656-664`) | OK via dialog (`I-SC:773-774,797-800`; dialog fields not verified) | same | OK via dialog (`K-S:620-643`; not verified) | PART: row only opens the main-window dialog (`W-Cat:335`) |
| Notice presets (`DOORS-20`, `notice.presets`, max 8) | OK, delete no confirm (`A-NS:696-739`) | PART: rows not editable, delete no confirm (`I-SC:804-829`) | add only | OK (`K-P:613-672`) | PART: no max-8 guard (`W-Lst:126-209`) |
| Device list with health, version, battery (`DEV-01`, `DASH-04`) | PART: read-only peers + info dump (`A-SA:696-712`) | PART: no health in list (`I-SC:1470-1506`) | "device info" row inert (`I-SVC:394-396`) | PART: online/offline only (`K-P:2063-2089`) | PART: no online/health (`W-Ed:794-834`) |
| Remove device (`DEV-02`) | OK (`A-NS:1418-1467`) | PART: no confirm (`I-SC:1497-1501`) | same | OK (`K-P:2115-2139`) | OK (`W-Ed:876-895`) |
| Device name, any device (`DEV-04`) | OK | OK (`I-SC:1481-1486`) | OK | PART: no length check (`K-P:2098-2099`) | OK |
| Device role, any device (`DEV-05`) | PART: self only, via setup screen (1.4) | PART: self, no restart; others read-only | MISS | MISS | PART: self unreachable on door station; others no confirm, no effect on Windows targets |
| Device door (`DEV-06`) | PART: self free text; others picker | PART: self free text; others picker (`I-SC:1490-1495`) | others only | PART: self read-only, picker in Devices page | PART: self free text, others picker |
| UI language per device (`DEV-07`) | self (`A-SM:117-118`) | self (`I-SC:255-266`) | self | PART: writes boot.json `ui_lang`, not the config key (`K-S:484-489`) | self (`W-Cat:201-204`) |
| Call return per device + inherit (`DEV-08/09`) | PART: self, no inherit/reset (`A-SM:119-121`) | MISS | MISS | MISS | MISS |
| Recovery helper mode (`DEV-10`) | self (`A-SM:125-126`) | MISS | MISS | PART: boot.json `keepalive_helper`, raw labels (`K-S:490-494`) | MISS |
| Video playback (`DEV-11`, low_latency/hls/mjpeg) | WRONG VALUES: offers auto/h264/mjpeg, which Core ignores (`A-SM:143-144` vs `node.cpp:3697-3706`) (checked) | self (`I-SC:269-274`) | self | self (`K-S:508-513`) | self (`W-Cat:402-404`) |
| Video rotation (`DEV-12`) | PART: no "auto", cannot return to it (`A-SM:145-147`) | self | self | self | self |
| Camera codec, resolutions, fps, quality, bitrate (`DEV-13..15,17..20`) | MISS | self, door station only (`I-SC:332-367`) | n/a | MISS | present but unreachable (`W-Cat:372-390`) |
| Camera device hint (`DEV-16`) | MISS | MISS | n/a | MISS | unreachable, free text |
| Visitor layout (`DEV-21`) | MISS | self, door (`I-SC:289-294`) | n/a | MISS | MISS |
| Motion enable / sensitivity / interval (`DEV-22,24,25`) | MISS | self, door (`I-SC:370-380`) | n/a | MISS | unreachable (`W-Cat:407-412`) |
| Motion wakes screen (`DEV-23`) | self, door (`A-SM:122-124`) | MISS | n/a | MISS | MISS |
| Capability override (`DEV-26`) | MISS | MISS | MISS | MISS | MISS |
| Device volume call/sos/idle + inherit (`DEV-28/29`) | self (`A-SA:562-577`) | self; sliders write the cluster default while inheriting (`I-SC:424-447`) | self | self; "inherit" has no confirm (`K-S:541-576`) | self (`W-Cat:215-222`) |
| UI element overrides (`DEV-30/31`, `local.ui.elements`) | MISS | MISS | MISS | MISS | MISS |
| Global playback policy (`DEV-32`, `video_playback.global`) | MISS | MISS | MISS | MISS | OK, narrower timeout range (`W-Adm:495-579`) |
| Per-pair playback override (`DEV-33/34`) | MISS | MISS | MISS | MISS | MISS |
| Panel identities create/edit/rotate/revoke (`PAN-01..08`) | OK (`A-NS:1471-1616`) | PART: rotate/revoke single tap (`I-SVC:913-1207`) | not verified | OK (`K-P:1631-1833`) | OK (`W-Adm:593-831`) |
| Pairing: create, join, invite, deny, add-all, code, QR (`PAIR-01..14`) | OK in separate screens | OK in separate screen | no QR scan | separate screen (not read) | separate panel (not read) |
| Rebuild cluster (`PAIR-06`, `SYS-25`) | MISS | MISS | MISS | MISS | OK (`W-Adm:1164-1185`) |

### Calls

| Admin item | Android | iOS | tvOS | Kiosk | Windows |
|---|---|---|---|---|---|
| Call flow (`RULE-01`, `ui.call_flow`) | OK (`A-SM:168-170`) | OK (`I-SC:616-620`) | OK | OK (`K-S:808-812`) | OK (`W-Cat:299-301`) |
| Cluster call return (`RULE-02`, `call.indoor.return_s`) | OK (`A-SM:175-176`) | MISS (offers `ui.call_ttl_s` instead, `I-SC:621-624`) | MISS | MISS (`ui.call_ttl_s`, `K-S:814`) | MISS |
| Rule list add / delete / enable (`RULE-03..06`) | OK (`A-NS:917-928`) | PART: delete no confirm (`I-SC:1520-1542`) | add only | OK (`K-P:813-860`) | OK, no toggle on row (`W-Ed:432-464`) |
| Trigger type and doors (`RULE-07/08`) | OK | OK | OK | OK | OK |
| Trigger devices for device_offline (`RULE-09`) | OK (`A-NS:1009-1014`) | MISS | MISS | MISS | OK (`W-Ed:480-485`) |
| Schedule and windows (`RULE-10/11`) | PART: times typed as text (`A-NS:1083-1102`) | OK | OK | OK | PART: times typed as text |
| Actions list and type (`RULE-12/13`) | OK | OK, with reorder | add only | OK | OK, with reorder |
| sip_call, telegram actions (`RULE-14..16`) | OK | OK | OK | OK | OK |
| Chime target devices (`RULE-17`) | OK (`A-NS:1136-1157`) | MISS | MISS | MISS | OK (`W-Ed:652-656`) |
| Chime sound (`RULE-18`) | OK | OK | OK | OK | OK |
| device_alert targets devices / roles / web groups (`RULE-20`) | MISS (kept, not editable, `A-NS:1164-1180`) | PART: roles only (`I-SC:1758-1779`) | same | PART: roles only (`K-P:1110-1112`) | PART: roles + devices, no web groups (`W-Ed:673-684`) |
| device_alert channels, never suppress (`RULE-21/22`) | OK | OK | OK | OK | OK |
| device_alert visual / sticky / TTL (`RULE-23,26`) | MISS | OK | OK | OK | OK |
| device_alert sound (`RULE-24`) | MISS | MISS | MISS | OK (`K-P:1128-1137`) | OK |
| device_alert volume, colours (`RULE-25,27`) | MISS | MISS | MISS | MISS | OK (`W-Ed:698-706`) |
| SOS dry-run preview (`RULE-28`) | MISS | MISS | MISS | MISS | MISS |
| Quick replies add/edit/delete/reorder/speak (`QR-01..07`) | OK; delete from the edit dialog skips confirm and DTMF cleanup (`A-SA:1111`) | OK, delete no confirm (`I-SC:658-702`) | add only | OK (`K-P:471-532`) | OK (`W-Lst:25-135`) |
| Reply audio per language (`QR-05`) | OK (`A-NS:590-640`) | OK (`I-SC:694-702`) | OK | MISS | MISS |
| Speech / TTS provider, key, voices, rate, cache (`QR-08..14`) | MISS | MISS | MISS | MISS | MISS |
| Purposes add/edit/delete/reorder/enable (`PUR-01..06`) | OK, icon free text | OK, icon typed, delete no confirm | add only | OK, icon free text | OK, icon free text |
| Visitor languages (`PUR-07`, `ui.languages`) | OK (`A-SM:171-172`) | OK (`I-SC:631-640`) | no reorder | MISS | PART: can be emptied (`W-Cat:302-306`) |
| Language revert (`PUR-08`) | OK | OK | OK | OK | OK |
| Households label, chat ids, extensions (`HH-01..05`) | OK, delete no confirm (`A-NS:875-913`) | OK, delete no confirm, extensions unvalidated (`I-SC:1437-1466`) | add only | OK (`K-P:1241-1321`) | OK (`W-Ed:237-263`) |

### Appearance

| Admin item | Android | iOS | tvOS | Kiosk | Windows |
|---|---|---|---|---|---|
| Wording overrides (`TXT-01`) | OK; placeholder check counts only (`A-NS:497-585`) | OK, raw keys as titles (`I-SC:1314-1381`) | no search | OK (`K-P:2146-2235`) | OK, shows nothing until searched (`W-Adm:294-491`) |
| Theme scope cluster / per device (`TH-01`) | MISS (cluster only) | MISS | MISS | PART: cluster + this device (`K-P:2329-2346`) | MISS |
| Background colour (`TH-02`) | PART: hex text, no picker (`A-SA:554-558`) | PART: hex text (`I-SC:505-511`) | same | OK swatches (`K-P:2275-2279`) | OK (`W-Ed:899-957`) |
| Background image (`TH-03`) | OK (`A-NS:409-427`) | OK (`I-SC:512-514`, upload :1280) | pick only | PART: photo library upload only, cannot pick an existing asset (`K-P:2281-2292`) | OK (`W-Adm:244-290`) |
| Backdrop enabled (`TH-04`) | MISS | OK | OK | MISS | OK |
| Backdrop colour (`TH-05`) | MISS | PART: hex text | same | MISS | MISS |
| Backdrop opacity (`TH-06`) | OK | OK | OK | MISS | OK |
| Blur radius (`TH-07`) | OK | read-only "system" (matches Admin for iOS) | same | MISS | OK |
| Appearance (`TH-09`) | PART: self override only, cluster default not editable (`A-SA:535-553`) | PART: cluster only (`I-SC:481-484`) | same | PART: cluster only, `auto_system` not offered (`K-S:495-507`) | PART: cluster only (`W-Cat:260-263`) |
| Appearance schedule (`TH-10`) | MISS (shown read-only) | OK | OK | MISS | OK |
| Screensaver enabled / idle / brightness (`TH-11,15,16`) | OK, cluster only (`A-SM:155-159`) | OK | OK | OK (`K-S:787-802`) | WRONG KEY: writes `devices.{self}.local.screensaver_after_s`; Core reads `local.display.*` (`W-Cat:254-257` vs `node.cpp:4222-4234`) (checked) |
| Screensaver content mode (`TH-12`) | MISS | OK | OK | OK | MISS |
| Screensaver daily schedule (`TH-13/14`) | MISS | OK | OK | MISS | MISS |
| Call button colour (`TH-17`) | MISS | MISS | MISS | MISS | MISS |
| Ink per region, 7 regions (`TH-18`) | MISS | PART: 5 regions, hex text (`I-SC:1290-1310`) | same | PART: 5 regions (`K-P:2297-2317`) | MISS |
| Launch / door-call / button / update sound (`AS-01,02,04,06`) | PART: built-in or none, no custom asset (`A-SM:131-140`) | OK (`I-SC:454-461`) | OK | PART: button sound only (`K-S:770-772`) | OK (`W-Cat:234-243`) |
| Loop call sound (`AS-03`) | OK | OK | OK | OK | OK |
| Ringtone (`AS-05`) | OK (`A-NS:444-448`) | OK | OK | OK (`K-P:2489-2490`) | OK |
| Asset upload (`AS-07`) | PART: audio file or recording; images only as wallpaper | PART: same | MISS | PART: mic recording; photo on iPad only | OK (`W-Adm:74-108`) |
| Asset list with used-by, delete (`AS-08/09`) | PART: sounds only, no image list | PART: no used-by, delete no confirm | view only | PART: no used-by | OK |
| Asset preview / play (`AS-10`) | MISS | MISS | MISS | MISS | MISS |

### System

| Admin item | Android | iOS | tvOS | Kiosk | Windows |
|---|---|---|---|---|---|
| MQTT host/port/user/password (`INT-01..04`) | OK (`A-NS:1310-1318`) | OK, weak validation (`I-SC:1812-1826`) | OK | OK (`K-P:1530-1542`) | OK (`W-Cat:521-524`) |
| Telegram token, polling, test (`INT-06..08`) | OK | OK | test not verified | OK | OK |
| Web Push sender, VAPID, bearer (`INT-10..15`) | OK (`A-NS:1291-1305`) | MISS (status row only, `I-SC:991-992`) | MISS | MISS | MISS |
| Bridge / Web Push status (`DASH-02`, `INT-16`) | PART: MQTT status only | MISS | MISS | MISS | MISS |
| SIP server / port / transport (`INT-17..19`) | OK | PART: no `tls` option (`I-SC:1074-1078`) | MISS (category hidden) | OK | OK |
| SIP account per device (`INT-20/21`) | self | self | MISS | self | self |
| Legacy tz offset (`INT-23`) | MISS | MISS | MISS | MISS | MISS |
| Quiet-hours windows (`INT-24`) | PART: weekday edits lost or shifted (`A-NS:1202-1213`, `A-NM:185-198`) | OK | add only | OK | OK |
| Quiet-hours suppress / never suppress (`INT-25/26`) | OK | MISS | MISS | OK (`K-P:779-790`) | OK |
| Time zone (`SYS-01`) | PART: Android's own list, 60 shown | OK | no search | OK | PART: 9 fixed zones (`W-Cat:444-449`) |
| NTP enable / servers / interval / sync (`SYS-02..04,06`) | OK, servers as unchecked text | OK | OK | OK, no host check | PART: servers as raw CSV, 4 fixed intervals |
| Time status (`SYS-05`) | OK | OK | OK | PART | MISS |
| Admin password (`SYS-07`) | OK | PART: no repeat field (`I-SC:298-310`) | same | OK | OK |
| Cluster volume defaults (`SYS-08`, `audio.volume.*`) | MISS | PART: only while "inherit" is on | same | MISS (displayed only) | OK (`W-Cat:224-229`) |
| SOS trigger mode (`SYS-09`) | MISS | MISS | MISS | MISS | OK |
| SOS countdown, roles, cancel PIN, web alerts (`SYS-10..12,15`) | OK | OK | OK | OK | OK |
| SOS alarm sound (`SYS-13`) | OK | OK | OK | OK | OK |
| SOS alarm volume (`SYS-14`) | MISS | MISS | MISS | MISS | OK |
| Config export (`SYS-16`) | OK file | PART: clipboard only | inert row | PART: clipboard only | OK file |
| Config import with preview (`SYS-17..22`) | OK, summary shows counts only; needs loopback session | PART: clipboard only | inert row | PART: clipboard only | OK |
| Fingerprint / membership (`SYS-23`) | not verified | MISS | MISS | MISS | OK (`W-Cat:500`) |
| Rotate cluster key (`SYS-24`) | OK | OK | OK | OK | OK |
| Legacy panel token (`SYS-26..28`) | MISS | MISS | MISS | MISS | MISS |
| Raw config view / key write (`SYS-30/31`) | MISS | MISS | MISS | MISS | MISS |
| Logs (`SYS-32`) and event log (`EV-01/02`) | MISS | MISS | MISS | MISS | PART: opens the log folder; no event log |
| Partition-conflict review (`NAV-07`) | not found | not found | not found | not found | not found (none of the inventories lists one; not verified) |

## 2.2 Defects found while building the matrix (not just missing rows)

| # | shell | defect | where |
|---|---|---|---|
| 1 | Windows | Door station cannot open settings | `MainWindow.Shell.cs:50`, `MainWindow.Pairing.cs:117-124` (checked) |
| 2 | Windows | Never applies a remotely edited identity | `MainWindow.CallFlow.cs:328-331` |
| 3 | Windows | Brightness and screensaver write keys Core does not read | `W-Cat:252-257`, `node.cpp:4222-4234` (checked) |
| 4 | Windows | SIP answer mode offers "manual"; Core knows `auto` / `ring` | `W-Cat:431-433`, `node.cpp:5244-5247` (checked) |
| 5 | Android | Video playback offers values Core ignores | `A-SM:143-144` (checked) |
| 6 | Android | Quiet-hours weekday filter dropped / shifted on edit or delete | `A-NS:1202-1213`, `A-NM:185-198` |
| 7 | iOS | Role change neither restarts nor shows the door field on first try | `I-SVC:251-264` (checked) |
| 8 | iOS | Name edited on the device page goes to boot.json only; the same name under Cluster > Devices restarts the app | `I-SC:228-234` vs `:1481-1486` |
| 9 | tvOS | Export, import and "device info" rows are shown but do nothing | `I-SVC:394-396,507-526` |
| 10 | Kiosk | Top-level writes are not retried after the PIN when Core answers `admin_required`; shown as "save failed" | `K-S:1194-1199` vs `K-P:133-173` |
| 11 | Kiosk | UI language and helper mode go to boot.json instead of the replicated keys Admin edits | `K-S:484-494` |
| 12 | all | Secrets are stored only in the entering device's secure store (Admin has the same per-node limitation, with a "provision this node" action) | `A-NS:190-236`, `I-SVC:533-559`, `K-P:200-216`, `W-Ed:134-186` |

## 2.3 Native-only settings (Admin lacks them)

| setting (key) | shells |
|---|---|
| Brightness and night mode (`display.brightness`, `display.night.*`), pixel shift (`display.pixel_shift_s`) | Android, iOS/tvOS, kiosk (no pixel shift), Windows |
| Reply display time (`reply.display_ttl_s`) | all four |
| Call timeout `ui.call_ttl_s`, history retention `events.retention_days` | iOS/tvOS, kiosk |
| External cameras (`media_sources.*` + credentials) | all four |
| SIP direct port, answer mode, DTMF actions (`sip.direct_port`, `sip.accounts.<self>.answer_mode`, `sip.dtmf_actions`) | Android, iOS, kiosk, Windows |
| SRTP (`sip.srtp`) | iOS, kiosk, Windows |
| MQTT TLS, pin, base topic, discovery prefix; Home Assistant language and control switches (`integrations.mqtt.*`, `integrations.ha.*`) | all four |
| Telegram message template (`integrations.telegram.text_template`) | Android, Windows (ja only) |
| Browser WebRTC account (`integrations.webrtc.*`) | Android |
| SOS SIP call (`emergency.sip_call.*`; no Core reader found by grep, not verified) | iOS/tvOS, Windows |
| Rule extras: name, trigger `call_missed`, condition `when.purposes`, actions `auto_reply` / `ha_command` | Android, iOS, kiosk, Windows (varies) |
| Leave cluster / factory reset | Android (`A-SA:719-722`) |
| Kiosk mode, exit kiosk, restart app, software update, video stats overlay, dashboard preview rate | shell-local, various |

## 2.4 Tests that claim parity

| test | what it really checks | what it misses |
|---|---|---|
| `ios-compat/tests/native_settings_contract_test.py` ("no web-only rows", lines 131-150) | Reads only the Swift shell. About 16 key strings must appear in the settings sources, and five `settings.web_only_*` i18n ids must not. | Never opens `ios-kiosk` or `webui/admin/app.js`. Any missing editor passes. It currently cannot run to the end: line 110 reads `ios/Doorbell/SettingsForm.swift`, which is deleted in the working tree (checked) |
| `ios/DoorbellTests/SettingsCatalogTests.swift` `testFormerlyWebOnlyItemsAreNative` (:163-177) | Three items: panels is a shell action, rule editor is a list, SIP password is a secret field | Everything else |
| `ios-compat/tests/pairing_flow_contract_test.py:125-158` | `DBSettingsScreen.m` writes through the Core ABI and does not contain `api/config` / `api/login` | `DBSettingsPages.m` and `DBEditor.m` have no test at all |
| `win/tests/test_windows_contracts.py` `test_every_admin_setting_is_native` (:1037-1125) | Substring checks on C# source: 19 handler names exist, no `WebOnly` / `OpenWebAdmin` strings, some API literals | Never reads the Admin or the schema, so door unlock, screensaver object, Web Push, speech, per-device scope, logs all pass |
| same file, `test_native_settings_cover_device_config_and_write_through_the_batch` (:783-844) | 15 key literals present, batch write used | Pins the wrong key `Local + ".screen_brightness"` |
| Android `SettingsSearchTest` | Substring search and category ordering only | Nothing about Admin |
| Android `SettingsModelTest`, `NativeSettingsModelTest` | Encoders, ranges, validators, batch document shape | No comparison with Admin; the "same keys as the web admin" statements are comments |

No test on any platform compares a native catalogue with `webui/admin/app.js` or `docs/en/config-schema.md`. A real parity test would need a shared machine-readable list of setting keys.

## 2.5 Prioritised to-do per platform

### Android

1. Fix `local.video.playback` options to `low_latency` / `hls` / `mjpeg`, and add `auto` to rotation (`A-SM:143-147`).
2. Fix the quiet-hours weekday loss (`A-NS:1202-1213`, `A-NM:185-198`).
3. Role: replace the three rows that silently open first-run setup with the "Change role" form from 1.5 (door picker, confirmation, cancel); add role to the Devices list editor for other devices (`A-NS:1418-1467`).
4. Add per-device door-station settings: camera codec / resolution / fps / quality / bitrate / device hint, motion enable / sensitivity / interval, visitor layout (`DEV-13..25`).
5. Let launch / door-call / button / update sounds use custom assets (`A-SM:131-140`); add an image asset list with delete.
6. device_alert action: targets, visual / sticky / TTL, sound, volume, colours (`A-NS:1164-1180`).
7. Theme: colour picker instead of hex text, backdrop enabled + colour, appearance cluster default and schedule, screensaver mode and schedule, call-button colour, ink overrides.
8. Add cluster volume defaults, SOS trigger mode and alarm volume.
9. Add confirmations: building, household, notice preset, media source, DTMF, secret deletes; quick-reply delete from the edit dialog (also run its DTMF cleanup, `A-SA:1111`).
10. Missing areas: speech/TTS, playback policy, rebuild cluster, logs / event log.

### iOS / iPadOS

1. Role: implement 1.5. Minimum: after `persistSetup`, update `AppDelegate.boot` and call the existing identity restart; show the door field immediately when door station is selected (`I-SVC:251-264`); confirmation.
2. Add confirmations for remove device, every list delete, Telegram disable, wording reset, panel revoke / rotate (`I-SUI:1220-1225`, `I-SC:1497-1501`).
3. Rules: trigger devices for `device_offline`, chime target devices, device_alert devices / web groups / sound / volume / colours.
4. Quiet hours: suppress and never-suppress lists (`I-SC:976-978`).
5. Web Push editor (`I-SC:991-992`).
6. Cluster call return `call.indoor.return_s`, per-device call return, motion wakes screen, camera device hint.
7. Explicit cluster volume defaults instead of the "writes cluster while inheriting" behaviour (`I-SC:433-447`); SOS trigger mode and alarm volume.
8. Unlock: three-state mode and command binding (`I-SC:792-796`).
9. Colour picker for all hex fields; call-button colour; ink regions footer and notice; SIP `tls` transport; password repeat field.
10. Export / import to a file (share sheet) instead of the clipboard; role editor for other devices; speech/TTS, playback policy, rebuild, logs.

### tvOS

1. Make list delete / reorder and row switches reachable with the remote (`I-SUI:1114-1117,1228`).
2. Remove or implement the inert rows: export, import, device info (`I-SVC:394-396,507-526`).
3. Show the role read-only with a reason; confirm that a replicated `door_station` is refused (not verified).
4. Search for the time-zone and wording lists.

### iOS 5 kiosk

1. Role: add the "Change role" form (1.5) in the Device category, and make the role editable in Cluster > Devices; replace the misleading footer `editor.role_on_device` (`K-S:481`, `K-P:2100-2113`). Add a restart confirmation to the device door choice (`K-P:2105-2110`).
2. Retry top-level writes after the PIN on `admin_required` (`K-S:1194-1199`).
3. Write UI language and helper mode to the replicated keys (`devices.<self>.local.ui_lang`, `.local.recovery.helper_mode`) as well as boot.json (`K-S:484-494`).
4. Add visitor languages (`ui.languages`), launch / door-call / update sounds, cluster call return.
5. Add camera, motion and visitor-layout settings for a door station.
6. Reply audio per language; unlock mode and command; rule trigger devices and chime target devices.
7. Theme: pick an existing image asset, backdrop settings, blur, appearance `auto_system` and schedule, screensaver schedule.
8. Web Push, cluster volume defaults, SOS trigger mode and alarm volume.
9. A single assets page (list, used-by, delete); file-based export / import if feasible on iOS 5.
10. Move the hard-coded English titles ("Telegram", "SIP", "TLS", "SRTP", "ID", stream titles) into `i18n/strings.yaml` (`K-S:697,701`; `K-P:1371,1534,1918-1920,2111`), as AGENTS.md requires.

### Windows

1. Give a door station a route to settings (hidden corner + password should open settings), otherwise role, door, camera and motion rows are unusable (`MainWindow.Pairing.cs:117-124`).
2. Apply replicated identity (`devices.<self>.name/.role/.door`) like the other shells; persist boot.json before committing config in `WriteIdentity`; replace the silent random door with the door picker; confirm remote role edits in `EditPeer` (`W-Act:240-266`, `W-Ed:836-874`).
3. Fix keys: brightness and screensaver to `devices.{self}.local.display.*` or the `display.screensaver` object (`W-Cat:252-257`); answer mode `ring` instead of `manual` (`W-Cat:431-433`). Update the contract test that pins `screen_brightness`.
4. Door unlock mode and command (`doors.<id>.unlock`).
5. Screensaver object (enabled, mode, schedule, brightness), cluster and per-device call return, Web Push.
6. Time zone: full list instead of 9; NTP servers as a validated list; time sync status.
7. Reply audio per language; label fields for all enabled visitor languages, not only ja/en/zh (`W-Lst:302`).
8. Guards: do not allow an empty `ui.languages`; notice presets max 8; confirmations for volume reset, wording reset, background clear.
9. Theme: backdrop colour, call-button colour, ink overrides, per-device appearance.
10. Per-pair playback overrides, speech/TTS, in-app log and event viewer.

### All shells (shared work)

- A device picker so per-device settings can be edited for other devices, as Admin does.
- Nothing native exists for: capability override, UI element overrides, call-button colour, speech/TTS, per-pair playback, asset preview, raw config, SOS dry-run.
- A shared, machine-readable settings catalogue to drive a real parity test (2.4).
