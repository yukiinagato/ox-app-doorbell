# Native UI redesign: handoff (2026-11-13)

Work stopped here at the owner's request (budget). Everything was merged to `main`
with tests deliberately deferred: code first, verification later. Treat every item
under "Not verified" as untested, not as passing.

Related documents:

- `docs/en/ui-guidelines.md`: the design spec for the redesign (principles, SOS flow,
  video stage and zoom, colour roles, per-platform control tables).
- `docs/en/native-settings-parity-audit.md`: web Admin versus native settings, per
  shell, with the role-switch design (snapshot from 2026-11-12; line numbers are
  stale).
- `docs/en/visitor-flow-design.md` and `docs/en/visitor-flow-contract.md`: the
  door-station wizard ("visitor flow") design, the owner's decisions, and the
  contract shells implement against.

## Owner decisions that shape the work

- Each shell follows its platform's official design with stock controls; shells are
  not meant to look alike. Material Components on Android API 21+, framework Holo
  widgets on API 19, ModernWpf on Windows, stock UIKit left to the system on the iOS 5
  kiosk (no UIAppearance restyling).
- Icons: vendored Tabler set only. Missing icons and widely used dependencies may be
  downloaded without asking.
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

## State per deliverable

### Windows (0.2.0, file version 0.2.0.24)

Done: Fluent redesign, NavigationView home, settings parity list emptied (role change,
replicated identity, time zones, NTP, theme, ink, unlock, idle screen, speech,
capabilities, assets, other devices, Advanced), SOS flow, zoom host, conversation
fixes, role-text contrast, automated remote UI test path
(`win/scripts/setup_test_host.ps1`, `run_remote_tests.sh`, `ui_smoke.ps1`,
`typecheck_host.py`).

Not verified: batch 12 compiled in CI but was never seen on a screen; the last small
edits (pending state by `request_id`, door-station settings language, Slide-only SOS
gesture, single dialog title) only passed the host type check. Remote run 5 was
aborted; discard its output.

Next: push, wait for `windows-contract`, run
`win/scripts/run_remote_tests.sh 10.10.38.43 nagato`, open every screenshot (zoom test
cards first, then door-station dark purpose buttons, light secondary text, in-call
title, toggles, steppers, dialog scrim). Suspect first if something misbehaves:
`Fluent.DimOwnerWhileOpen`, the settings content width binding in
`SettingsWindow.BuildShell`, `BuildStepper`. ContentDialog/Flyout are intentionally
unused (synchronous modal flows). Visitor flow: not started.

The test PC keeps one permanent firewall rule (`DoorbellTest SSH (LAN)`), OpenSSH
Server, the task `DoorbellTest-RunJob` and `C:\DoorbellTest`;
`setup_test_host.ps1 -Uninstall` reverts them. The session there is Remote Desktop:
UI tests need it connected.

### Android (0.4.3, build 46)

Done: Material 3 (modern) and framework widgets (legacy19) through per-flavor
`PlatformUi`/`ShellActivity`; home without history; SOS flow; zoom; role change;
quiet-hours, playback and secure-store bridge-order fixes; camera close race fix;
about half of the settings parity list; accent and role-text rules; video stage rule
with H.264 aspect fit; Answer on its own row in narrow action zones; debug-only
`-PdoorbellTier=legacy19 -PdoorbellLegacyAbi=arm64-v8a` lane.

Not verified: nothing was built after the last `assembleModernDebug`; the rewritten
`VideoZoomMathTest`, the new layout test and instrumentation case T35-06 were never
compiled; the legacy arm64 lane was never built (remove it if it fails rather than
debugging it); in-call was never reached on the emulator (SIP needs two devices on a
real network); legacy19 never ran anywhere; door-to-indoor role change never ran end
to end.

Next: build and test both lanes; re-check the call screen with real video at 1x and
zoomed; role change end to end; walk legacy19; finish parity (custom sound assets and
asset list, device_alert details, speech, playback policy, logs, capability override,
other devices' local settings, delete confirmations) until `KNOWN_GAPS` and
`DYNAMIC_GAPS` in `tools/tests/test_android_settings_parity.py` are empty.

### iOS and tvOS (0.5.1, builds 72 and 23)

Done: tab bar home, collection view tiles, table-based history and editors, alert
admin prompt, call action zone, SOS flow, zoom, role change
(`RoleChangeController.swift`), a first group of settings, UI gesture tests target.

Known broken: tvOS Home shows no clock or date (`DashboardView.fittingHeight` returns
101 pt with collapsed labels) and the SOS trigger overlaps the door tile when the
missed-call row shows; tvOS debug hook `sos_active` shows nothing; at the largest
Dynamic Type the incoming screen's admin QR text overlaps the countdown row and the
History primary column is too narrow; tvOS History shows a raw node id for "answered
by"; `storeMediaSecret` still writes the whole object `media_sources.<id>`.

Not verified: the role change was never exercised live; the device builds and all
checks were not rerun after the last edits.

Next: fix the above, run the five-target build and checks, then the remaining parity
(rules extras, quiet-hours suppress lists, unlock binding, colour picker, SIP TLS,
cluster volume defaults, other devices' roles, speech, playback policy, raw config,
logs, capability and UI-element overrides, tvOS search).
`ios-compat/tests/modern_settings_parity_test.py` exists but is not wired into
`test_host.sh`.

### iOS 5 kiosk (0.7.1, build 85; iOS 9 profile 0.6.1, 408)

Done and installed on the iPad 1: stock UIKit redesign, home without history, SOS
panel, role change, full settings parity, admin retry on writes, video stage rule.
Seen on the device by screenshot: home, settings, history, incoming, add device,
pairing. Not verified on the device: gestures (pinch, pan, SOS slide), rotated door
stations, H.264 under zoom, the role change restart, the nine new settings pages. The
iOS 9 armv7 lane was only syntax-checked (no iOS 9 SDK on the build Mac).

### Web panel and Admin (ship inside Core)

Done: redesigned door, monitor and call pages; Admin console; SOS flow with countdown;
zoom with stage clipping and rotation; panel state fields `display`,
`doors[].online`, `doors[].unlock`, `emergency.trigger.countdown_s`; Admin writes
leaves; contrast tests. Not verified: iOS 5 Safari, a real H.264 stream, rotation
against a real rotated station, SOS send on a single preview node reported
"preparation could not be confirmed" (cause not investigated).

### Core: visitor flow (partly implemented)

In the tree: `core/src/node/visitor_flow.{h,cpp}`, `visitor_flow_service.inc`, node
hooks and routes, `visitor_message` event with Telegram, HA and device_alert
mappings, three additive exports (`db_core_visitor_flow_json`,
`db_core_visitor_flow_template_json`, `db_core_visitor_notify_json`), conformance
fixture and reference walker, `core/tests/test_visitor_flow.cpp`.

Verified: Core builds; `doorbell_tests -tc="visitor flow*"` passes (7 cases). The full
Core suite was NOT run after these changes. Likely fallout: HA discovery
`event_types`, seeded-rule counts, panel-state shape, the features list. Not inert:
panel state carries `visitor_flow`, a default rule is seeded, flow-key writes are
validated. Native shells stay on the classic visitor screen until they advertise
`visitor_flow_v1`.

Remaining for Core: run and fix the full suite; node-level tests (notify, rate limit,
idempotency, old-shell gating, fake camera fetcher, per-step CRDT merge, batch
rejection, bridge mappings); confirm and pin what an older Core does with an unknown
top-level key (reading so far: accepted and merged, unconfirmed); API docs
(`docs/en/operation-api.md`, `webui/panel/API.md`, `webui/admin/API.md` and
translations); add the three export names to `win/abi-probe`. Snapshot limits: only
`media_sources.<id>.streams.snapshot.url` is supported (no ONVIF discovery, no RTSP
still); snapshots are served from the public `/asset/<sha256>` route for about seven
days, which deserves a security review before release.

Remaining for everything else: Admin flow editor and simulator, web `door.html`
renderer, and renderer plus full editor in each native shell (design section 3,
WP2 to WP8).

## Repository-wide notes

- `tools/tests/test_event_conformance.py` fails on the Android source contract
  `android-targeted-chime-routing`; this predates the redesign and also makes
  `tools/conformance/run.py` fail.
- `feature-parity.json` and the wiki were not updated for any of this.
- `docs/en/ui-guidelines.md`, this file and the three documents listed at the top
  have no ja/zh translations.
- The checkpoint commit `a85b088` (concurrent incoming calls and conversations) was
  never built as a whole before the redesign went on top of it.

## Door-station first screen (owner feedback, 2026-11-13, not fixed)

The owner finds the arrangement of the visitor home screen poor, on the kiosk in
particular: the language control sits alone at the top left, the clock and date float
mid-left over the wallpaper, the Call button is pushed into the bottom-right corner
with its hint detached above it, and the version line sits under it. Nothing reads as
one composition and the primary action is not where the eye lands. Redo the layout
on every shell together with the visitor-flow start page, which replaces this screen:
title and purpose/first-step options centred as one block, the primary Call option
largest and central, language switch in the top bar at the trailing edge, clock
secondary in the top bar, SOS at the leading edge of the bottom zone, no version line
on the visitor screen. Check it on a real door station before calling it done.

Kiosk 0.7.2 (86) is installed on the three iPad mini 1 devices (10.10.38.169, .49,
.154) with `"mic":true`; the previous app and boot.json are at
`/var/tmp/Doorbell.app.pre-redesign` and `/var/tmp/boot.json.pre-redesign` on each.
The iPad 1 still runs 0.7.1 (85). The microphone fix (permission request, TCC
entitlements, hardware default) has not been confirmed in a real call.
