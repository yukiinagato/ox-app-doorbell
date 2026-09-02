# Web admin API contract

Admin endpoints use the existing `dbsess` cookie with `SameSite=Strict`.

## Secret writes

`POST /api/secrets` accepts `{"secret_ref":"secret:<name>","value":"<secret>"}` from an
authenticated Admin session and writes the value through the platform secure-store callback. It
never returns the value and never materializes it in configuration. Save the corresponding
`*_ref` with `/api/config/batch` only after this call succeeds. MQTT, Telegram, and SIP forms keep
unknown fields and existing references; editing one field must not drop `pass_ref`, `answer_mode`,
or vendor extensions.

`DELETE /api/secrets` accepts the same `secret_ref` after the corresponding configuration update
has committed. It returns `409 secret_ref_in_use` while any materialized configuration value still
references that secret, preventing one shared reference from being retired out from under another
account.

MQTT and Telegram references are fleet configuration, but their values remain local to each
node's secure store. After the first save or a rotation, visit every eligible integration node and
use **Provision on this node** to write the already-replicated reference locally; this operation
does not create a new reference or mutate fleet configuration. Do not claim leader failover until
every intended candidate reports the corresponding backend ready.

SIP accounts are per-device. Admin permits password creation, rotation, or same-reference local
provisioning only when it is served by that account's target node; a remote row may edit the
non-secret user field but cannot place the target's password in the wrong node's secure store.

Every configuration write endpoint applies the same recursive secret contract. Plaintext fields
such as `pass`, `password`, `bot_token`, `sip_pass`, VAPID private keys, `panel.tokens`, invalid
secret references, URL userinfo, and credential query parameters reject the complete write even
when nested in a container object or array.

`POST /api/panel-token/rotate` stores the new credential securely and atomically replaces
`panel.token_refs` plus the non-secret `panel.token_generation`. Its response returns the
credential once with `Cache-Control: no-store`; Admin builds launch links with
`#k=<credential>`, never a query parameter. Panel sessions bind to the replicated generation and
canonical reference set, so rotation invalidates sessions across the fleet.

`POST /api/panel-token/provision` accepts
`{"secret_ref":"secret:panel.access.…","token":"<credential>"}` only for a reference already
active in replicated `panel.token_refs`. It writes this node's secure store, invalidates this
node's panel sessions, does not mutate configuration, and returns no credential with
`Cache-Control: no-store`. Repeat it through each node's authenticated Admin before relying on
panel failover.

Web Push subscriptions are not exported as plaintext configuration. Core seals the complete
`endpoint`/`p256dh`/`auth` subscription as one schema-v2 CRDT record with XChaCha20-Poly1305 under a
mesh-PSK-derived key. Startup reseals legacy raw records or removes them fail-closed; a removed
record requires the browser to subscribe again.

## POST /api/config/batch

Apply multiple LWW-map operations as one authenticated atomic commit:

```json
{
  "ops": [
    {
      "op": "set",
      "key": "devices.node.local.ui.elements.call.primary",
      "value": { "scale": 1.1, "foreground": "#ffffff", "background": "#101418" }
    },
    { "op": "delete", "key": "devices.node.local.ui.elements.status.offline" }
  ]
}
```

`set.value` is a JSON value, not a double-encoded JSON string. Validate every operation before
writing; an empty or duplicate key, unknown operation, or invalid value rejects the entire batch.
Persist one commit and issue one configuration-change notification.

Success is `{"ok":true,"n":2,"revision":"<opaque>"}`. Treat `revision` as opaque. A transitional
`hlc` alias may be read, but new clients use `revision`. If the endpoint returns 404 or 501, do not
fall back to sequential `/api/config` writes: show atomic configuration as unavailable. Import and
raw-key editing use this same contract.

Per-device recovery mode is written as a complete value at
`devices.<node_id>.local.recovery.helper_mode`. Only `off`, `auto`, and `on` are valid. The Admin
default is `auto`; use the authenticated batch endpoint so this setting cannot be partially saved.
Configured mode is not proof that a root helper is installed, reachable, or effective; display
measured runtime helper status separately.

## Per-device semantic UI

The native `ui_manifest` is a read-only runtime capability at the top level of `/api/status`, not
configuration. The node serving Admin also exposes a separate built-in Web renderer contract at
`web_ui.manifest`. Admin shows separate **Native UI** and **Web UI** editors because the element
sets differ, although both write the same serving-device path. The current Web manifest contains
`call.primary`, `cancel.call`, `call.end`, `purpose.button`, `ring.title`, `ring.action`,
`status.offline`, `reply.button`, `monitor.close`, and the always-visible two-second hold control
`sos.trigger`. It omits `sos.cancel` because a panel session is not authorized to clear SOS.

Peer gossip carries native manifests, and Core durably retains each peer's last valid native
manifest/capabilities. A configured offline device with `cached_contract:true` can therefore be
validated and saved against that cached contract across Core restart. This is queued validation,
not apply success: wait for the exact renderer to reconnect, validate, and publish its runtime
apply report. Admin still edits a Web surface only for the node serving the current page; there is
no remote/offline Web-manifest catalog, and a native peer manifest is not a Web fallback. Admin
must never write either manifest.

Schema v1 has `schema_version:1`, `units:"logical"`, viewport touch/scale constraints, and an
`elements` map. Each descriptor lists writable properties and whether the element is
`safety_critical`. Admin may write only descriptor-listed properties under
`devices.<node_id>.local.ui.elements.<semantic_id>`.

Allowed property names are `scale`, `font_scale`, `foreground`, `background`, `accent`, `border`,
and `radius`; there is no `visible`, `emphasis`, or generic `color` alias. Apply these rules:

- colors are `#RRGGBB`; foreground/background contrast is at least 4.5:1 and
  accent/background contrast at least 3:1;
- scale values stay within the manifest viewport range;
- radius is between zero and `viewport.minimum_touch` logical units;
- safety-critical elements cannot be hidden and cannot be scaled below 1;
- an invalid manifest is wholly unavailable, never partially applied.

Save changes or resets to multiple elements with one `/api/config/batch` request. Legacy
`devices.<node_id>.local.ui.style` may seed migration display only; new Admin does not write it.
Import/raw editing must reject manifest writes, legacy-style writes, and individual property-leaf
writes, reconstructing complete override objects before sending the batch.

## Call-flow compatibility

Save `ui.call_flow` as the string `purpose_first` or `ring_then_purpose` with the atomic batch
endpoint. Admin may show `ring_then_purpose` as an option only with its compatibility warning
beside it. A peer supports that behavior only when its measured status feature map explicitly has
`call_flow_v2:true`; a version number, role, or missing feature map is not proof. List every
reported peer without that declaration before saving. The warning is non-blocking because older
clients retain `purpose_first` behavior during a rolling upgrade.

## Lossless trigger-rule editing and SOS dry run

`trigger_rules.<id>` is a whole-value configuration entry. The visual editor starts with a deep
copy and merges only fields the administrator changed. It preserves unknown top-level, `when`,
`schedule`, action, `targets`, and `presentation` fields, including `never_suppress`. Unknown
action types are shown read-only and are not converted or removed. Opening and saving the seeded
`r_sos_default_on` or `r_sos_default_off` rule without changes must produce a value structurally
identical to the original.

The editor supports `emergency_on` and `emergency_off` triggers and the `device_alert` action:

```json
{
  "type": "device_alert",
  "targets": {
    "devices": ["panel-a"],
    "roles": ["indoor_panel"],
    "web_subscription_groups": ["guards"]
  },
  "channels": ["in_app", "system_notification", "web_push"],
  "never_suppress": true,
  "presentation": {
    "visual": true,
    "sound": "siren1",
    "volume": 100,
    "sticky": true,
    "ttl_s": 0,
    "background": "#8F1010",
    "foreground": "#FFFFFF",
    "accent": "#FFD166"
  }
}
```

Each selector accepts an array or `"all"`. A legacy action with no `targets` object addresses all
native nodes and every Web subscription group. Once `targets` exists, selectors are explicit: an
object containing only `web_subscription_groups` addresses no native shell, and an object without
`web_subscription_groups` addresses no active Web page or Push subscription. `web_profiles` is a
read-only compatibility alias; new saves use `web_subscription_groups`. Missing `channels` retains the legacy `in_app`
default, while an explicit empty array is silent. Colors use `#RRGGBB`; the Web renderer rejects
unsafe contrast and falls back to its safe palette. The dry-run resolves device IDs, roles, Web
subscription groups, offline or undiscovered devices, configured local recipients, and recipients
whose measured `device_alert_channels` and
channel support/permission say they can currently present the request. It warns about zero
recipients, silent presentation, unsupported or unavailable channels, rolling-upgrade nodes whose
channel support is unknown, requested Web Push with no matching subscription, and an unavailable
Push backend. Warnings never block saving.

`status.web_push.delivery_backend:true` means the current mesh partition has an eligible
`web_push` leader whose measured capabilities include a valid HTTPS sender configuration and a
locally readable VAPID private secret. `configured:true` alone is not delivery readiness; status
also exposes `leader`, `local_secret_ready`, and a bounded `warning_code` for diagnosis.

The Integrations tab edits the non-secret sender URL, VAPID public key/subject, and secret
references as one save plan. Entering a new VAPID private key or optional sender bearer token first
stages that value in the current node's secure store under a fresh reference; the replicated
configuration is committed only after those secure writes succeed. Once a reference exists, use
**Provision on this node** from each intended leader candidate's own Admin page to install the same
value without changing replicated configuration. Do not rely on Push-only SOS until every intended
candidate is provisioned and status reports a non-empty leader with `delivery_backend:true`.

`emergency.web_active_page_alerts` is an independent boolean Admin switch, default `true`. When
true, an open Web panel renders replicated active SOS even if the matching rule has zero recipients,
is Push-only, or has a stale negative projection. When false, raw replicated state is not rendered
by an open page, but a matching positive `device_alert` or delivered Web Push still can be.
While this raw path is enabled, a rule TTL expires its custom decoration and sound but cannot hide
the safe red raw-SOS overlay; that overlay remains until SOS clear or the switch is turned off.

Core `delivery_result` events are dispatch-attempt records: for example, local shell callback
dispatch, shell unavailable, Push accepted/failed, no recipients, or backend unavailable. They do
not prove OS/browser presentation. Native clients separately publish per-channel presentation,
permission, TTL-expiry, and limitation results under runtime `device_alert`; Admin must show the two
evidence levels distinctly.

## Call history and the missed-call rule

`GET /api/call-log?since_ms&before_ms&limit&door&outcome` and `POST /api/call-log/seen` accept an
authenticated Admin session as well as a panel session; the panel contract in
`webui/panel/API.md` documents the row shape. `outcome` is derived, never stored, and concurrency
losers, fenced calls, and live calls are excluded. The seen watermark behind `unread_missed` is
device-local and is not replicated, so each node reports its own badge.

`GET /api/events` additionally accepts `since_ms` (inclusive lower bound on `wall_ms`), `type`, and
`door`, and every row carries `origin`, `seq`, and `hlc` for replication identity. The response
carries `server_ts` for use as the next cursor.

`call_missed` is a rule trigger with no event of its own: a `call_cancelled` event whose reason is
`timeout` or `recovery_*` matches both `call_cancelled` and `call_missed`. The seeded
`r_missed_call_default` rule is an ordinary `trigger_rules` entry — editable, disableable, and
deletable in the rules tab — that raises a `device_alert` on `indoor_panel` roles and Web Push and
deliberately excludes door stations. Deleting it is permanent; a local meta marker stops the
migration from recreating it on restart.

`events.retention_days` (1..3650, default 90) is the age floor of the local event-retention sweep,
which always also keeps the newest 5,000 records per origin. Deletion additionally requires a
durable replication coverage vector; until one exists, retention is a no-op.

## Time service

`GET /api/status` carries a `time` object:

```json
{
  "zone": "Asia/Tokyo", "zone_known": true,
  "source": "system", "enabled": false, "ok": false,
  "offset_ms": 0, "measured_offset_ms": 0,
  "last_sync_ms": 0, "rtt_ms": 0, "server": "", "interval_s": 900,
  "offset_min": 540, "syncing": false,
  "local": { "iso": "2026-09-02T21:30:00+09:00", "date": "2026-09-02",
             "hh": 21, "mm": 30, "ss": 0, "weekday": "wed", "weekday_num": 3,
             "offset_min": 540, "dst": false, "known": true,
             "wall_ms": 1772000000000, "tz": "Asia/Tokyo" }
}
```

`source` is `ntp` only while `time.ntp.enabled` is true *and* a sync succeeded within three
intervals; otherwise it is `system` and `offset_ms` is 0. `measured_offset_ms` keeps the last
measurement either way, so the card can show what was measured after NTP is switched off.
`err` is present after a failed round and is one of `no_response`, `bad_server`, `bad_reply`, or
`implausible`. Admin must render `source` and never infer it from `enabled` alone: an enabled but
unreachable time service is still running on system time.

`POST /api/time/sync` (Admin session) starts one immediate round and returns
`{"ok":true,"started":true}`. It returns `409 {"ok":false,"err":"ntp_disabled"}` when the
independent time service is off, and `409 {"ok":false,"err":"not_started"}` before Core is running.
The exchange is asynchronous: re-read `/api/status` (or wait for the `time_changed` UI event)
rather than treating the 200 as a completed sync.

Writing `time.zone` through the normal configuration endpoints is rejected unless the identifier is
in the table bundled in Core, and Core rewrites the derived `integrations.tz_offset_min` itself.
Admin must not write both from the form.

## Volumes

Cluster defaults live in `audio.volume.{call,sos,idle}` (0..100) and a device overrides them at
`devices.<id>.local.audio.volume.<level>`. Container writes (`audio`, `audio.volume`,
`devices.<id>.local.audio`) are validated as a whole, so an atomic batch cannot smuggle an
out-of-range level in through a parent object. Removing an override means deleting the leaf key,
not writing `null`.

Core resolves the effective level as device override → cluster default → built-in default
(call 80, sos 100, idle 60), with `emergency.alarm_volume` as an extra fallback for the SOS level.
`db_core_audio_json` exposes the same resolution to native shells.

## Announcements

`POST /api/doors/<id>/notice` accepts `{"text":"…","expires_ms":0}` or `{"text":"…","ttl_s":3600}`;
`expires_ms` wins when both are present and 0 means "until cleared". `DELETE /api/doors/<id>/notice`
clears it, and clearing an announcement that is not there succeeds. Both accept an authenticated
Admin session **or** a panel credential, because the indoor announcement dialog and the Admin doors
tab write the same value.

The value is ordinary replicated configuration at `doors.<id>.notice`:

```json
{ "text": "Deliveries to the side gate today", "from_device": "<node_id>",
  "created_ms": 1772000000000, "expires_ms": 0 }
```

`text` is 1..200 characters, counted in Unicode code points. `from_device` and `created_ms` are
written by Core, not by the caller. An unknown door, empty text, or text over the limit is
`400 {"ok":false,"err":"rejected"}` and leaves the current announcement untouched. Core prunes an
expired announcement on its one-minute tick and emits `notice_changed`, so a panel that is showing
one does not need its own expiry timer.

## Battery and power

A device that implements the optional platform power callback publishes
`status.self.power` (and the identical `status.node.power`) and appears with the same object in
`status.peers[].power`:

```json
{ "battery_pct": 82, "charging": false, "mains": true }
```

`battery_pct` is `-1` on a device with no battery, and the UI must then show nothing at all rather
than a zero-percent indicator. A device that does not implement the callback has no `power` key,
which is not the same as a battery at zero. Peer values arrive through the bounded runtime
projection, so they carry these three fields and nothing else.

## Announcements, unlock, appearance, and the automatic theme

`POST /api/notice` and `DELETE /api/notice` write the cluster-wide announcement at
`notice.global`, taking the same `{"text":…,"expires_ms":…}` or `{"text":…,"ttl_s":…}` body as
the per-door route and accepting an Admin session or a panel credential. A door-specific
announcement always overrides it, so publishing a house-wide message never clears what a door
already carries. `status.doors.<id>.notice` reports the resolved value with `"scope":"door"` or
`"scope":"global"`; render that, do not merge the two yourself. `status.notice.global_active`
says whether a cluster-wide message exists.

`notice.presets` is an administrator-editable array of at most eight `{id, text}` entries that the
announcement dialogs render. Ids are 1..32 characters of letters, digits, `_` or `-`; text is
1..200 code points. Three are seeded once and may be edited or deleted freely.

`POST /api/doors/<id>/open` triggers the configured unlock action for one door, accepting an Admin
session or a panel credential. It returns `409 {"ok":false,"err":"unlock_not_configured"}` when no
unlock action exists anywhere, and `404` for an unknown door — never a success that did nothing.
The action is the existing feature-code path: the same `ha_command` a SIP DTMF code publishes,
which the MQTT bridge forwards as `<base_topic>/cmd/<command>`.

`status.doors.<id>.unlock` is `{"configured":bool,"command":"…","show_button":bool,
"source":"default"|"admin"}`. `show_button` defaults to `configured`; `doors.<id>.unlock.show_button`
forces either answer. Decide from this before rendering the control, and when it is shown but
unconfigured, say so on the tap.

`status.display.appearance` is `{"configured":…,"effective":"light"|"dark","follow_system":bool,
"schedule":{"dark_from":…,"light_from":…}}`, resolved by core in `time.zone`.

`status.display.theme` carries the automatic contrast decision: `auto_background`, `auto_ink` per
semantic region, `auto_accent` (`call_button` plus `call_button_ink`), the `ink_override` map, and
the effective `call_button_bg` / `call_button_ink`.

`auto_background.source` is `color` when no background image is configured, `image` when one was
sampled, and `image_unsampled` when an image **is** configured but core could not sample it — with
a `reason` of `too_large` (past core's 16 MP decoded-pixel budget), `decode_failed`, or `missing`
(not cached on this node yet). On `image_unsampled` the published `color`, `auto_ink` and
`auto_accent` were derived from the flat theme colour, not from the picture on screen: do not
trust them. Sample the image locally, or keep the previous ink until the asset arrives. Reporting
`color` for a configured-but-unsampled image is what made shells paint light text over a light
background photograph. `display.theme.auto_ink` and
`display.theme.auto_accent` are computed and rejected on write; override with
`display.theme.ink_override.<region>` and `display.theme.call_button_bg`, or their
`devices.<id>.local.theme` equivalents. Always take the button text colour from
`call_button_ink`: on a mid-luminance background no colour can both separate from it and carry
white text, and core returns the best compromise rather than an unreadable button.

`status.video.publish` carries the counters core measures on the sending side: `frames`,
`keyframes`, `fragments`, `dropped_forward`, `frame_interval_ms`, `fps_x10`. Latency, jitter and
displayed frames belong to each receiver's own player and arrive through its runtime status.

## Colour contrast is advisory

Every configuration write endpoint validates colour **format** (`#RRGGBB`) and rejects anything
else. Contrast is measured but never enforced: a write that falls short of WCAG 2.1 AA (4.5:1 for
text, 3:1 for large text and UI components) still succeeds and returns

```json
{"ok":true,"warnings":[{"key":"devices.<id>.local.ui.elements.cancel.call",
                        "property":"foreground","contrast":3.1,
                        "message_key":"theme.low_contrast"}]}
```

`warnings` is absent when there is nothing to report. Show the measured ratio inline next to the
field; do not treat it as a failure or roll the value back. The check runs against the *resolved*
element — manifest defaults, the stored override, and this write merged — so a warning may name a
property the current request did not touch.

## One administrator password

`POST /api/login` verifies against `admin.password_hash`, the cluster-wide credential, falling back
to this node's legacy local digest until the first successful login republishes it. The first
password offered on any surface becomes the cluster's. Five failures pause every surface for ten
minutes and the endpoint answers `429 {"ok":false,"err":"locked"}`; the counter is shared with
`db_core_admin_password_verify`, so a native settings screen and the web page cannot be attacked
independently. Changing the password invalidates every existing Admin session.

`status.emergency.cancel_requires_password` is what gates the SOS clear control: core computes it
as `emergency.cancel_requires_pin` AND a password actually being set, so a cluster that never
chose one can always silence its own alarm. `status.emergency.admin_password_set` reports the
second half on its own.

## Pairing: minting a PIN is not bulk add

`POST /api/join-token` mints or refreshes the join PIN and nothing else; the bulk-add window stays
shut, so a device already announcing itself is not auto-invited merely because a PIN is on screen.
It accepts an optional `{"seconds":N}` (clamped to 30..600) and returns
`{"ok":true,"host":…,"pin":…,"expires_s":…}`, the same shape `POST /api/pairing/start` returns.
`POST /api/pairing/start` is the explicit bulk-add button: it opens the auto-invite window *and*
mints a PIN, and belongs only to that control and its warning.

`pairing_revoked` means a full local reset, not just "forget the PSK". On receiving it, and when an
administrator confirms removal on the device itself, the shell deletes the secure PSK, the pairing
fields of `boot.json`, **and** name/role/door/`setup_complete`, then restarts into first-run setup.
A device that kept its old role and door would rejoin the next cluster half-configured.

## Visit purposes can be switched off

`visit_purposes.<id>.enabled` (bool, default true) hides a purpose from visitors without deleting
it: wording, icon and order survive being switched off and back on. Disabled purposes are omitted
from the panel contract's `purposes` list and cannot be attached to a call. A door station still
showing a stale button rings anyway, without the purpose — the visitor is never punished for a
configuration change they cannot see. The 用件 tab offers a toggle alongside delete.

## Doors always exist for a live door station

A door station whose `boot.json` names a door creates `doors.<door>` itself when the entry is
absent — on founding or joining a cluster and on every later start while paired — labelling it
with the device name in all three languages. Before this, a cluster founded by a door station had
no `doors.*` entries at all: `status.doors` was `{}`, `POST /api/doors/<id>/notice` answered
`rejected`, and only the cluster-wide `POST /api/notice` worked. The entry is only ever created,
never rewritten, so renaming a door, giving it a building, or reassigning the station in the 門口
tab survives every restart.

`status.doors` also lists any door served by an **alive door-station peer** that has no
configuration entry yet, with `"configured": false` and the device's name as the label. Render
those tiles normally — they are addressable, and the first announcement or unlock write creates the
entry, after which the door reports `configured`. Offer the 門口 tab as the place to name it. A
door nobody serves and nothing configures stays unknown and is refused with `400 rejected`.
