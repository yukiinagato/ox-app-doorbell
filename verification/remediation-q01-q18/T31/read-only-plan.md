# T31 implementation boundary proposal

Status: read-only inventory. T15 has been accepted by the parent; implementation awaits agreement on the shared T16 helper contract. No production changes or tests are claimed here. Source identities are recorded in `inventory-source.json`. Line anchors are observations of that inventory, not durable symbols.

## Existing behavior

- `node.cpp:2355`, `2591–2689`, `10210–10263`: panel sessions bind to one global `panel.token_refs`/`token_generation` set and resolved secure values. Sessions have random tokens, CSRF, 30-minute interactive idle/8-hour absolute lifetimes, and capacity 128. There is no stable independent panel principal or per-door capability. Existing invalidation clears every session and media frame.
- `node.cpp:10720–10790`: legacy door-open and announcement aliases accept the general panel credential. Their authorization must be covered as well as newer operation endpoints.
- `node.cpp:10855–11631`: panel state, call controls, snapshots, SIP configuration and media use generic panel authentication. SIP call-info returns the shared `integrations.webrtc` credential. State/call-info enumerate every configured door.
- `operation_service.inc:46–104`, `238–260`, `335–430`: operations use device grants and authenticated mesh peer authority. Panel SOS currently adds a hashed session subject and a global panel credential version. Independent panel grants must be checked in addition to the hosting device grant, at both the forwarding and authority nodes.
- `node.cpp:2414–2436` and `doorbell_capi.cpp:376–398`: existing platform secure callbacks already provide credential storage. References may be configured/replicated; values must remain local secure-store data. No new credential vault is needed.
- `node.cpp:4961–5029`: native SIP accounts already use `sip.accounts.<id>.user/pass_ref`, with secure lookup and peer mapping. Reuse that account representation for explicit panel mapping; do not invent PBX provisioning.
- `node.cpp:9898–9915`, `httpd.cpp:568–625`: direct camera streams and snapshots have an explicit existing LAN-public policy, and built-in providers bypass normal route handlers. Panel API grants alone cannot make a privacy claim about these public resources.

## Proposed independent record

Proposed location: `panel.identities.<panel_id>`. Allocate a random 128-bit lower-hex ID (within the ADR 64-ASCII maximum). Fields: `credential_ref`, `credential_generation`, `door_scope`, `grants`, `revoked`, and optional `sip_account_id`. New records start with empty grants and scope. Do not interpret an absent identity as the legacy principal.

Proposed grant names: `view`, `call.monitor`, `call.answer`, `call.initiate`, `sos.trigger`, `door.open`, `media.publish`, `notice.write`. A door action requires both its grant and an explicit matching door. Global SOS has an empty door and its own grant. A panel cannot acquire SOS-clear authority from SOS-trigger authority. Existing native/admin clear policy remains unchanged.

Use an explicit `legacy_shared` marker for old global references and sessions. Their weaker shared revocation and shared SIP boundary must be visible in responses and documentation. Per-identity rotation/revocation affects that identity only; a change to A must not eject B. Compare a canonical current single-identity permission representation for `grant_version`; do not hash every panel record together. Include the credential binding separately, with resolved-secret identity kept local and never delegated.

Map explicit `sip_account_id` to the existing account record. Missing account/user/pass_ref/local secure value yields `provisioning_required`. A new identity never falls back to the shared WebRTC SIP user or password. Transport/server configuration can remain shared. Provisioned status must represent an actual configured account, not an invented extension or automatic PBX setup claim.

## Shared T16 interface proposal

A small typed `PanelPrincipal` contains only `panel_id`, `credential_generation`, `grant_version`, and `legacy_shared`. It contains no session, CSRF, credential, secure value, or credential digest.

All helpers run only on the Core loop, return immediately, do no network work, and never refresh interactive idle time:

- `bool panelSessionPrincipal(const std::string& session, PanelPrincipal* out)`: resolve an unexpired session; compare its observed identity, generation, permission version and local secure binding with current state; fail closed on any mismatch. Populate `out` only on success.
- `bool panelSessionAllowed(const std::string& session, const std::string& door, const std::string& grant)`: resolve the principal and check its current grant and door scope.
- `bool panelPrincipalAllowed(const PanelPrincipal& principal, const std::string& door, const std::string& grant)`: verify the delegated principal against this node's current replicated identity, revocation, credential generation and permission version. It does not claim to validate a remote cookie or session lifetime.

The T16 sender performs session checks before admission and before sending. The authenticated receiver checks the actual SecureChannel peer, the server-origin dialog-owner prefix, the current call/revision/owner tuple, bounded delegation lifetime, and `panelPrincipalAllowed` before publishing. Browser fields alone never establish this principal. Remote compatibility for explicit `legacy_shared` remains a coordination decision; it must never become the fallback for absent independent identity.

## Editing ownership

T31 owns new panel record/validator/helper files, existing PanelSession and credential helpers, session bootstrap/identity management, non-media panel route authorization and scoped outputs, panel operation authorization, selective identity-change invalidation, schema/translations, native management entry where applicable, and targeted tests. Existing trusted-local native action APIs retain their separate Core/device trust boundary; an identity-aware management entry must reuse the administrator session/CSRF contract.

T16 (parent) owns MediaAuthorization, mediaAuthorityCurrent, media-authorize/call-frame/peer-frame routes, media RPC/delegation, Httpd reader and TCP/resource limits. T31 does not edit these bodies. The parent adds the shared helper calls at admission and final acceptance. Media cleanup must become selective rather than calling global invalidation for every independent identity edit.

For call-info, T31 owns account selection and door filtering; T16 owns same-origin stream/upload URL routing. For call-lifecycle, T31 only adds current action/scope checks; established T15 owner and lease semantics remain the authority.

## Route coverage and tests

- View: scoped panel state, call history and seen markers, snapshot/proxy/metadata, call-info, incoming/recovery output. Do not leak unrelated call IDs, door configuration, notices, or credentials through filtered top-level objects.
- Call: initiation/purpose/cancel use initiation scope and existing call constraints; monitoring/answer/reply/hangup/lifecycle retain existing call/revision/owner checks plus their explicit grant.
- SOS: panel trigger and durable operation branches require `sos.trigger`; keep clear policy separate.
- Door open: both legacy direct alias and durable operations require `door.open` and exact door scope. Preserve compatibility semantics of the old alias without claiming it has newly gained the durable operation ledger.
- Notices and push subscriptions: prevent a read-only independent panel from mutating shared configuration or another panel's subscription. Scoped notices require `notice.write`; cluster-global notice changes remain administrator-only for new identities. Preserve explicit legacy behavior only as documented compatibility.
- Media: grant permission is additional to T15 current ownership, never a substitute. Receiver checks must include revocation/version visibility.

Required real production tests: readonly direct open/media denial; independent A/B sessions and A-only revocation with an observed peer update; a media-capable nonowner denied; new identity without an independent SIP mapping returns provisioning_required and no shared secret. Add alias, Origin/CSRF, scope-filtering, rotation, secure-store failure, stale operation/delegation, unknown grant and malformed-record boundaries where applicable. Existing panel/operations/media tests remain regression coverage. No physical lock or SOS is exercised.

## Open coordination decisions

1. Explicit legacy-shared remote media policy and its wire identity/version checks.
2. Existing LAN-public direct streams: retain and document the separate policy, or let T16 change its reader authorization. Do not silently claim panel scope protects these resources.
3. Confirm the persisted field/grant names and helper signatures before simultaneous Node edits.

No task acceptance status is changed by this inventory.
