# Native UI redesign: handoff (state after the 2026-11-15 integration)

This file describes `main` after the air-quality work, the Core/CI fixes, the
per-platform fixes and the kiosk settings audit were brought together. Verification is
stated per deliverable; anything under "Not verified" is untested, not passing.

Related documents:

- `docs/en/ui-guidelines.md`: the design spec (principles, home composition, SOS flow,
  video stage and zoom, colour roles, icon policy, per-platform control tables).
- `docs/en/native-settings-parity-audit.md`: web Admin versus native settings, per
  shell, with the role-switch design (snapshot from 2026-11-12; line numbers are
  stale).
- `docs/en/visitor-flow-design.md` and `docs/en/visitor-flow-contract.md`: the
  door-station wizard ("visitor flow") design, the owner's decisions, and the
  contract shells implement against.
- `docs/en/air-quality-sensors.md` (with ja and zh translations): the PM2.5 sensor
  design.

## Owner decisions that shape the work

- Each shell follows its platform's official design with stock controls; shells are
  not meant to look alike. Material Components on Android API 21+, framework Holo
  widgets on API 19, ModernWpf on Windows, stock UIKit left to the system on the iOS 5
  kiosk (no UIAppearance restyling).
- Icons: each platform uses its own native open set (see "Icon policy" below); never
  hand-drawn. Missing icons and widely used dependencies may be downloaded without
  asking.
- Home shows no call history; History is its own destination with a missed-call
  badge and one notice on Home.
- SOS: compact outlined trigger, tap opens a confirmation, slide there to confirm,
  then the existing countdown. No press-and-hold anywhere.
- Live video: the stage takes all remaining space, the picture is aspect-fitted, zoom
  1x to 4x with the stage (not the fitted picture) as the clip rectangle.
- Role colours used as text or outline must reach 4.5:1 in both appearances.
- App accent: only an administrator-chosen call-button colour becomes the accent;
  Core's automatically computed accent does not.
- Role switching and full parity with web Admin in every native settings UI.
- Config writes shared between Admin and shells are leaves (Core lets a leaf mask a
  parent object member regardless of age; see
  `core/tests/test_config_leaf_masking.cpp`). The Core merge rule itself is
  unchanged; changing it needs a decision because mixed-version clusters would
  materialise different configs.
- Visitor flow: wizard enabled on upgrade; "must reach a call" is the administrator
  setting `visitor_flow.require_call`; the okihai snapshot comes from an external
  camera, not the door camera; full native flow editors on every platform including
  the kiosk.

## Icon policy as implemented

Per-platform native sets, `tools/gen_icons.py` generates the raster and vector assets,
and `tools/check_icons.py` rejects hand-drawn icons.

- Kiosk and iOS 9 to 12: Framework7 Icons (MIT), shared manifest in
  `assets/icons/framework7/`. Seen on devices (kiosk).
- iOS 13+ and tvOS: SF Symbols with bundled Framework7 fallback imagesets
  (`F7*.imageset`) behind `AppIcon`. The `door` fallback is a lock and `videoOff` is
  `eye_slash_fill` for lack of a match. Simulator builds only.
- Android: Material Symbols (`ic_ms_*.xml`).
- Windows: Fluent UI System Icons as filled geometries (`assets/icons/fluent/`),
  including the sales, utility and other purposes. Host checks only; never rendered.
- Web: the vendored Tabler set.

## State per deliverable

### Windows (0.2.1, file version 0.2.1.27)

Done: Fluent redesign, NavigationView home, settings parity list emptied, SOS flow,
zoom host, conversation fixes, Fluent icons, stepper chevrons sized, a read-only
air-quality indicator (`MainWindow.AirQuality.cs`, no Bluetooth hosting).

Verified: `win/tests/test_windows_contracts.py` and `win/scripts/typecheck_host.py` on
this integration. Remote run on the Windows test PC: the suite was green on CI run
43709454544 (before the air-quality merge and the rule-label change).

Not verified: nothing after that run was compiled on Windows or rendered. Open items from
the remote run: the Answer button has low contrast in the test state, navigation and
dialog title text is small, and the light-theme screenshots were never viewed. The
air-quality indicator and the Fluent icon sizing in Viewbox/PathIcon are unseen.

Next: push, wait for `windows-contract`, run `win/scripts/run_remote_tests.sh
10.10.38.43 nagato`, open every screenshot including light theme, and fix the three open
items. Suspect first if something misbehaves: `Fluent.DimOwnerWhileOpen`, the settings
content width binding in `SettingsWindow.BuildShell`, `BuildStepper`. ContentDialog and
Flyout are intentionally unused (synchronous modal flows). The Windows shell has no
trigger-rule list, so the rule-label change does not apply there. The test PC keeps one
permanent firewall rule (`DoorbellTest SSH (LAN)`), OpenSSH Server, the task
`DoorbellTest-RunJob` and `C:\DoorbellTest`; `setup_test_host.ps1 -Uninstall` reverts
them. The session there is Remote Desktop: UI tests need it connected.

### Android (0.5.3, build 50)

Done: Material 3 (modern) and framework widgets (legacy19) through per-flavor
`PlatformUi`/`ShellActivity`; home without history; SOS flow; zoom (recentred offset
fixed: a clamped `-0f` no longer differs from `ZoomState()`); role change; quiet-hours,
playback and secure-store bridge-order fixes; camera close race fix; null-safe household
extensions; about half of the settings parity list; accent and role-text rules; video
stage rule with H.264 aspect fit; Material Symbols; PM2.5 indicator, model and BLE
host (`AirQuality*.kt`, `AirSensor*.kt`, unverified); readable rule titles.

Verified on this integration: modern lane `assembleModernDebug` and
`testModernDebugUnitTest` (see the final check summary in the integration report).

Not verified: the legacy19 lane after the air-quality merge (it was not rerun here);
instrumentation case T35-06 was never compiled or run; in-call was never reached on the
emulator; legacy19 never ran anywhere; door-to-indoor role change never ran end to end;
the air-quality BLE host never ran against a sensor.

Next: re-check the call screen with real video at 1x and zoomed; role change end to end;
walk legacy19; finish parity (custom sound assets and asset list, device_alert details,
speech, playback policy, logs, capability override, other devices' local settings,
delete confirmations) until `KNOWN_GAPS` and `DYNAMIC_GAPS` in
`tools/tests/test_android_settings_parity.py` are empty.

### iOS and tvOS (iOS 0.6.3, build 76; tvOS 0.5.4, build 26)

Done: tab bar home, collection view tiles, table-based history and editors, alert admin
prompt, call action zone, SOS flow, zoom, role change (`RoleChangeController.swift`), a
first group of settings, UI gesture tests target, SF Symbols with Framework7 fallbacks.
Fixed since 0.5.1: tvOS Home header and nav title, SOS overlap, `sos_active` hook,
accessibility-size incoming QR and History columns, tvOS "answered by" names,
`storeMediaSecret` writes the leaf, DoorbellIOS9 availability. New: PM2.5 view and
Bluetooth host (`AirQualityView.swift`, `AirSensorHost.swift`, usage descriptions in
`Info.plist`), readable rule titles and the visitor-message trigger label.

Verified: host-side checks only (string generation, icon checks, English-source check,
`ios-compat` host tests, conformance). `xcodebuild` was not run on this integration: the
air-quality and rule-label Swift edits are covered only by review.

Not verified: no iOS or tvOS build of the merged tree; the role change was never exercised
live; the SOS overlap with a door tile and the accessibility-size layouts were never seen
(no door in the simulator cluster, no tvOS gesture); the DoorbellIOS9 target was not built
after the icon change.

Next: run the five-target build and checks, then the remaining parity (rules extras,
quiet-hours suppress lists, unlock binding, colour picker, SIP TLS, cluster volume
defaults, other devices' roles, speech, playback policy, raw config, logs, capability and
UI-element overrides, tvOS search). `ios-compat/tests/modern_settings_parity_test.py`
exists but is not wired into `test_host.sh`.

### iOS 5 kiosk (0.8.4, build 98; iOS 9 profile 0.7.4, build 421)

Done and seen on devices: stock UIKit redesign, home without history, SOS panel, role
change, full settings parity, admin retry on writes, video stage rule, Framework7 icons
throughout, door-station home recomposed, Settings category tiles and QR section, indoor
home spacing, microphone request and TCC entitlements, talk toggle in live view, call
diagnostics trace. Settings audit (0.8.3): QR only on the device-information page,
bitmaps at screen scale, controls rebound instead of reallocated, row layouts cached per
width. PM2.5 air-quality section in settings and the air strings are in the generated
`DBGeneratedStrings.m`, now produced from `i18n/strings.yaml`. Rule rows without a name
show the localized trigger label.

Verified: `ios-kiosk/scripts/build_app.sh` builds the merged tree (armv7, iOS 5.1 target,
zero unresolved symbols); `ios-compat` host tests pass. Earlier versions were installed on
the iPad 1 (0.7.1) and the three iPad mini 1 devices (0.7.2, `"mic":true`; the previous app
and boot.json are at `/var/tmp/Doorbell.app.pre-redesign` and
`/var/tmp/boot.json.pre-redesign` on each).

Not verified: 0.8.4 was not installed anywhere; portrait and iPad 1 screenshots, the
calling/connected/reply states on a device, a sweep of every settings sub-page, gestures
(pinch, pan, SOS slide), rotated door stations, H.264 under zoom and the role change
restart. The microphone fix has not been confirmed in a real call. The iOS 9 armv7 lane
was only syntax-checked (no iOS 9 SDK on the build Mac).

Known defects: the door-station home has been seen on the indoor mini in landscape only;
phone landscapes under 500 pt still use the old two-column layout; the clock text is hard
to read over a bright wallpaper; the bottom caption can clip.

Next: install 0.8.4 on the iPad 1 and one mini, review portrait and the remaining states,
fix the defects above.

### Web panel and Admin (ship inside Core)

Done: redesigned door, monitor and call pages; Admin console; SOS flow with countdown;
zoom with stage clipping and rotation; panel state fields `display`, `doors[].online`,
`doors[].unlock`, `emergency.trigger.countdown_s`; Admin writes leaves; contrast tests;
air-quality admin section; the rules list shows a localized trigger label (or the rule
name) instead of the raw id for seeded `r_*_default` rules, and the unknown-trigger label
instead of "Button press" for triggers it does not list.

Verified: `webui/tests/*.test.js` pass. Not verified: iOS 5 Safari, a real H.264 stream,
rotation against a real rotated station, SOS send on a single preview node reported
"preparation could not be confirmed" (cause not investigated).

### Core

Visitor flow: in the tree and partly implemented. `core/src/node/visitor_flow.{h,cpp}`,
`visitor_flow_service.inc`, node hooks and routes, the `visitor_message` event with
Telegram, HA and device_alert mappings, three additive exports
(`db_core_visitor_flow_json`, `db_core_visitor_flow_template_json`,
`db_core_visitor_notify_json`), a seeded `r_visitor_message_default` rule, conformance
fixture and reference walker, `core/tests/test_visitor_flow.cpp`. Native shells stay on the
classic visitor screen until they advertise `visitor_flow_v1`.

Air quality: `core/src/sensors/mops_vida.{h,cpp}`, `core/src/node/air_quality_service.inc`
and `core/tests/test_air_quality.cpp`, with the `air_quality_changed` event and the
`db_core_air_quality_json` export. Unverified WIP on hardware: no real MOPS VIDA sensor was
used.

Verified on this integration: Core build and the full `doorbell_tests` suite, Python tool
tests, the conformance runner (visitor flow and event conformance). See the integration
report for the exact results.

Remaining for Core: node-level visitor-flow tests (notify, rate limit, idempotency,
old-shell gating, fake camera fetcher, per-step CRDT merge, batch rejection, bridge
mappings); confirm and pin what an older Core does with an unknown top-level key (reading
so far: accepted and merged, unconfirmed); API docs (`docs/en/operation-api.md`,
`webui/panel/API.md`, `webui/admin/API.md` and translations); add the exports to
`win/abi-probe`. Snapshot limits: only `media_sources.<id>.streams.snapshot.url` is
supported (no ONVIF discovery, no RTSP still); snapshots are served from the public
`/asset/<sha256>` route for about seven days, which deserves a security review before
release.

### Visitor flow status

Core contract implemented (above). Native shells and the web `door.html` renderer do not
render the wizard yet; the Admin flow editor and simulator are not written; no shell
advertises `visitor_flow_v1`. Remaining work packages are design section 3, WP2 to WP8.

### PM2.5 air-quality sensors (unverified WIP)

Committed from another session's working tree at the owner's request and merged with the
icon changes: Core service and MOPS VIDA driver, Android and iOS Bluetooth hosts and
indicators, a Windows read-only indicator, kiosk settings and strings, web Admin section,
`docs/*/air-quality-sensors.md`. The air strings are now in `i18n/strings.yaml`. No
hardware test was run and the shells that host Bluetooth were not exercised. Treat the
feature as unreleased until a sensor is paired on each hosting platform.

## Repository-wide notes

- `feature-parity.json` was updated with the air-quality feature; the wiki was not.
- `docs/en/ui-guidelines.md`, this file and the visitor-flow and parity documents have no
  ja/zh translations.
- The checkpoint commit `a85b088` (concurrent incoming calls and conversations) was
  never built as a whole before the redesign went on top of it.
- Rules without a title now show a readable label in Android, iOS, kiosk and web Admin;
  the Windows shell has no rule list.
