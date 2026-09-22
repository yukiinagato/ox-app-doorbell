# Panel API contract

This document defines the HTTP contract used by `door.html`, `monitor.html`, and the modern
`call.html` page. iOS 5 Safari clients use ES5 and two-second XHR polling; WebSocket, SSE, and
`fetch` are not required for the legacy pages.

## Authentication

Panel credentials are issued once by the authenticated Admin UI. Core stores only
`panel.token_refs` plus a non-secret `panel.token_generation` in replicated configuration; the
values remain in platform secure storage on each node. Sessions bind to the current generation and
canonical reference set, so any replicated rotation rejects old cookies on every node. Admin must
provision the already-replicated reference separately on each panel-serving node before failover
can authenticate the same credential.
Admin launch links put the one-time credential in the URL fragment (`#k=...`), which is not sent in
HTTP. The page exchanges it with `POST /api/panel/session` and then uses the HttpOnly `dbpanel`
cookie. Query/form credentials are rejected. Cross-node browser uploads may use an
`Authorization: Bearer <credential>` header; bearer values must never appear in URLs or logs.

## GET /api/panel/state

The optional `group=<name>` query selects the Web subscription group used for this page's
`device_alert` projection. The Web runtime reads `?group=<name>` from the panel URL, persists a
valid name locally, and uses that same group for both polling and any Push subscription. Missing or
invalid names fall back to `all`.

This is the polling state endpoint:

```json
{
  "call_flow": "purpose_first",
  "active_page": "monitor",
  "emergency": { "active": false, "hlc": "", "web_active_page_alerts": true },
  "doors": [
    { "id": "d_front", "label": "Front door", "calling": false },
    { "id": "d_back", "label": "Back door", "calling": true,
      "call_id": "0195…", "call_state": "ringing", "stage_revision": 1,
      "expires_at_ms": 1756300050000, "recovery_required": false }
  ],
  "events": [
    { "type": "press", "door": "d_front", "device": "", "wall_ms": 1756300000000 }
  ],
  "quick_replies": [
    { "id": "soon", "label": "Be right there",
      "labels": { "ja": "すぐ行きます", "en": "Be right there", "zh": "马上来" } }
  ],
  "reply": null,
  "server_ts": 1756300020000
}
```

- `doors[]` lists configured doors. `calling` is true only while the current call remains active.
- `call_flow` is `purpose_first` or `ring_then_purpose`. Older object-shaped values are read-only
  compatibility data and must not be emitted by new clients.
- `call_id` identifies one call and is mandatory for cancellation, delayed purpose selection, and
  recovery acknowledgement. Never apply an action to a later call using a stale ID.
- `call_state` may be `ringing`, `purpose_pending`, `answered`, `in_call`, `cancelled`, `expired`, or
  `ended`. A client must not roll the UI back when it receives a lower `stage_revision`. Terminal
  states are read-only tombstones retained for up to 30 seconds; they never re-enter recovery.
- `recovery_required:true` means Core restored an unresolved call after restart and is awaiting an
  explicit result from `POST /api/panel/recovery`. It is not a new ring request.
- `emergency` is authoritative when present. Only rolling-upgrade clients may reconstruct missing
  emergency state from recent `emergency` and `emergency_cancel` events.
- `active_page` is an optional hint: `door`, `monitor`, or `call`. Replicated active SOS takes
  precedence while `web_active_page_alerts` is enabled; a positive matching `device_alert` or Push
  can also take precedence when it is disabled. Ignore unknown values.
- Optional media fields are `source_node_id`, `stream_mjpeg`, `stream_mp4`, and
  `playback_profile`. The profile orders receiver-resolved strategies and their startup/stall
  timeouts. Web clients skip unsupported strategies and fall back without claiming playback.
- `events` contains up to ten recent event summaries. `reply` is the latest quick reply or null;
  compare only monotonically increasing `reply.ts` values.
- `quick_replies` is the bounded configured reply catalog without audio paths or unrelated
  configuration. A monitor may choose the label matching `doors[].visitor_lang`.
- `purposes`, `languages`, `sounds`, and the personalization fields below may also be present.

## Call lifecycle actions

All bodies in this section use `application/x-www-form-urlencoded`.

### POST /api/panel/press

Body: `door=<id>[&purpose=<id>]`.

Success returns `{"ok":true,"call_id":"<opaque>","call_state":"ringing",`
`"stage_revision":0,"expires_at_ms":<ms>}`. The Web panel must retain the call identity and cancel
control until it observes a terminal state; a lost poll is not evidence that the call ended. An
unknown door or purpose returns 400, and a durable event write failure returns 500. For
`purpose_first`, include the selected purpose in this request.

### POST /api/panel/purpose

Body: `door=<id>&call_id=<opaque>&purpose=<id>`.

This is the delayed selection step for `ring_then_purpose`. It succeeds only for the matching
active call and returns its `call_id` and updated `stage_revision`; a stale call returns 409.

### POST /api/panel/cancel

Body: `door=<id>&call_id=<opaque>`.

Success acknowledges command acceptance. Keep the UI active until state becomes cancelled or
`calling` becomes false. Cancellation is rejected once the call is in-call. Missing or stale call
identity returns 409; legacy nodes without a safe endpoint must be shown as unsupported.

### POST /api/panel/reply

Body: `door=<id>&call_id=<opaque>&stage_revision=<n>&reply_id=<configured-id>`.

This sends only a configured quick reply for the exact still-ringing call. It returns 409 for a
stale, superseded, or established call and 400 for an unknown reply. Success ends that ringing call;
arbitrary reply text is intentionally not accepted from a panel session.

### POST /api/panel/hangup

Body: `door=<id>&call_id=<opaque>`.

Use this after the matching call reaches `answered` or `in_call`. It ends only the SIP leg owned by
that call ID and emits `call_ended`; it never uses the visitor cancellation path. A ringing,
missing, stale, or unsupported call returns 409.

### POST /api/panel/call-lifecycle

Body: `door=<id>&call_id=<opaque>&stage_revision=<n>&dialog_id=<32-hex>&state=<answered|heartbeat|ended>[&reason=<token>]`.

Resident WebRTC clients create one cryptographically random `dialog_id` for an answer attempt.
They report `answered` only after that exact SIP dialog is confirmed, send `heartbeat` at least
every ten seconds while it remains established, and report `ended` only for a dialog whose
`answered` report succeeded. Monitor calls never use this endpoint. The response includes an
opaque `dialog_owner`; if panel state later reports a different owner, the losing SIP dialog must
terminate without reporting `ended`. Missing identity, stale revision, a second browser dialog, or
an ended/non-established call is rejected. A missing heartbeat produces one recovery cancellation
after ten seconds.

### POST /api/panel/recovery

Body: `door=<id>&call_id=<opaque>&restored=<true|false>[&dialog_id=<32-hex>]`.

Use this only while the matching state entry has `recovery_required:true`. `restored=true` confirms
that the client restored the call UI/session; false resolves it as not restored. Success returns
`{"ok":true}` and clears the pending flag. Missing, stale, already-resolved, or non-pending calls
return 409. Bad tokens return 403. Retry only the same call ID; the operation must never resolve a
newer call. An in-call WebRTC recovery requires the same `dialog_id` that won the answered claim;
a different browser or a generic door page cannot confirm that dialog.

## Emergency

The stock door, monitor and call pages use the [durable operations API](../../docs/en/operation-api.md)
with `action:"sos_start"`. One explicit SOS activation prepares one handle, then executes it.
Every request, including session metadata and status queries, has a four-second transport deadline.
The shared overlay displays preparing, sending, accepted, explicitly unstarted, refused, and
unknown results. Accepted means Core accepted the operation; it does not confirm notification
delivery. Only replicated state or a valid Push controls the active emergency presentation.

An ambiguous execute preserves the handle. The recovery button queries that same handle; it never
prepares a replacement automatically. A query returning `prepared` offers explicit execution of
that handle. Only an authoritative unstarted terminal state permits an explicit new preparation.
A lost prepare response never causes execute and can be retried only by a new user action.
The handle is retained in tab session storage when available, without credentials, so a normal
page refresh offers a query before another send. A session change does not grant access to that
record: Core rechecks its original creator and current permissions.

The server-derived `dbpanel` session principal may use only `sos_start`, with the serving node's
explicit SOS grant and configured authority. Every operation request carries the session CSRF
header; mutations require a trusted exact Origin. There is no shared-Bearer or legacy-endpoint
fallback. The existing two-second pointer/keyboard hold remains available; assistive-technology
button activation and ordinary recovery buttons use the same single-intent controller.
Authentication, permission and validation refusals remain visible with another-help instructions.

`POST /api/panel/emergency` remains a legacy one-shot compatibility endpoint (`active=1`).
Panel clients cannot clear SOS: `active=0` or `active=false` returns 403. Clearing retains the
existing kiosk/admin rules, including the existing no-admin-password exception on those controls.

SOS active/clear state always replicates. `emergency.web_active_page_alerts` is an administrator
boolean and defaults to true. When true, an open page renders replicated active SOS before any
zero-recipient, Push-only, or stale negative `device_alert` projection. When false, raw state does
not trigger active-page presentation, but a positive `device_alert` selected for the page's Web
group, or a delivered Web Push, still can.

`device_alert.presentation` and Push payload presentation may contain `visual`, `sound`, `volume`
(0–100), `sticky`, `ttl_s`, `background`, `foreground`, and `accent`. Web validates bounds and
color contrast, uses a safe palette on rejection, renders a full-screen overlay, and uses a
bounded generated alarm tone when browser audio policy permits. While raw active-page SOS is
enabled and SOS remains active, a non-sticky positive TTL expires only the rule-selected
decoration and sound: the page falls back to the persistent safe red raw-SOS overlay until SOS is
cleared or the administrator disables the raw-state switch. With the raw path disabled, TTL may
hide the projected presentation; TTL never clears replicated SOS state. Browsers without Push
continue polling while the page is open; Push additionally requires HTTPS/localhost, Service
Worker/Push support, an authorized subscription, and a configured delivery backend.

The Push payload preserves all presentation fields. The Service Worker maps sticky/TTL and the
requested sound/volume to the browser notification capabilities, then forwards the same payload to
an open panel where full-screen colors and bounded audio are rendered. Browser/OS notification APIs
may ignore custom sound/volume and do not offer arbitrary background/foreground/accent colors;
those limitations must not be reported as successful OS presentation.

## Images and streams

### GET /snapshot-proxy?door=<id>

Returns the latest JPEG as `200 image/jpeg` with `Cache-Control: no-store`; an unavailable station
returns 503. Clients may add `t=<timestamp>` to defeat caches. `live=1` may upgrade the response to
MJPEG, but a server may legally return one JPEG.

### GET /stream-proxy.mp4?door=<id>

Returns a same-origin fMP4/H.264 stream. The server proxies the responsible station rather than
redirecting the browser across origins. Unknown door is 404, invalid token is 403, and unavailable
or disabled encoding is 503. Disconnecting the client releases the upstream subscription.

### POST /api/panel/media-authorize

The relative same-origin endpoint accepts form fields `door`, `call_id`, and `stage_revision`.
First obtain the session's random `csrf_token` from `GET /api/panel/session` (or the credential
exchange response). Authorization, frame publication, and a session-bound call lifecycle require
the `dbpanel` HttpOnly cookie, `X-Doorbell-CSRF`, and an exact trusted `Origin`. Long-lived shared
Bearer credentials cannot publish. An initial `answered` transition binds the independently
authenticated Web session to the server's dialog owner; knowing another session's `dialog_id`
does not grant publication. Legacy answers without this binding and recovered dialogs whose
original Web session was lost cannot publish.

Success returns `schema_version:1`, `door`, `call_id`, integer `stage_revision`, server-derived
`dialog_owner`, a random 32-character lowercase-hex `media_generation`, `publish_remaining_ms`
(integer 1..10000), and `upload_path:"/call-frame"`. The deadline cannot outlive the current
dialog lease or Web session. Renewal creates a new generation and clears the previous frame;
it never renews the dialog lease. Session background reads and media traffic do not extend
interactive idle expiry. Restart and observed credential changes invalidate sessions and grants.

Only this node's door station is supported here. Cross-node requests return 501 with
`media_transport_unsupported`; the bounded authenticated transport remains a T16 qualification
gate. There is no direct-peer HTTP fallback or wildcard CORS. These local checks alone do not
advertise the cross-node `media_publish_v1` capability.

### POST /call-frame?door=<id>&call_id=<id>&stage_revision=<revision>&media_generation=<generation>&frame_sequence=<sequence>

The body is one `image/jpeg`. All identity fields are mandatory. The server rechecks current
call, revision, owner, session/credential, and authorization expiry before writing the transient
peer-frame slot. `frame_sequence` is a decimal string from 1 through 9223372036854775807, at
most 19 digits, without leading zero, sign, or exponent. Duplicate/older sequences and retired
generations return 409. Wrong session/CSRF/Origin returns 403; malformed identity/JPEG returns
400. Encoded data is capped at 1 MiB; JPEG metadata must describe at most 307200 pixels and
neither dimension may exceed 1024. T16 still owns strict HTTP-reader admission and worker bounds.
The browser sends at most two frames per second and retains one in-flight request. A successful
reply echoes generation and sequence with `acceptance:"remote_core_accepted"`; it does not prove
that a remote screen rendered the image.

### GET /peer-frame.jpg?door=<local-door>&call_id=<id>&stage_revision=<revision>

Only the local door station's current call may be read. `door` defaults to the station's own
door; `call_id` and `stage_revision` are mandatory (409 when absent). Native loopback readers
need no browser cookie. Non-loopback readers need a current `dbpanel` session; any supplied
browser `Origin` must be exactly trusted, including on loopback. Missing/currently invalid
frames and frames older than three seconds return 404. No wildcard CORS is supplied.

Successful `image/jpeg` responses have `Cache-Control:no-store` and headers
`X-Doorbell-Call-Id`, `X-Doorbell-Stage-Revision`, `X-Doorbell-Dialog-Owner`,
`X-Doorbell-Media-Generation`, and `X-Doorbell-Frame-Sequence`. The last two have the same
32-hex/decimal-string contracts as publication. A shell captures current call/revision/owner,
Core generation, and its own polling generation before requesting; it checks them again and
validates all response identity headers before rendering. Retiring a poll clears its image and
cancels its request; a late completion cannot clear a successor's busy flag or display its image.

An in-call UI state may include `remote`, `peer_node`, and `peer_stream`. When peer resolution
fails, a door station may poll `/peer-frame.jpg`; an indoor client reports video unavailable.

## Call history

`GET /api/call-log?since_ms&before_ms&limit&door&outcome` is accepted with either the panel session
cookie or an authenticated Admin session. Rows are newest first, `limit` defaults to 50 and is
clamped to 500, `since_ms` is an inclusive lower bound on `ts`, and `before_ms` is an exclusive
upper bound used to page older.

```json
{ "rows": [ { "id": "<origin>:<seq>", "call_id": "0195…", "ts": 1756300000000,
              "door": "d_front", "purpose": "p_delivery", "visitor_lang": "en",
              "outcome": "answered", "answered_by": "living-room", "duration_ms": 42000,
              "snapshot": "", "hlc": "…", "seen": true } ],
  "unread_missed": 0, "seen_hlc": "…", "server_ts": 1756300100000 }
```

`outcome` is derived from the replicated projection: `answered`, `replied`, `missed` (a ring
timeout or a failed restart recovery), or `cancelled`. Concurrency losers, fenced calls, and calls
that are still ringing or connected are never returned.

`POST /api/call-log/seen` with `{"up_to_hlc":"<row hlc>"}` (or an empty value for "everything")
moves the **device-local** seen watermark forward and answers with the new `unread_missed`. The
watermark never replicates and never moves backwards. `monitor.html` calls it once when the page
opens so the missed badge clears.

## Web call information

`GET /api/panel/call-info` returns `webrtc` connection data and a `doors` map containing
`extension`, `station`, `online`, and optional media/profile fields. An empty `station` means this
node owns the door. The SIP password is resolved in memory from secure storage for this
authenticated response; configuration must use a secret reference and must never embed the value
in `boot.json`, URLs, events, or logs.

## Web Push extension

Legacy polling remains mandatory. Modern HTTPS/localhost clients may use:

- `GET /api/panel/push-vapid-public-key`;
- `POST /api/panel/push-subscription` with the PushSubscription JSON, panel page, and group;
- `DELETE /api/panel/push-subscription` with the exact endpoint to remove.

An unavailable endpoint (404/501) is unsupported, not subscribed. Notification URLs must be
same-origin `/panel/` paths. A typical create body is
`{"subscription":<PushSubscription.toJSON()>,"page":"/panel/monitor","group":"guards"}`.
The page obtains `group` from `?group=<name>` and uses the same persisted value for
`GET /api/panel/state?group=<name>`; the default group is `all`.

Core normalizes the subscription, then seals its complete `endpoint`, `p256dh`, and `auth` values
as one schema-v2 CRDT record using XChaCha20-Poly1305 and a mesh-PSK-derived key. Configuration and
exports never expose those values in plaintext. At startup, a legacy raw record is resealed when
possible or removed fail-closed; operators must re-subscribe if migration removes it. Core opens a
record only in bounded memory when subscription operations or provider delivery require it;
deletion derives the record key from the submitted exact endpoint. Endpoint and key bytes remain
opaque and round-trip losslessly inside that sealed boundary.

## Personalization, language, and assets

State may include:

- `doors[].visitor_lang` and press-event `purpose`/`visitor_lang` badges;
- ordered `purposes[]` entries with `id`, `icon`, `order`, and labels by language;
- `languages[]`, sourced from `ui.languages`.

`POST /api/panel/visitor-lang` takes form field `lang` and optional `door`; authentication comes
only from the HttpOnly panel session. The language returns to the primary language after the
configured inactivity interval. `GET /api/panel/i18n` returns
`languages` and `i18n_overrides`; lookup order is override, built-in string, then key.

`GET /asset/<sha256>` serves immutable content-addressed UI/audio assets without a panel or admin
session on the trusted media LAN. Public access applies only to an exact GET path containing a
64-digit lowercase SHA-256; other methods and asset-shaped paths remain behind the session gate.
Native shells may use Core's verified local path or the clean loopback asset URL without a query
credential.

Native UI events may include resolved theme paths, alarm/reply/chime audio paths,
`visitor_lang`, and `asset_ready`. A null local path means the asset is not cached and must not be
reported as ready.

## Web semantic UI

Panel state includes `web_ui.device_id`, the serving node's built-in schema-v1
`web_ui.manifest`, and effective override objects from
`devices.<device_id>.local.ui.elements`. This manifest is intentionally distinct from the native
top-level `ui_manifest` and currently covers `call.primary`, `cancel.call`, `call.end`,
`purpose.button`, `ring.title`, `ring.action`, `status.offline`, `reply.button`, `monitor.close`,
and `sos.trigger`. The SOS entry
styles both the two-second hold control and the safe baseline of its full-screen presentation;
valid rule-projected presentation colors temporarily take precedence. Pages validate the manifest,
minimum 44 effective-pixel controls, contrast, and declared properties; invalid updates retain a
last-known-good style. They post `/api/panel/ui-report` only after an actual renderer applies or
rejects the style.

`sos.cancel` is intentionally absent from the Web contract: a panel session may raise SOS but is
not authorized to clear replicated emergency state. Kiosk PIN and authenticated Admin controls
retain that safety action.

The Web manifest is local to the serving Core node and is not replicated as a per-peer Web
catalog. Admin cannot infer or edit a remote/offline Web surface from a native peer manifest.

## Legacy client behavior

Both legacy pages poll every two seconds and keep retrying after showing an offline banner on five
consecutive failures. `door.html` may self-refresh after five minutes; `monitor.html` must not,
because refresh loses its user-granted audio state. `?mock=1` bypasses XHR and exercises the same
renderer with built-in data.
