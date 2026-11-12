# Visitor flow contract v1 — implementer's note for shell, panel and Admin agents

Sources of truth, in this order:

1. `core/include/doorbell/doorbell.h` ("Visitor flow" block) — ABI and event shapes.
2. `tools/conformance/fixtures/visitor-flow-v1.json` — `resolve` cases (config in, resolved
   document out) and `walk` cases (inputs, Core calls, what is on screen).
3. `tools/conformance/visitor_flow.py` — the reference walker (`FlowWalker`, about 150 lines).
   Port it; do not redesign it.
4. `docs/en/config-schema.md` ("Visitor flow") — the configuration an editor writes.

A shell renders the **resolved** document and never reads `visitor_flow` from raw configuration.
Only a settings/Admin editor reads and writes raw configuration.

## 1. Opting in (native shells)

Advertise feature `visitor_flow_v1` in `db_core_set_capabilities_json` (`features` object) only
once the renderer exists, and keep `purpose.button`, `call.primary` and `cancel.call` in the UI
manifest. Until then `db_core_visitor_flow_json` returns
`{"enabled":false,"reason":"unsupported_shell"}` and the shell keeps today's purpose screen.
The web panel is not gated (it ships with Core).

## 2. ABI (all additive; `db_platform_v2` is unchanged)

```c
char* db_core_visitor_flow_json(db_core* c, const char* door_id);          /* resolved document */
char* db_core_visitor_flow_template_json(db_core* c, const char* name);    /* editor templates  */
char* db_core_visitor_notify_json(db_core* c, const char* door_id, const char* step_id);
/* existing, unchanged: */
char* db_core_press_v2(db_core* c, const char* door_id, const char* purpose);
```

All three return owned strings (`db_free`). `door_id` NULL/empty = this shell's door. They
marshal to Core's loop: call them off the UI thread. Neither needs the admin window.

UI events (through the existing callback):

- `{"t":"visitor_flow_changed","door":"d_front","revision":"…","enabled":true}` — re-read
  `db_core_visitor_flow_json`. Emitted only when the document for this shell's door changed
  (config edit, purpose edit, an image finishing its download, a capability change). Coalesce.
- `{"t":"device_alert","kind":"visitor_message","door":"d_front","message_id":"…","step":"n_left",
  "purpose":"p_delivery","text":{"ja":"…","en":"…","zh":"…"},"visitor_lang":"ja",
  "snapshot":{"sha256":"…","url":"/asset/<sha256>","path":"/abs/local/file"|null},
  "visual":true,"sticky":false,"ttl_s":60,"channels":["in_app","system_notification"]}` —
  indoor side, when a rule matches. `snapshot` is absent for a text-only message. Show
  `text[<UI language>]` (fallback `ja`), title from string `flow.message_title`. It is not a
  call: no ringing UI, no call-log row, no unread-missed badge.
- `{"t":"event","type":"visitor_message",…same message fields…}` — the generic event feed.

## 3. HTTP

| Route | Auth | Notes |
|---|---|---|
| `GET /api/panel/state` | panel | gains top-level `visitor_flow` (resolved document for `?door=` if given and viewable, else the node's own door) and `doors[].visitor_flow_start` |
| `GET /api/panel/visitor-flow?door=<id>` | panel `view` | resolved document for one door |
| `POST /api/panel/visitor-notify?door=<id>&step=<step id>` | panel `call.initiate` (same as `/api/panel/press`) | result as below |
| `GET /api/visitor-flow?door=<id>` | admin session / local | resolved document, not gated by shell capability |
| `GET /api/visitor-flow/template?name=default\|purposes\|delivery` | admin session / local | `{"ok":true,"flow":{…}}` |
| `POST /api/visitor-notify` body `{"door":"d_front","step":"n_left"}` | admin session / local | same gate as `/api/press` |
| `GET /asset/<sha256>` | public | flow images and message snapshots |

Notify result (ABI and HTTP):

```json
{"ok":true,"throttled":false,"message_id":"<32 hex>"}
{"ok":true,"throttled":false,"message_id":"<same id>","duplicate":true}
{"ok":true,"throttled":true}
{"ok":false,"err":"unknown_door|flow_disabled|unknown_step|event_persistence_failed"}
```

HTTP status: 200 for ok, 409 `flow_disabled`, 500 `event_persistence_failed`, 400 otherwise.
**The visitor side passes a step id and nothing else.** There is no text parameter anywhere.

## 4. Resolved document (one full example)

```json
{
  "schema_version": 1, "enabled": true, "door": "d_front", "source": "config",
  "revision": "9f2c41d07a6be113", "start": "s_home", "idle_s": 45, "require_call": true,
  "steps": {
    "s_home": { "kind": "page",
      "title": {"ja": "ご用件をお選びください", "en": "How can we help?", "zh": "请选择来访目的"},
      "images": [],
      "options": [
        {"id": "o_call", "semantic_id": "call.primary", "label": {"ja": "呼び出す", "en": "Call", "zh": "呼叫"},
         "icon": "", "style": "primary", "to": "c_any"},
        {"id": "o_visit", "semantic_id": "purpose.button", "label": {"ja": "訪問", "en": "Visit", "zh": "访客"},
         "icon": "🏠", "style": "normal", "to": "c_visit", "purpose": "p_visit"},
        {"id": "o_delivery", "semantic_id": "purpose.button", "label": {"ja": "宅配便", "en": "Delivery", "zh": "快递"},
         "icon": "📦", "style": "normal", "to": "s_parcel", "purpose": "p_delivery"} ] },
    "s_parcel": { "kind": "page",
      "title": {"ja": "置き配できますか？", "en": "Can you leave it at the door?", "zh": "可以放在门口吗？"},
      "body": {"ja": "サイン不要のお荷物は玄関前に置いてください。", "en": "If no signature is needed, please leave the parcel by the door.", "zh": "无需签收的包裹请放在门口。"},
      "images": [],
      "options": [
        {"id": "o_leave", "semantic_id": "call.primary", "label": {"ja": "置き配する", "en": "Leave it", "zh": "放在门口"},
         "icon": "📦", "style": "primary", "to": "s_where"},
        {"id": "o_hand", "semantic_id": "purpose.button", "label": {"ja": "手渡し・サイン必要", "en": "Hand over / signature", "zh": "需当面签收"},
         "icon": "✍️", "style": "normal", "to": "c_delivery"} ] },
    "s_where": { "kind": "page",
      "title": {"ja": "置き場所", "en": "Where to leave it", "zh": "放置位置"},
      "body": {"ja": "ドア左の宅配ボックスの上に置いてください。\n\n置いたら下のボタンを押してください。", "en": "Place it on the box left of the door.\n\nThen press the button below.", "zh": "请放在门左侧的箱子上。\n\n放好后请按下方按钮。"},
      "images": [ {"asset": "<sha256>", "url": "/asset/<sha256>", "path": "/data/assets/<sha256>",
                   "alt": {"ja": "置き場所の写真", "en": "Photo of the drop spot", "zh": "放置位置照片"}, "place": "above"} ],
      "options": [
        {"id": "o_done", "semantic_id": "call.primary", "label": {"ja": "置きました", "en": "I left it", "zh": "已放好"},
         "icon": "", "style": "primary", "to": "n_left"} ] },
    "c_any":      { "kind": "call" },
    "c_visit":    { "kind": "call", "purpose": "p_visit" },
    "c_delivery": { "kind": "call", "purpose": "p_delivery", "on_unanswered": "s_parcel" },
    "n_left":     { "kind": "notify", "purpose": "p_delivery", "to": "e_thanks" },
    "e_thanks":   { "kind": "end", "title": {"ja": "ありがとうございました", "en": "Thank you", "zh": "谢谢"},
                    "images": [], "return_s": 8 }
  },
  "issues": []
}
```

No flow: `{"schema_version":1,"enabled":false,"door":"d_front","revision":"…",
"reason":"disabled|legacy_call_flow|unsupported_shell"}` → show the classic screen.

Guarantees Core makes (checked by `check_resolved_document` in the reference walker):

- `start` names a `page`; every option `to`, notify `to` and call `on_unanswered` names a step in
  the document; a notify always leads to an `end`; every page has at least one option; at most
  one option per page has `style:"primary"`.
- Options a visitor must not see (disabled, or tied to a disabled/deleted purpose) are already
  removed. Purpose labels and icons are already inlined into `label` / `icon`.
- Every text map (`title`, `body`, `label`, `alt`) has one non-empty entry for **each** language
  in `ui.languages`. Shell lookup is `map[visitor language]`, fallback `map["ja"]`, fallback any
  value. `title` and `body` are simply absent when the step has none.
- `body` is plain text: `\n` is a line break, a blank line starts a paragraph. No markup; do not
  linkify. Limits: title 60 characters, body 600 characters / 8 paragraphs, option label 40.
- `images[]` (at most 2): native shells load `path`; while it is `null` show `alt` as text; a
  `visitor_flow_changed` follows when the file arrives. Web uses `url`.
- Notify steps carry no message text and no snapshot settings: those stay inside Core.
- Ids starting with `__` (`__call`, `__end`, `__home`) are steps/options Core synthesized while
  repairing a flow. Treat them like any other.
- `source`: `config` (administrator's steps), `default` (built-in wizard, nothing written yet),
  `fallback` (unusable flow: one page with the Call button). `issues[]` is for editors only.
- `revision` changes whenever anything else in the document changes. Compare it, do not diff.

## 5. Walker (shell-side model) — port `FlowWalker`

State: `mode` (`page` | `calling` | `end` | `legacy`), `stack` of page ids (`stack[0]` = start),
`active_step` (the call step while calling, the end step while on an end page), `notice`, `reply`.

| Input | Behaviour |
|---|---|
| tap option → `page` | push it (if it is already on the stack, pop back to it) |
| tap option → `call` | `db_core_press_v2(door, step.purpose or "")`; hand over to the existing calling/in-call/cancel screens unchanged. If press returns no call id: stay on the page, show `flow.call_failed` |
| tap option → `notify` | `db_core_visitor_notify_json(door, step id)`. `ok:true` (also when `throttled:true`, never reveal throttling) → show the step's `to` end page. `ok:false`, a NULL result, or a `to` that is not an `end` → ring instead: `db_core_press_v2(door, step.purpose or "")` |
| tap option → `end` | show the end page |
| tap option → unknown kind / target not in the document | direct call: `db_core_press_v2(door, "")` |
| Back (`flow.back`) | pop one page; hidden on the start page, on end pages and while calling |
| idle `idle_s` seconds on a page | back to the start page (no-op there) |
| Done (`flow.done`) or `return_s` elapsed on an end page | back to the start page |
| call ended, reason `timeout` | if the call step has `on_unanswered`: stack = `[start, that page]`; otherwise start page with the existing `calling.no_answer` notice |
| call ended, any other reason | start page |
| reply banner arrives / expires | global overlay above any page; never changes the stack |
| `visitor_flow_changed` | re-read. Calling: keep calling (read `on_unanswered` from the new document when the call ends). Page: keep the stack if `stack[0]` is still the start and every entry is still a page, else go to the start. End: keep if the step is still an `end`. Disabled document: classic screen |
| visitor language change | re-render text only |

Any error while rendering or walking degrades to a direct call. A visitor is never stranded.
`sos.trigger`, `cancel.call`, `call.end`, the language bar and the notice banner stay exactly
where they are today. PIN gates are unchanged. There is still no route from the visitor screen
to settings, Admin, a URL or text input: the option shape has no member that could carry one.

Run the walk cases against your model: for each `walk[]` case take the resolved document
`resolve[case.flow].expect`, create the walker with `case.lang` (default `ja`), compare its
snapshot with `case.start`, then for each `steps[]` entry apply `event`, compare the Core calls
with `calls` (`[{"press":"<purpose>"}]`, `[{"notify":"<step>"}]`, both in order, or `[]`) and the
snapshot with `expect` (`mode`, `page`, `title`, `options[{id,semantic_id,label}]`, `back`, `done`,
`notice`, `reply`). For `{"flow_changed":"<name>"}` feed `resolve[<name>].expect`. Events:
`tap` (+ optional `notify_result`, `press_result:"failed"`), `back`, `idle_timeout`, `done`,
`end_timeout`, `call_ended:"<reason>"`, `reply:true|false`, `lang`, `flow_changed`.
Python reference: `python3 tools/conformance/run.py` and
`python3 -m unittest tools/tests/test_visitor_flow_conformance.py`
(`run_walk_case(case, flows, YourWalker)` accepts another walker class).

## 6. Semantic ids

| Element | Id | Notes |
|---|---|---|
| option with `style:"primary"` | `call.primary` | rendered in the existing call-button slot; existing overrides apply |
| every other option | `purpose.button` | existing overrides and tests hold |
| Back | `flow.back` | new, not safety critical |
| title/body text block | `flow.text` | new, not safety critical |
| Done on an end page | `flow.done` | new, not safety critical (added beyond the design: an end page needs one control) |

Each resolved option carries its `semantic_id`; use it rather than deriving it.
`sos.trigger`, `cancel.call`, `call.end` must stay always present.

## 7. Layout (design 2.7)

- Two zones. Content zone (title, images placed `above`, body, images placed `below`) scrolls.
  Option zone is fixed at the bottom and never scrolls off screen.
- Options: one column on phone-class and kiosk-portrait screens, two columns otherwise. Minimum
  option height 72 pt, never below the manifest minimum touch size (44). The primary option is
  the large button. If the options exceed 50% of the viewport height the option zone scrolls
  internally with a fade marking it.
- Images scale to the content width, at most 40% of the viewport height, aspect preserved.
- Focus order: title → body → options → Back. `alt` is the image's accessibility label. Announce
  the title on page change.
- With a flow, the idle screen **is** the start page: there is no separate big Call button next
  to the purposes. Without a flow the classic screen is unchanged.
- The iOS 5 kiosk keeps its icon sanitiser (non-BMP emoji in `icon`).

## 8. Editors (Admin and native settings)

Raw configuration (see `docs/en/config-schema.md`):

| Key | Written as |
|---|---|
| `visitor_flow.enabled` | bool leaf (absent = on) |
| `visitor_flow.start` | string leaf, a page id |
| `visitor_flow.idle_s` | int leaf 15..300 (default 45) |
| `visitor_flow.require_call` | bool leaf (default true) |
| `visitor_flow.steps.<id>` | **one whole object per step** |
| `doors.<door>.visitor_flow.start` | string leaf |

Rules Core enforces on write (error string `visitor_flow.<code>[: <step>[.<option>]]`; the part
before `": "` is also an i18n key, `visitor_flow.invalid` is the generic fallback with `{detail}`):

- Never write `visitor_flow` or `visitor_flow.steps` as a container and never write a key below
  a step (`visitor_flow.steps.s_home.title` is refused). Deleting `visitor_flow` (one delete op)
  is how "Reset to the built-in wizard" works; deleting `visitor_flow.steps.<id>` removes a step.
- Save one edit as **one batch** (`db_core_config_batch_json` / `POST /api/config/batch` with the
  plain `ops` array): the graph is validated on the configuration the batch would leave, so a
  step and the step it points to must arrive together. With the revision-checked commit, a set
  merges into the stored object, so dropped members need `remove_fields`; the plain batch
  replaces the whole step and is the simpler choice.
- Step and option ids: 1..32 of `[A-Za-z0-9_-]`, not starting with `__`.
- `page`: `{kind,title?,body?,images?,options[1..12]}`; option
  `{id,label?|purpose?,icon?,style?,enabled?,to}` (a label or a purpose is required; `purpose`
  inherits that purpose's label and icon; at most one `primary`).
- `call`: `{kind,purpose?,on_unanswered?}` (`on_unanswered` must be a page).
- `notify`: `{kind,message{lang},purpose?,to,snapshot?}`; `to` must be an `end`;
  `snapshot` is `{"source":"media_source","id":"<media_sources id with a snapshot stream>"}` or
  `{"source":"door_station"}`; absent = text only. The picker lists `media_sources` entries that
  have `streams.snapshot.url` (strings `flow_editor.snapshot_*`).
- `end`: `{kind,title?,body?,images?,return_s? 3..60}`.
- Graph: ≤ 32 steps, targets exist, no page cycle (`on_unanswered` may point back; it is not a
  cycle), ≤ 6 pages deep, purposes/assets/cameras exist, `start` and every door start is a page.
- `visitor_flow.require_call` true (default): `start` and every door start must reach a `call`.
  False: notify-only doors are accepted and the write returns warning
  `visitor_flow.no_call`; show `flow_editor.require_call_off_warning` next to the switch.
- Warnings ride along in `warnings[]` (`message_key` `visitor_flow.crowded_page`,
  `visitor_flow.no_call`); the write succeeded.

While no step was ever written Core serves the built-in wizard (`source:"default"`). To edit it,
fetch `db_core_visitor_flow_template_json(c,"default")` (or the HTTP route) and write its `flow`
as a batch: `visitor_flow.enabled`, `visitor_flow.start`, `visitor_flow.idle_s`,
`visitor_flow.require_call`, and one `visitor_flow.steps.<id>` per step. Templates `purposes`
and `delivery` work the same way; when replacing an existing flow include delete ops for the
steps that go away. Steps are an unordered pool: list them start page first, then in the order
they are reached. Images come from the existing asset upload; downscale to ≤ 1280 px on the long
edge and about 400 KB before uploading. Explicit steps supersede `ui.call_flow`: grey that
select and say why. Strings: `flow_editor.*`, `visitor_flow.*`, `flow.*` in `i18n/strings.yaml`.

## 9. What Core does on notify (for indoor/alert implementers)

- Per door: the same step within 60 s returns the first `message_id`; otherwise one message per
  30 s and six per 10 minutes; beyond that `throttled:true` and nothing is sent.
- Event `visitor_message` (never a `press`: no ring, no call, no missed-call logic), payload
  `{schema_version:1,message_id,step,purpose?,text{lang},visitor_lang,capture_cutoff_ms,
  snapshot?:{source,id?,sha256,bytes,type:"image/jpeg",node}}`.
- Rule trigger `when.type:"visitor_message"` with the usual `doors` / `purposes` filters; seeded
  rule `trigger_rules.r_visitor_message_default` (indoor `device_alert` + Telegram to all
  households with the snapshot when the step has one). `chime` works as for any event.
- Snapshot: taken by the node that accepted the notify, from the step's camera
  (`media_sources.<id>.streams.snapshot.url`, credentials from `secret_ref` as a request header
  only). The message is published when the picture arrives or after 4 s without it. The JPEG is
  a content-addressed blob (`/asset/<sha256>`), not a ledger asset; other nodes fetch it by hash
  on demand and it is kept about 7 days.
