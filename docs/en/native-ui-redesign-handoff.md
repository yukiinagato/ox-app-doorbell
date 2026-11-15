# Native UI redesign: handoff (state after the fourth integration)

This file describes `main` after the air-quality work, the Core/CI fixes, the
per-platform fixes and the kiosk settings audit were brought together, the second
integration (the Core visitor-flow completion, the full-screen quick-reply overlay on
every shell, the language-switch and settings responsiveness work), and the third
integration: the visitor flow implemented on Core, the web door page, Admin, the kiosk,
<<<<<<< HEAD
iOS and tvOS, Android and Windows. The fourth integration adds the per-shell polish of that
flow (step ordering, option icons, preview, start-page composition, no classic-screen flash)
on every shell and the web Admin. Current versions: Windows 0.4.0 (file version
0.4.0.33), Android 0.6.1 (55), iOS 0.7.1 (81), tvOS 0.6.1 (31), iOS 5 kiosk 0.9.1 (102)
with the iOS 9 profile 0.8.1 (425). Verification is stated per deliverable; anything
=======
iOS and tvOS, Android and Windows. Current versions: Windows 0.3.1 (file version
0.3.1.32), Android 0.6.0 (54), iOS 0.7.2 (82), tvOS 0.6.3 (33), iOS 5 kiosk 0.9.0 (101)
with the iOS 9 profile 0.8.0 (424). Verification is stated per deliverable; anything
>>>>>>> d6d95a3d (tvOS: screenshot request hook (home/history/settings/monitor/notice/sos/sos_active) behind debug_screenshots; tvOS 0.6.2 (32))
under "Not verified" is untested, not passing.

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
- Web: the vendored Tabler set. `tools/gen_icons.py` skips Tabler's invisible
  `stroke="none"` background path; existing sprite symbols are unchanged.

## State per deliverable

### Windows (0.4.0, file version 0.4.0.33)

Polish (0.4.0): the flow editor lists steps by Core's `order` and moves them with buttons
(consecutive `order` values, changed steps written whole); options draw vendored Fluent icons
(`FlowIcons.cs`) from the purpose id or the mapped emoji, with an icon picker; the caption line
sits at the bottom edge with a small clock; the editor has a preview that walks the flow without
sending; option-level Core errors show under the option; no classic screen shows before the first
flow answer. Verified on the host only: `win/scripts/test_flow_editor_model.sh`,
`test_visitor_flow.sh`, the other `win/scripts/test_*.sh`, `win/tests/test_windows_contracts.py`
and `typecheck_host.py`. The polish has not been compiled on Windows or seen on a PC.

Visitor flow (0.3.0): the door-station start page and wizard renderer (model, start-page
renderer) and the full flow editor, with a UI suite and a debug sample document. The sample
and `win/scripts/ui_smoke.ps1` follow the purposes-only default start page (no `o_call`).
Verified: `win/scripts/test_visitor_flow.sh` (19 documents, 21 walks), the other
`win/scripts/test_*.sh`, `win/tests/test_windows_contracts.py` and `typecheck_host.py`.
Not verified: the Windows app was never compiled or run, so the flow renderer, the editor
and the UI suite have not been seen.

Earlier work: Fluent redesign, NavigationView home, settings parity list emptied, SOS flow,
zoom host, conversation fixes, Fluent icons, stepper chevrons sized, a read-only
air-quality indicator (`MainWindow.AirQuality.cs`, no Bluetooth hosting). Quick-reply
overlay (`ReplyFit.cs`, `ReplyDismissGuard.cs`). Settings responsiveness: writes go
through one ordered lane (`WriteLane.cs`), steppers and search are debounced, Core is read
per render. The responsiveness change is unmeasured.

Verified: `win/tests/test_windows_contracts.py` and `win/scripts/typecheck_host.py` on
this integration. Remote run on the Windows test PC: the suite was green on CI run
43709454544 (before the air-quality merge and the rule-label change).

Not verified: Windows was not run for this integration (host contract and type checks
only); nothing after that run was compiled on Windows or rendered, including the reply
overlay and the write lane. Open items from
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

### Android (0.6.1, build 55)

Visitor flow (0.6.0, polished in 0.6.1): the flow wizard on the door station and a native
flow editor (`VisitorFlowEditor.kt`, `VisitorFlowEditModel.kt`). 0.6.1: options show vendored
Material Symbols (`FlowIcons.kt`: known emoji or the purpose id map to home, package, mail,
briefcase, wrench, ellipsis, person; the editor offers a picker that stores the emoji every
shell understands); Core's call-button colour is only used for a primary option that leads to
a call; the clock is a small secondary element in the top row beside the language switch; the
version caption is the bottom line of the screen; no classic controls show before Core has
said whether a flow exists; the editor lists steps in Core's `step_order`, moves a step up or
down from its menu (consecutive `order` values, only changed steps rewritten as whole steps in
one batch; duplicates land after the original; new steps take the next order) and has a
preview (`FlowPreview.kt`, same walker and page renderer, terminal actions only described);
the asset toast no longer shows a raw `%1$s`. Verified: modern and legacy19 `assemble`, unit
tests and lint, emulator screenshots (see the report of this change). Unverified: legacy19 on
a device, drag reordering (the menu is the only control), notify and call against a live
cluster on the new layout. Parity scan in `tools/tests/test_android_settings_parity.py`
includes the editor sources.

Earlier work: Material 3 (modern) and framework widgets (legacy19) through per-flavor
`PlatformUi`/`ShellActivity`; home without history; SOS flow; zoom (recentred offset
fixed: a clamped `-0f` no longer differs from `ZoomState()`); role change; quiet-hours,
playback and secure-store bridge-order fixes; camera close race fix; null-safe household
extensions; about half of the settings parity list; accent and role-text rules; video
stage rule with H.264 aspect fit; Material Symbols; PM2.5 indicator, model and BLE
host (`AirQuality*.kt`, `AirSensor*.kt`, unverified); readable rule titles. Quick-reply overlay (`ReplyFit.kt`, corner countdown, exit hint,
guarded dismissal). Settings responsiveness (`SettingsRefresh.kt`): Core reads off the main
thread, ordered writes, coalesced reloads that rebuild only on change, secure-store
presence cached per snapshot; unmeasured.

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

### iOS and tvOS (iOS 0.7.2, build 82; tvOS 0.6.3, build 33)

Visitor flow: the wizard on the door-station home (`VisitorFlowView.swift`,
`VisitorFlowPages.swift`) and a full flow editor in Settings (`VisitorFlowEditor.swift`);
the UI manifest is published again when Core starts after the supervisor so a fresh node
gets the wizard. Verified on this integration: the Doorbell scheme builds for the iOS
simulator (arm64, deployment target 14.0), DoorbellTests pass (271 tests) on an iPhone
simulator, DoorbellIOS9 builds (device, unsigned) and DoorbellTV builds (tvOS simulator).
Polish round (0.7.1): steps listed in Core `step_order` with the stock reorder control
(consecutive `order` writes, new step at the end, duplicate right after the original);
option icons mapped from purpose id or emoji to SF Symbols (unknown = person) with an icon
picker in the editor; start page composed as one centred block (equal cards, two columns, three
when wide), small clock beside the language switch, caption at the bottom edge; "Try it" preview
that walks the live document and reports the call or message that would run; no classic-screen
flash before the first flow answer. Fixed: `.local` settings actions never ran when no completion
handler was passed (the template, reset and preview rows). Verified on an isolated single-node
simulator: XCUITest taps (option, Back, notify path to the end page, Done; iPhone and iPad),
a page with a registered test image, a reorder and an invalid editor save (Core `bad_text` shown under
the field). Not verified: real devices; the notify takes about 4 s with no pending indicator.
`ios-compat/tests/modern_settings_parity_test.py` now scans the flow editor sources and
ignores message ids; it is still not wired into `test_host.sh`.

Earlier work: tab bar home, collection view tiles, table-based history and editors, alert admin
prompt, call action zone, SOS flow, zoom, role change (`RoleChangeController.swift`), a
first group of settings, UI gesture tests target, SF Symbols with Framework7 fallbacks.
Fixed since 0.5.1: tvOS Home header and nav title, SOS overlap, `sos_active` hook,
accessibility-size incoming QR and History columns, tvOS "answered by" names,
`storeMediaSecret` writes the leaf, DoorbellIOS9 availability. New: PM2.5 view and
Bluetooth host (`AirQualityView.swift`, `AirSensorHost.swift`, usage descriptions in
`Info.plist`), readable rule titles and the visitor-message trigger label. Since 0.6.3: quick-reply
overlay (`ReplyFit.swift`), language control styled to its own radius, language switch
applied on the tap and coalesced (`LangSwitch.swift`), settings change events coalesced
into one off-main snapshot read with row-level updates and off-main config writes
(`SettingsPerf.swift`). Measured in the simulator: 10 change events went from 170-200 ms
to 0.017 ms. No device measurement.

Not verified: the role change was never exercised
live; the SOS overlap with a door tile and the accessibility-size layouts were never seen
(no door in the simulator cluster, no tvOS gesture).

Next: tap through the flow and the editor against a live Core, then the remaining parity (rules extras,
quiet-hours suppress lists, unlock binding, colour picker, SIP TLS, cluster volume
defaults, other devices' roles, speech, playback policy, raw config, logs, capability and
UI-element overrides, tvOS search).

### iOS 5 kiosk (0.9.1, build 102; iOS 9 profile 0.8.1, build 425)

Polish (0.9.1): the flow editor lists steps in Core's `step_order` and reorders them with the
stock table reorder control (`DBFlowOrder`: consecutive `order` values, changed steps rewritten
whole in one batch; a new step takes the next order, a duplicate follows its original; the step
kind stays fixed and the step page says why). Options draw one vendored icon above the label (the
bound purpose's, otherwise the configured emoji mapped by `DBPurposeModel`; an emoji is never
drawn) and the editor's icon field is a picker. A page without a primary option centres the card and
the three-column grid as one block. The door screen shows neither classic call button nor purposes
until Core has answered the first flow request. The editor has a "Try it" page that walks the stored
flow with `DBVisitorFlowModel` and names the Core call a tap would make without making it.

Visitor flow (0.9.0): the wizard on the door screen (`DBVisitorFlowModel`, `DBDoorScreen`),
a flow model with a host test that reads the conformance fixture, and a full flow editor
in settings (`DBFlowEditorPages`). The app links the visitor-flow Core exports. Seen on the
iPad mini and the iPad 1 through static debug screenshots only: no taps were made.
Verified: `ios-compat/scripts/test_host.sh`; `ios-kiosk/scripts/build_app.sh` builds the
merged tree (armv7, iOS 5.1 target, zero unresolved symbols) and the binary contains the
visitor-flow Core code and strings. Settings parity scans include the flow editor sources.

Done and seen on devices (0.8.6 and earlier): stock UIKit redesign, home without history, SOS panel, role
change, full settings parity, admin retry on writes, video stage rule, Framework7 icons
throughout, door-station home recomposed, Settings category tiles and QR section, indoor
home spacing, microphone request and TCC entitlements, talk toggle in live view, call
diagnostics trace. Settings audit (0.8.3): QR only on the device-information page,
bitmaps at screen scale, controls rebound instead of reallocated, row layouts cached per
width. PM2.5 air-quality section in settings and the air strings are in the generated
`DBGeneratedStrings.m`, now produced from `i18n/strings.yaml`. Rule rows without a name
show the localized trigger label. Since 0.8.4: full-screen fitted quick reply with
countdown and guarded two-step close, End-button guard after an answer, language switch
relabelling in place with a debounced Core write, lazy category rows with diffed table
refresh and asynchronous optimistic control writes (0.8.6). Measured on the iPad mini: the
language switch went from about 480 ms to about 70 ms, the settings rebuild from 200 ms to
9 ms, and the first control write from 506 ms to under 1 ms.

Earlier verification: `ios-compat` host tests pass. Earlier versions were installed on
the iPad 1 (0.7.1) and the three iPad mini 1 devices (0.7.2, `"mic":true`; the previous app
and boot.json are at `/var/tmp/Doorbell.app.pre-redesign` and
`/var/tmp/boot.json.pre-redesign` on each).

Not verified: 0.9.0 and 0.8.6 were not installed anywhere as built here; portrait and iPad 1 screenshots, the
calling/connected/reply states on a device, a sweep of every settings sub-page, gestures
(pinch, pan, SOS slide), rotated door stations, H.264 under zoom and the role change
restart. The microphone fix has not been confirmed in a real call. The iOS 9 armv7 lane
was only syntax-checked (no iOS 9 SDK on the build Mac).

Known defects: the door-station home has been seen on the indoor mini in landscape only;
phone landscapes under 500 pt still use the old two-column layout; the clock text is hard
to read over a bright wallpaper; the bottom caption can clip.

Next: install 0.9.0 on the iPad 1 and one mini, tap through the wizard and the editor, review portrait and the remaining states,
fix the defects above.

### Web panel and Admin (ship inside Core)

Done: redesigned door, monitor and call pages; Admin console; SOS flow with countdown;
full-screen quick-reply overlay on the door page (`reply_fit`, countdown, exit hint,
guarded dismissal) and the `reply.display_ttl_s` Admin field (5 to 300);
zoom with stage clipping and rotation; panel state fields `display`, `doors[].online`,
`doors[].unlock`, `emergency.trigger.countdown_s`; Admin writes leaves; contrast tests;
air-quality admin section; the rules list shows a localized trigger label (or the rule
name) instead of the raw id for seeded `r_*_default` rules, and the unknown-trigger label
instead of "Button press" for triggers it does not list.

Visitor flow: the shared walker (`webui/panel/visitor-flow.js`), the wizard on the door
page and the Admin flow editor (with simulator). Polish: Admin lists steps in Core's
`step_order` and moves them with buttons or drag (consecutive `order` values written as whole
steps in one batch); option icons map purpose ids and known emoji to vendored Tabler icons
(briefcase, tool, dots and user added) with a picker; the door page keeps options in the content
column, shows nothing of the classic screen before the first state and opens a door's own flow on
multi-door panels. Verified against a real local Core node with screenshots;
`webui/tests/*.test.js` pass. Known gap: Admin saves the flow through the batch route with a snapshot comparison
instead of the revision-checked commit.

Not verified: iOS 5 Safari, a real H.264 stream,
rotation against a real rotated station, SOS send on a single preview node reported
"preparation could not be confirmed" (cause not investigated).

### Core

Visitor flow: implemented. `core/src/node/visitor_flow.{h,cpp}`,
`visitor_flow_service.inc`, node hooks and routes, the `visitor_message` event with
Telegram, HA and device_alert mappings, three additive exports
(`db_core_visitor_flow_json`, `db_core_visitor_flow_template_json`,
`db_core_visitor_notify_json`), a seeded `r_visitor_message_default` rule, conformance
fixture and reference walker, `core/tests/test_visitor_flow.cpp`. The default wizard lists
the enabled purposes only (a generic Call option exists only when no purpose is enabled),
steps carry an optional `order`, and the resolved document has a `step_order` list.
Shells that do not advertise `visitor_flow_v1` stay on the classic visitor screen.

Air quality: `core/src/sensors/mops_vida.{h,cpp}`, `core/src/node/air_quality_service.inc`
and `core/tests/test_air_quality.cpp`, with the `air_quality_changed` event and the
`db_core_air_quality_json` export. Unverified WIP on hardware: no real MOPS VIDA sensor was
used.

Verified on this integration: Core build and the full `doorbell_tests` suite, Python tool
tests, the conformance runner (visitor flow and event conformance). See the integration
report for the exact results.

Visitor flow Core work is complete (634 tests in `doorbell_tests`): node-level tests (`core/tests/test_visitor_flow_node.cpp`,
plus the Home Assistant case in `test_ha_bridge.cpp`) cover notify, rate limit, idempotency,
capability gating, external-camera snapshots with a fake fetcher, per-step merge and delete, batch
rejection, `require_call`, the default wizard, and the Telegram and HA mappings. An older Core
accepts and merges the unknown `visitor_flow` key (pinned by a test; see `config-schema.md`,
"Mixed versions"). Message snapshots are no longer served from the public `/asset/<sha256>` route:
they need live-media authorization. Concurrent edits to different steps of the flow mark
the section as an unresolved conflict instead of merging silently. Snapshot limits: only
`media_sources.<id>.streams.snapshot.url` is supported (no ONVIF discovery, no RTSP still), and web
panels and Web Push do not present visitor messages.

### Visitor flow status

Implemented on Core, the web door page, Admin, the kiosk, iOS and tvOS, Android and
Windows (see each deliverable for what was verified). Done on every shell in the polish round:
step ordering by Core's `order`, option icons from the purpose id or emoji, an editor preview,
start-page composition (centred block, small clock, caption at the bottom), and no classic-screen
flash before the first flow answer. Admin saves the flow through the batch route with a snapshot
comparison instead of the revision-checked commit.

Remaining known items:

- Windows: the polish was never compiled or seen on a PC; the remote re-test is outstanding and
  the earlier screenshots were never opened. The UIA test flakes on the dark notice dialog.
- Android: legacy19 has never run on a device; drag reordering is absent (the item menu is the
  only control).
- iOS 5 kiosk: the step kind cannot be changed; iOS 5 Safari is untested for the web pages; the
  selected language segment's label may be invisible on the iOS 9 kiosk profile.
- The door-station iPad mini at 10.10.38.49 has not been updated to the new kiosk build.
- Verification gaps from earlier rounds remain: the iOS editor saves were not run against a live
  Core, and no shell was exercised on a physical device in this round.

String keys shared by several shells (`flow_editor.conflict`, `flow_editor.image_upload`,
`flow_editor.call_flow_superseded`) keep one wording each in `i18n/strings.yaml`; Android's
image placement label with a value is `flow_editor.image_place_current`.
Icon picker labels differ per shell and keep separate keys: web `icon_auto`, `icon_home`, `icon_package`,
`icon_dots`, `icon_user`; kiosk `icon_house`, `icon_box`, `icon_envelope`, `icon_bag`, `icon_ellipsis`,
`icon_bell`; iOS `icon_parcel`, `icon_sales`, `icon_work`, `icon_other`, `icon_default`, `icon_custom`;
Android `icon_kind_*`; Windows `icon_wrench`, `icon_other_ellipsis`, `option_icon_pick`, `preview_note_walk`,
`preview_notify_step`. Identical wording is shared (`icon_none`, `icon_person`, `icon_mail`, `icon_tool`,
`preview_close`, `preview_restart`).

### PM2.5 air-quality sensors (unverified WIP)

Committed from another session's working tree at the owner's request and merged with the
icon changes: Core service and MOPS VIDA driver, Android and iOS Bluetooth hosts and
indicators, a Windows read-only indicator, kiosk settings and strings, web Admin section,
`docs/*/air-quality-sensors.md`. The air strings are now in `i18n/strings.yaml`. No
hardware test was run and the shells that host Bluetooth were not exercised. Treat the
feature as unreleased until a sensor is paired on each hosting platform.

## Quick-reply overlay and responsiveness (all shells)

- When a resident replies, the door-station screen shows the text full screen at the
  largest font that fits, a countdown in a corner (from `reply.display_ttl_s`, 5 to 300
  seconds, default 30), and the exit hint. See `ui-guidelines.md` for the rules. The fit
  and dismissal logic is shared in spirit but implemented per shell: `ReplyFit.kt`,
  `ReplyFit.swift`, `ReplyFit.cs` plus `ReplyDismissGuard.cs`, `DBTextFit` and
  `DBReplyDismissal` on the kiosk, `reply_fit` in the web door page.
- The setting range is 5 to 300 in Android, iOS and tvOS, the kiosk, Windows and Admin.
- Language switching and settings pages were made to respond on the tap: coalesced events,
  work off the main thread, diffed refreshes. Numbers exist only where stated above (kiosk
  and iOS simulator); Android and Windows are unmeasured and Windows was not run.

## Repository-wide notes

- `feature-parity.json` was updated with the air-quality feature; the wiki was not.
- `docs/en/ui-guidelines.md`, this file and the visitor-flow and parity documents have no
  ja/zh translations.
- The checkpoint commit `a85b088` (concurrent incoming calls and conversations) was
  never built as a whole before the redesign went on top of it.
- Rules without a title now show a readable label in Android, iOS, kiosk and web Admin;
  the Windows shell has no rule list.
