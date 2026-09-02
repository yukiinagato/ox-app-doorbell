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
