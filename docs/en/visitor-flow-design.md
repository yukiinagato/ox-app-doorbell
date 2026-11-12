# Visitor flow design (door-station call-out wizard)

Status: design accepted 2026-11-13; the "Owner decisions" section at the end overrides the body where they differ. Core side partly implemented (see `native-ui-redesign-handoff.md`).

Paths are relative to the repository root. `node.cpp` means `core/src/node/node.cpp`.

## 1. What exists

**Core model**
- **Purposes:** `visit_purposes.<id> = {label{ja,en,zh}, icon, order, enabled}` (`docs/en/config-schema.md:263-275`). Only `enabled` is validated (`node.cpp:1662`). They are seeded (`node.cpp:7433`) and their tombstones are kept forever (`node.cpp:4874`).
- **Mode:** `ui.call_flow` is `purpose_first | ring_then_purpose` (`config-schema.md:175`, `:1111-1113`). In `purpose_first` the home screen shows purposes plus a "Direct call" button, which is the redundancy the owner noticed. Core downgrades to `purpose_first` when the door's shell lacks features or manifest elements (`effectiveCallFlow`, `node.cpp:6370`).
- **Press:** `db_core_press_v2(door, purpose)` and `db_core_select_purpose_v2` (`core/include/doorbell/doorbell.h:168-170`); `POST /api/press` (`node.cpp:11903`); `POST /api/panel/press`, gated by `call.initiate` (`node.cpp:12487`).
  - `doPress` (`node.cpp:12982`) appends a `press` event carrying `call_id`, `purpose`, `visitor_lang` and `expires_at_ms`.
  - A disabled purpose rings without a purpose; a repeat press returns the active call.
  - Call TTL is `ui.call_ttl_s`, 10..300, default 60 (`node.cpp:7645`).
- **Rules:** `when.type` `button` and `purpose_selected` both canonicalise to `press`, with an optional `when.purposes` filter (`core/src/events/rule_engine.cpp:95-139`). Dispatch is at `node.cpp:8540-8611`:
  - `chime`; `auto_reply` (the door shows a quick reply, and the schema doc already names `qr_okihai`, `config-schema.md:278-283`); `sip_call`.
  - `telegram`: `onAction` only handles press and purpose events (`core/src/bridge/telegram.cpp:517`).
  - `device_alert`: only emergency and missed-call events (`node.cpp:8567-8574`).
  - Indoor panels chime by default on any press that has no chime action (`node.cpp:8604`).
  - The MQTT/HA bridge receives every event (`node.cpp:8611`) but maps `press` explicitly (`core/src/bridge/ha_bridge.cpp:665`).
- **Unanswered:** a `call_cancelled` with reason `timeout` matches the virtual trigger `call_missed` (`rule_engine.cpp:101-126`).
- **Reply banner:** TTL is `reply.display_ttl_s` (`node.cpp:8758`).
- **Notices:** `notice.global` and `doors.<id>.notice` (`config-schema.md:483-485`).
- **Languages:** `ui.languages`, reverting after `ui.visitor_lang_revert_s` (`config-schema.md:176-183`).
- **Assets:** the `assets` ledger takes jpeg/png/audio up to 3 MB (`node.cpp:179`, `:188`). Every node prefetches them (`config-schema.md:1040`). Native shells use `db_core_asset_path` and the `asset_ready` event (`doorbell.h:114`, `:223`); web uses `GET /asset/<sha>` (`node.cpp:11979`, `webui/panel/panel-common.js:181-193`).
- **No flow graph exists.** `call.*` holds only `call.indoor.return_s` (`node.cpp:1695-1716`). Admin's "call flow" card is the mode select plus the return time (`webui/admin/app.js:6433-6537`).
- **No press rate limit exists**, only the idempotent active-call check.

**Shells**
- **Android:** `MainActivity.kt` (purpose section `:57-62`, `showsHomePurposes` `:1012`, `onPurposeClick` `:1027`, no-answer `:144`/`:1266`, reply `:1374`), `VisitorPanels.kt:23`, `VisitPurposes.kt`, `CallFlowController.kt:43`. Tests: `VisitPurposesTest.kt`, `VisitorUiInstrumentation.kt`.
- **iOS/tvOS:** `ios/Doorbell/VisitorScreenView.swift:328` (`setCallFlow`), `MainViewController.swift` (`buildPurposeButtons` `:1246`, `beginCall` `:2099`, `PurposeChoiceViewController` `:2424`).
- **iOS 5 kiosk:** `ios-kiosk/src/Screens/DBDoorScreen.m` (purpose scroll `:388`, `showsHomePurposes` `:1121`, a `UIAlertView` chooser `:100-108`), `ios-kiosk/src/Core/DBPurposeModel.h` (drops non-BMP emoji), `DBDoorVisitorLayout`.
- **Windows:** `win/DoorbellApp/MainWindow.Purposes.cs:67-230`, `MainWindow.VisitorActions.cs`, `MainWindow.CallFlow.cs`.
- **Web panel:** `webui/panel/door.html` (reply banner `:15`, `purposeButtons` `:215-245`, `beginPress` `:296`, state render `:497-546`), `webui/panel/call-flow.js`.
- **Pinned contracts:**
  - Semantic id `purpose.button`: web manifest (`node.cpp:454`), `door.html:231`, `MainActivity.kt:916`, `ios-compat/tests/uikit_visitor_runner/main.m`, `win/DoorbellApp/Core/RuntimeContracts.cs`.
  - `webui/tests/call_flow.test.js`, `door_visitor_cases.js`, `win/tests/test_windows_contracts.py`.
  - `feature-parity.json` F05 (`:1478`).
  - `tools/conformance/fixtures/event-traces-v2.json`, which covers events only, not UI flow.

**Editors**
- **Admin:** `renderPurposes` and `editPurpose` (`webui/admin/app.js:8705-8820`) write the whole object at `visit_purposes.<id>` plus the leaf `.enabled` (`app.js:2277-2294`), pinned by `webui/tests/admin_leaf_writes.test.js:112-131`.
- **Native settings:** `android/.../NativeSettingsSections.kt:646-689`, `ios/Doorbell/SettingsCatalog.swift:657`/`:715`, `ios-kiosk/src/Screens/DBSettingsPages.m:734-784`, `win/DoorbellApp/Settings/SettingsWindow.Lists.cs:262-468`.

## 2. Design

### 2.1 Document

Top-level `visitor_flow`:

| Key | Written as | Meaning |
|---|---|---|
| `visitor_flow.enabled` | bool leaf | Master switch |
| `visitor_flow.start` | string leaf | Entry step id |
| `visitor_flow.idle_s` | int leaf, 15..300, default 45 | Return to the start page after inactivity |
| `visitor_flow.steps.<id>` | **one whole object per step** | The step, including its `options` and `images` arrays |
| `doors.<door>.visitor_flow.start` | string leaf | Per-door entry point into the shared step pool |

- **Why this shape:** it is the same discipline Admin already uses for purposes (`app.js:2282`). Nothing below a step is ever written as a leaf, so leaf masking cannot produce a half-merged step. Concurrent edits to different steps merge; edits to the same step are last-writer-wins on the whole step.
- **Why the per-door override is only an entry point:** a back door can start at a different page without duplicating the graph. A door that needs unique pages simply adds steps to the pool.

### 2.2 Step kinds

- **`page`** is the single page-like step the owner asked for: `title{lang}`, `body{lang}`, `images[]` and `options[]` (1..N). It serves as home menu, question and instruction page alike.
  - Each option has `id`, `label{lang}` **or** `purpose:"p_x"` (inherits the purpose's label and icon, one source of truth), an optional `icon`, `style: "primary"|"normal"`, `enabled` and `to: "<step id>"`.
- **`call`**: `purpose` (optional, must be a `visit_purposes` id) and an optional `on_unanswered: "<step id>"`. It calls the existing `db_core_press_v2`, so every existing rule, chime target, Telegram message and quick reply behaves exactly as now.
- **`notify`**: `message{lang}` (the resident-facing text), an optional `purpose`, and `to` (normally an `end`). It does not ring.
- **`end`**: `title`, `body`, `images` and `return_s` (3..60, default 8). It shows a single "Done" control.

**Body text is plain text.** A newline is a line break and a blank line starts a paragraph. No markup.
- Five renderers must agree: `UILabel` on iOS 5, Android `TextView`, WPF `TextBlock`, UIKit, and escaped HTML in iOS 5 Safari. Even a tiny markup means five parsers, five escaping bugs and a divergence source for conformance.
- The same string feeds TTS and the Telegram text.
- Emphasis comes from the title, the images and the primary option.
- Limits: title ≤ 60 characters, body ≤ 600 characters and ≤ 8 paragraphs per language.

**Images:** `images: [{asset:"<sha256>", alt:{lang}, place:"above"|"below"}]`, at most 2 per page.
- Core accepts only hashes present in `assets` with an image type.
- Admin downscales before upload to ≤ 1280 px on the long edge and about 400 KB. The ledger's 3 MB cap stays, but the iOS 5 kiosk cannot decode large JPEGs comfortably.
- Native shells get a local path in the resolved document, null until `asset_ready`; they show the alt text meanwhile. Web uses `/asset/<sha>`.
- No new fetch path or permission is needed: prefetch already covers every ledger entry.

### 2.3 Core resolves, shells render

Core publishes a **resolved flow** per door through new `db_core_visitor_flow_json(c, door)`, a `visitor_flow` member in panel state (next to `purposes`, `node.cpp:12361`), and a `{"t":"visitor_flow_changed"}` UI event.

The resolved document is:
- validated and repaired;
- stripped of disabled options, and of options whose `call` purpose is disabled;
- inlined with purpose labels and icons;
- annotated with image paths and a `revision` hash.

Shells keep only a navigation stack plus two terminal calls. They never read `visitor_flow` from raw config.

**Validation**
- At write time, in `configWriteValidEffective` against the effective config (the pattern used for DTMF replies at `node.cpp:6384`); Admin saves a flow edit as one config batch.
- Again at resolve time, because CRDT merges can still produce dangling targets.
- Rules: known kinds; targets exist; acyclic; depth ≤ 6; ≤ 32 steps; ≤ 8 options per page; at most one `primary` per page; every path ends in `call`, `notify`→`end`, or `end`; at least one `call` is reachable from `start`.
- A *warning* (the existing `ConfigWarning` channel) when a page with body or images has more than 4 options.
- Resolve-time repair: a dangling or unknown target becomes a purpose-less `call`. A visitor is never stranded.

**Versioning**
- New capability `visitor_flow_v1`, added to the measured feature list (`node.cpp:6316`), plus a manifest element check, mirroring `effectiveCallFlow`.
- If the door's shell lacks the capability, Core publishes no flow and the shell keeps today's purpose screen.
- A step kind newer than the running Core resolves to a direct call.
- A shell that meets an unknown kind in a resolved document issues a direct call.
- **Unverified:** I did not confirm that an older Core accepts an unknown top-level key on write or merge. Check `configWriteValid` (`node.cpp:1815`) before relying on mixed-version fleets.

### 2.4 Redundancy and defaults

- With a flow, the idle screen **is** the start page. The big Call button exists only as an option with `style:"primary"`, rendered with semantic id `call.primary` in the existing call-button slot. The administrator may keep, relabel or delete it.
- Without a flow there is a single Call button. The two are never shown together.
- **Migration is non-destructive.** When `visitor_flow` is absent and the mode is `purpose_first`, Core *derives* a flow at resolve time: start page = primary "Call" + one option per enabled purpose, each leading to a `call`. Nothing is written to config and upgraded installs look identical.
- `ring_then_purpose` with no explicit flow keeps the legacy path.
- An explicit flow supersedes `ui.call_flow`; Admin greys that select and says why.
- Admin offers "Start from current purposes" and templates, including delivery/okihai.

### 2.5 `notify` without ringing

**Decision: a new event type `visitor_message`, not a press with a "no ring" outcome.**
- `press` is assumed to be a call in too many places: `active_calls` and the call projection (`doPress`), the default indoor chime (`node.cpp:8604`), Telegram call claiming (`telegram.cpp:464`), the HA `press` entity (`ha_bridge.cpp:665`), and missed-call logic. A "no ring" flag would need a guard in each and would be mis-rung by older nodes.
- An unknown event type is inert on old nodes.

**Surface**
- `db_core_visitor_notify_json(c, door, step_id)` and `POST /api/panel/visitor-notify` (same `call.initiate` gate as panel press).
- Core takes a **step id only**. It reads the text from the flow, so a visitor or panel client cannot inject content.
- Payload: `{schema_version, message_id, step, purpose?, text{lang}, visitor_lang, capture_cutoff_ms}`.
- Rule trigger `when.type:"visitor_message"`, with the existing `doors` and `purposes` filters.
- Small extensions to three consumers: Telegram `onAction` (text plus optional snapshot), a `device_alert` kind `visitor_message` (reusing the `missedCallNotifyUi` shape, `node.cpp:5076`), and the HA event mapping. `chime` already works for any event.
- A seeded rule `r_visitor_message_default` (indoor `device_alert` + Telegram), which the administrator can disable.

**Abuse limits, enforced in Core per door**
- The same step within 60 s is idempotent and returns the same `message_id`.
- Otherwise one message per 30 s and six per 10 minutes.
- When throttled, Core returns `ok` with `throttled:true` and the shell still shows the end page, so an abuser gets no feedback.
- Snapshots follow the rule's `with_snapshot`.

### 2.6 Interaction with existing states

- A `call` step hands over to the unchanged calling, connected and cancel screens.
- The **reply banner** stays a global overlay above any flow page (`door.html:15`). `auto_reply` rules still fire on the press.
- **Unanswered:** on `call_cancelled` with reason `timeout`, the shell goes to `on_unanswered` if set (for example "Nobody answered. Leave the parcel?"). Otherwise it goes to idle with `calling.no_answer`, as today.
- Every non-start page has Back (pops the stack) and returns to the start page after `idle_s`. The language bar stays on every page. The language revert is unchanged.

### 2.7 Layout and accessibility

- **Two zones.** The content zone (title, images above, body, images below) scrolls. The option zone is fixed at the bottom and never scrolls off-screen.
  - Options are one column on phone-class and kiosk-portrait screens, two columns otherwise.
  - Minimum option height is 72 pt (never below the manifest minimum of 44, `node.cpp:454`).
  - If the options exceed 50% of the viewport height, the option zone scrolls internally and a fade marks it.
- Images scale to the content width, at most 40% of the viewport height.
- Focus order is title → body → options → Back. Alt text is the accessibility label. The title is announced on page change.
- A missing language falls back to `ja` and then to the id (same rule as `VisitPurposes.label`).
- The iOS 5 kiosk keeps its icon sanitiser.

### 2.8 Semantic ids and invariants

- Options keep **`purpose.button`**, so existing overrides and tests hold. A primary option uses **`call.primary`**.
- New, not safety-critical: `flow.back`, `flow.text`.
- **Must not change:**
  - `sos.trigger`, `cancel.call` and `call.end` stay always present.
  - No option type can open settings, Admin, a URL or free-text input.
  - PIN gates stay as they are.
  - A visitor can always reach a ring.
  - A flow failure degrades to a direct call.

### 2.9 Alternative considered

Extend each purpose with one optional pre-call question (`visit_purposes.<id>.ask = {text, leave|call}`).
- **For it:** a tiny schema, no graph validation, and it covers okihai.
- **Against it:** exactly one level, one question shape, no images in sequence, no door-specific entry, and the Call/purposes redundancy stays hard-coded. Each later request ("ask which household", "show the gate map first") would need another special field.
- **Verdict:** the graph costs more (validator, five renderers, editors), but only once. Admin hides the cost behind templates and a linear wizard-style list. It is the only option that honestly meets "maximum freedom".

### 2.10 Example

Derived default, abbreviated:
```json
{ "enabled": true, "start": "s_home", "idle_s": 45, "steps": {
  "s_home": { "kind": "page", "title": {"ja":"ご用件をお選びください","en":"How can we help?","zh":"请选择来访目的"},
    "options": [
      {"id":"o_call","label":{"ja":"呼び出す","en":"Call","zh":"呼叫"},"style":"primary","to":"c_any"},
      {"id":"o_visit","purpose":"p_visit","to":"c_visit"},
      {"id":"o_delivery","purpose":"p_delivery","to":"c_delivery"} ] },
  "c_any": {"kind":"call"},
  "c_visit": {"kind":"call","purpose":"p_visit"},
  "c_delivery": {"kind":"call","purpose":"p_delivery"} } }
```
Delivery template: replace `o_delivery.to` with `s_parcel` and add these steps.
```json
"s_parcel": { "kind":"page",
  "title": {"ja":"置き配できますか？","en":"Can you leave it at the door?","zh":"可以放在门口吗？"},
  "body": {"ja":"サイン不要のお荷物は玄関前に置いてください。","en":"If no signature is needed, please leave the parcel by the door.","zh":"无需签收的包裹请放在门口。"},
  "options": [
    {"id":"o_leave","icon":"📦","label":{"ja":"置き配する","en":"Leave it","zh":"放在门口"},"style":"primary","to":"s_where"},
    {"id":"o_hand","icon":"✍️","label":{"ja":"手渡し・サイン必要","en":"Hand over / signature","zh":"需当面签收"},"to":"c_delivery"} ] },
"s_where": { "kind":"page",
  "title": {"ja":"置き場所","en":"Where to leave it","zh":"放置位置"},
  "body": {"ja":"ドア左の宅配ボックスの上に置いてください。\n\n置いたら下のボタンを押してください。","en":"Place it on the box left of the door.\n\nThen press the button below.","zh":"请放在门左侧的箱子上。\n\n放好后请按下方按钮。"},
  "images": [{"asset":"<sha256>","place":"above","alt":{"ja":"置き場所の写真","en":"Photo of the drop spot","zh":"放置位置照片"}}],
  "options": [{"id":"o_done","label":{"ja":"置きました","en":"I left it","zh":"已放好"},"style":"primary","to":"n_left"}] },
"n_left": { "kind":"notify","purpose":"p_delivery",
  "message":{"ja":"荷物が玄関前に置かれました","en":"A parcel was left at the door","zh":"包裹已放在门口"},"to":"e_thanks" },
"e_thanks": { "kind":"end","title":{"ja":"ありがとうございました","en":"Thank you","zh":"谢谢"},"return_s":8 },
"c_delivery": { "kind":"call","purpose":"p_delivery","on_unanswered":"s_parcel" }
```

## 3. Implementation plan

**WP0 — Contract (blocks everything; one owner)**
- Freeze the schema above and the resolved-document shape.
- Add `tools/conformance/fixtures/visitor-flow-v1.json` with two parts:
  - `resolve` cases: config in → resolved document out. Cover derived default, disabled purpose, dangling target, unknown kind, per-door start, missing language, missing asset.
  - `walk` cases: a tap sequence → expected page ids, the visible options with their semantic ids, and the expected Core call (`press(purpose)` or `notify(step)`). Include Back, idle timeout, `on_unanswered`, throttled notify, and a reply arriving mid-page.
- Extend `tools/conformance/run.py` with a reference walker and add `tools/tests/test_visitor_flow_conformance.py`.

**WP1 — Core (after WP0)**
- `node.cpp`: the validator beside `visitPurposeValid` (`:1662`), wired into `configWriteValid` (`:1815`) and the effective check (`:6381`); the resolver and derivation; `doVisitorNotify` with its limiter beside `doPress` (`:12982`); routes beside `:11903` and `:12487`; panel state (`:12361`); the feature flag (`:6316`); the seed rule (`:7464` area) and `seedableKey` (`:4874`); the `device_alert` branch (`:8567`).
- `core/src/events/rule_engine.cpp`: the new trigger type.
- `core/src/bridge/telegram.cpp:517`, `core/src/bridge/ha_bridge.cpp:665`.
- `core/include/doorbell/doorbell.h` and the capi.
- Tests: `core/tests/test_settings.cpp` (validation matrix), `test_node.cpp` (resolve, notify, rate limit, old-shell gating), `test_crdt.cpp` (per-step merge, delete).
- Docs: `docs/{en,ja,zh}/config-schema.md`, `docs/en/operation-api.md`, `webui/panel/API.md` and `API.ja.md`, `webui/admin/API.md`.

**WP2 — Web Admin (parallel with WP1, against fixtures)**
- `webui/admin/app.js`: a new "Visitor flow" card that replaces the call-flow select when a flow exists (`:6433`).
  - Step list with add, duplicate, reorder and remove.
  - Per-step form: a textarea per language; an image picker with upload through the existing Assets code and client-side downscale; alt text; an option list with a target picker; a primary toggle.
  - Templates, live validation messages, and a simulator that runs the same walker as `door.html`.
- Extract the walker to a shared `webui/panel/visitor-flow.js`.
- Tests: `webui/tests/admin_leaf_writes.test.js` (whole-step writes, batch), a new `visitor_flow.test.js`, and locale files `webui/locale/{en,ja,zh}.json`.

**WP3 — Web panel (parallel)**
- `webui/panel/door.html` and `visitor-flow.js`, written in ES5 for iOS 5 Safari.
- Extend `webui/tests/door_visitor_cases.js`.

**WP4–WP7 — Native shells (parallel with each other after WP1's header lands)**
Each gets a pure flow model fed by the walk fixtures, a renderer, and a settings editor.
- **WP4 Android:** new `VisitorFlow.kt` plus `VisitorFlowTest.kt`; `VisitorPanels.kt`, `MainActivity.kt`, `NativeSettingsSections.kt`; `tools/tests/test_android_settings_parity.py`.
- **WP5 iOS/tvOS:** new `VisitorFlow.swift`; `VisitorScreenView.swift`; `MainViewController.swift` (replace `PurposeChoiceViewController` usage); `SettingsCatalog.swift`; `DoorbellTests`.
- **WP6 iOS 5 kiosk:** new `DBVisitorFlowModel.{h,m}`; `DBDoorScreen.m`, `DBDoorVisitorLayout`, `DBSettingsPages.m`; `ios-compat/tests/uikit_visitor_runner`. Mirror into `ios-legacy` if that shell is still shipped.
- **WP7 Windows:** new `Core/VisitorFlow.cs`; `MainWindow.Purposes.cs`, `MainWindow.VisitorActions.cs`; `Settings/SettingsWindow.Lists.cs`; `win/tests/test_windows_contracts.py`.
- **Collision risk:** other agents are editing `MainActivity.kt`, `MainViewController.swift`, `SettingsCatalog.swift`, `i18n/strings.yaml` and `DBGeneratedStrings.m` right now. Land new files first and keep edits to those files to small call sites.

**WP8 — Strings and parity**
- `i18n/strings.yaml` (`flow.back`, `flow.done`, `flow.sent`, editor strings) and regeneration.
- `feature-parity.json` F05 acceptance text.
- `wiki/Features*.md`.

## Decisions for the owner

1. **Upgrade default.** I recommend upgrades stay visually identical (derived flow) and the delivery template is one click in Admin; only fresh installs get it seeded. The alternative is switching every install to the okihai template on upgrade.
2. **Must every flow keep a reachable Call?** I made it a hard validation rule so a visitor can always ring. Dropping it allows notify-only doors but risks a doorbell that cannot ring.
3. **Depth of native editors.** Full parity on Android, iOS and Windows is feasible. On the iOS 5 kiosk I propose enable/disable, template apply, start-page choice and text edits only, with image and graph editing left to Admin.
4. **Notify defaults.** Whether the seeded rule sends a snapshot and goes to all households. A photo of a courier who chose not to ring is a privacy call.
5. **Retire `ring_then_purpose`?** I kept it as the legacy path when no flow exists. Removing it would simplify every shell.

### Critical Files for Implementation
- core/src/node/node.cpp
- core/include/doorbell/doorbell.h
- core/src/events/rule_engine.cpp
- webui/admin/app.js
- webui/panel/door.html
---

# Owner decisions (2026-11-13) — these override the text above where they differ

1. **Upgrade default: the wizard is enabled on upgrade.** Existing installs get the
   delivery/okihai wizard without anyone opening Admin. So instead of a purely derived
   default that looks like today's screen, Core's default flow (used when
   `visitor_flow` has never been written) is: start page built from the enabled
   purposes (plus the primary Call option), where the delivery purpose leads to the
   okihai question page -> leave it (instructions page -> notify -> end) / hand over
   (call with the delivery purpose, `on_unanswered` back to the question). Decide
   whether this is derived at resolve time or seeded once into config (seeding makes it
   editable as ordinary steps and visible in Admin; a derived default must still be
   materialised the first time the administrator edits it). The default instruction
   text must be generic and sensible with no image, since no photo exists yet. If the
   install has no delivery-like purpose enabled, the default is the plain derived flow.
2. **"Every flow must be able to reach a call" is an administrator setting**, not a
   hard rule: `visitor_flow.require_call` (bool leaf, default true). When true the
   validator rejects a flow whose start cannot reach a `call`; when false notify-only
   doors are allowed and Admin shows a clear warning. A broken/unresolvable flow still
   degrades to a direct call.
3. **The okihai snapshot comes from an external ONVIF camera, not the door station's
   own camera** (the door camera's angle cannot see where the parcel is left). The
   `notify` step gets an optional snapshot source that names a configured external
   camera (find the existing external-camera / media-source / ONVIF / go2rtc model in
   config and code: search config-schema.md and core/ for "camera", "onvif", "rtsp",
   "media_source", "external"; the kiosk settings call it 外部カメラ), with Admin and
   native editors offering a picker of configured cameras. Core (or the node that owns
   that camera) captures a still at notify time and attaches it to the
   `visitor_message` event for rules (Telegram photo, indoor device alert, history
   thumbnail). If the install has no way to pull a still from an external camera
   today, design and implement the smallest correct one (ONVIF GetSnapshotUri or the
   camera's configured snapshot/RTSP URL through the existing media path; credentials
   only as `secret:<name>` references, never in URLs, events or logs). No camera
   configured = text-only notification. The door station's own camera is only a
   fallback the administrator may choose explicitly.
4. **Native flow editors are complete on every platform, including the iOS 5 kiosk**
   (steps, texts per language, images from Assets, options and targets, templates,
   start page, require_call, snapshot camera).
