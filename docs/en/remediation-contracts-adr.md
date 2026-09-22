# ADR: Shared remediation contracts, version 1

Date: 2026-09-22. Status: accepted in T02 contract review; implementation and
target qualification gates remain open.

This document freezes the intended interface for the remediation plan. It does
not describe implemented features. The implementation inventory is
`verification/remediation-q01-q18/T02/existing-symbol-map.json`; the base revision
is `b26e0d346df99f2879915241b6e98d8ef1aa0707` plus the recorded incoming dirty tree.
T02 changes documentation and protocol examples only. Existing endpoints,
capabilities and applications must not claim these guarantees until their
implementation tasks and target qualification pass.

## C01: Authority and compatibility

Core owns authorization, call state, expiration and configuration validation.
Preserve `db_platform_v2` size/version negotiation and every legacy ABI layout,
ownership and calling convention. New JSON result entry points may be added;
existing integer results and caller-owned/free rules retain their meanings.
Unrecognized optional response fields are ignored by readers and preserved by
configuration editors. Unknown versions, action types or security-critical
request fields are rejected, never interpreted as permission.

Do not change existing call identity: `call_id`, `stage_revision`,
`dialog_owner` and publisher identity have distinct purposes. A monitor is not a
call owner. An answer loser cannot terminate the winner; Ignore is local;
visitor cancellation remains an idempotent global operation constrained by the
existing in-call rules. Preserve recovery windows, SOS clear semantics and the
valid zero-recipient SOS configuration. Keep `ios-legacy` frozen.

Add the following measured/implemented feature entries through existing Core
capability projection: `operations_v1`, `admin_sessions_v2`,
`web_request_lanes_v1`, `media_publish_v1`, `config_cas_v1`,
`config_conflicts_v1`, `config_import_v1`, `panel_identity_v1`.
Each is an object `{version: 1, supported: boolean, limits: object}`. Missing,
false or unknown version means unsupported. The server enforces capabilities;
clients cannot grant themselves a feature. Do not advertise one from build
flags, an SDK version, or a successful local camera preview.

All supported shells consume the same Core contracts: Android modern/API19;
modern iOS/iOS9 arm64/tvOS shared Swift; iOS5/iOS9 armv7 shared Objective-C;
Windows x86/x64; and supported Web runtimes. Physical device and memory
qualification remain separate per target. Documentation-only changes do not
bump application versions; implementation and bundled-resource changes do.

## C02: Common envelope and field rules

Versioned JSON responses preserve existing `ok` and `err` where present and add
`schema_version: 2`. The new authoritative fields are below. Integers must be
exact, finite JSON integers; millisecond durations are nonnegative and bounded
by the relevant limit. IDs are opaque, case-sensitive strings, never bearers.
No field contains a password, long-lived token, key, credential URL or raw
secret. Unknown result means unknown, not physical failure or success.

| Field | Type, bound and default | Meaning and lifetime |
|---|---|---|
| `request_id` | 32 lowercase hex characters; server generates if absent | Correlation for one request attempt; no deduplication or authority |
| `operation_id` | 32 lowercase hex characters from 16 secure random bytes; required after prepare | Stable identity of one user intent; authority-local durable lookup |
| `authority_node` | Existing validated node ID; required for an operation | Fixed executor of that handle; never selected by HTTP retry |
| `execution_state` | Enum in C04; required for operation results | Durable state, not inferred from transport status |
| `error_code` | Enumerated protocol error; absent on successful response | Machine-readable reason; `err` remains a compatibility projection |
| `retry_mode` | `none`, `same_operation_query`, `same_operation_execute`, `new_prepare`; default `none` | Advice only; every retry is reauthorized |
| `unknown_reason` | `response_lost`, `crash_during_dispatch`, `transport_ambiguous`, `ack_unavailable`; absent otherwise | Bounded explanation, no raw transport/secret data |
| `config_generation` | Opaque local revision string, maximum 256 bytes | Authority snapshot binding; not a global commit number |
| `credential_version` | Exact persisted LWW tuple `{hlc, author, seq}`; server-only in sessions | Bound to the credential record atomically, not a per-node counter |

`hlc` and `author` use the existing LWW encodings. `seq` is an unsigned decimal
string in new JSON to avoid JavaScript precision loss; storage retains its
existing integer representation. Clients compare opaque versions for equality,
not recency. Do not expose password hashes through a version field.

`config_generation` and `expected_revision` use the same opaque token for the
same authority's complete configuration snapshot. It includes a node-local
boot/restore epoch and revision identity; a restart or restore invalidates old
tokens even when values match. No ordering or cross-node equality is promised.
Editors retain drafts and reacquire a new base after invalidation. Operations
store the token used for preparation; it cannot silently be replaced at execute.
Replicated conflict parents use LWW record identities, not this boot-local token.

| Situation | HTTP / error | Retry and UI meaning |
|---|---|---|
| Known query result | 200 | Render its execution state; no implied physical success |
| Accepted/running operation | 202 | `same_operation_query` |
| Missing/expired session | 401 / `auth_required` | `none`; stop privileged retries |
| Authenticated but forbidden | 403 / `permission_denied` | `none` |
| Stale owner or ended call | 409 / `stale_owner` or `call_ended` | Retire only the exact old session |
| Changed config or same ID/different parameters | 409 / `config_conflict` or `idempotency_conflict` | No unconditional retry |
| Invalid schema/unknown critical field | 400 / `invalid_request` | `none` |
| Unsupported safe protocol | 501 / `unsupported_capability` | Upgrade/configure; no unsafe fallback |
| Body/item capacity | 413 / `capacity_exceeded` | Show the limit; do not split into live partial writes |
| Full operation/auth/worker capacity | 503 / `capacity_exceeded` | No extra admission; show bounded recovery |
| Unknown handle | 404 / `operation_not_found` | Query cannot recreate it; execute never prepares |
| Missing configuration baseline | 400 / `revision_required` | Reload/compare without discarding the draft |
| Missing or unreachable fixed authority | 503 / `authority_unavailable` | No substitute executor |
| Proven queued expiry | 503 / `not_started` | Retry policy depends on whether a valid prepared handle remains |
| Running request loses its response | 202, or 503 / `outcome_unknown` when no result is available | Query the original operation; never create a replacement automatically |

Browser timeout, network failure, abort and parse failure are local errors.
For a write they mean unknown unless the server has returned a verifiable
`not_started` result. Redaction applies to errors and diagnostics as well as logs.

Cookie-authenticated mutations require a session-bound random CSRF token in a
header and an exact configured Origin allowlist check; missing/null/untrusted
Origin fails closed for the new Web mutation routes. Non-browser authenticated
native/mesh requests use their own explicit principal and do not bypass
authorization by omitting Origin. SameSite alone is insufficient. Proxies are
trusted only by explicit deployment configuration; arbitrary X-Forwarded
headers never establish Origin, authority or identity. No wildcard credentialed
CORS and no CSRF/token values in URLs, events or diagnostic bundles.

## C03: HTTP scheduling

The scheduling state is `QUEUED -> RUNNING -> COMPLETED` or
`QUEUED -> EXPIRED`. Deadline validation and transition share one lock or atomic
decision. Only winning `QUEUED -> EXPIRED` proves `not_started`. Expired work can
never run. Running work cannot be generically undone by HTTP timeout.

Retain the existing 5000 ms wait ceiling. Own the request and completion context;
never retain HTTP stack references or use a connection after its handler exits.
Completion, shutdown and expiry settle once. Forwarded network work never waits
synchronously on the Core loop. Scheduling state is separate from durable
operation state; an expired query does not cancel its operation.

## C04: Prepare, execute, query and physical evidence

Reserve versioned routes `POST /api/operations/prepare`,
`POST /api/operations/<operation_id>/execute` and
`GET /api/operations/<operation_id>`. They are not present in the current build.
New native JSON ABI adapters must delegate to the same Core functions and free
results through the established ABI ownership convention.

Prepare accepts `{schema_version:2, action, door?, parameters}`. Actions are
`door_open`, `sos_start` and `sos_clear`; an unknown action is rejected. `door`
is required only for `door_open`, uses the existing validated door ID and cannot
be an arbitrary address. SOS remains cluster-global and omits `door`; a supplied
door on an SOS request is rejected rather than silently narrowing its scope.
Version 1 uses the empty parameter object for these three actions. Source/via,
unlock command and SOS projection are derived from authenticated Core state and
configuration, not caller parameters. Future parameter schemas require an ADR
amendment; the capacity below is not permission to pass arbitrary parameters.
Parameters are a validated object of at most 4096 encoded UTF-8 bytes, maximum
depth 8. Core resolves the action, permissions, current config and the exact
authority; canonical typed parameters are frozen in the record. The fingerprint
is a SHA-256 of that canonical representation; a caller-supplied fingerprint
never replaces validation. Unknown critical parameters are rejected.

Prepare returns a handle and `prepared_remaining_ms`, at most 30000 ms. It has no
physical effect, no extra confirmation wait and no prefetch on application
startup. A lost prepare response can leave only a bounded expiring record.
Execute carries the same operation and immutable parameters (or references the
already frozen parameters with no replacement). Repeated execution with identical
parameters returns the existing state; differing parameters return conflict.
Its body is either `{schema_version:2}` alone or the complete original prepare
body; partial replacements and unrecognized fields return `invalid_request`.
Unknown/removed/expired IDs cannot be created or revived by execute.

The new persistent authority binding is
`doors.<id>.operations.authority_node`, administered through the same validated
configuration service. It covers door-open actions. Global SOS uses the separate
`cluster.operations.sos_authority_node` binding and retains the current global
emergency event and presentation/recipient rules, including deployments without
any door. Missing or
ambiguous authority disables the new protocol with `authority_unavailable`;
there is no implicit MQTT-leader or failover executor. Cluster/global SOS must
resolve that global authority without selecting a door. Existing legacy SOS
remains available under its documented weaker contract until the new capability
is commissioned. Changing authority requires the old authority to be quiesced
and outstanding operations reconciled. Partitioned failover is not supported;
do not change authority merely because it cannot be reached.

Bind each record to authenticated principal, door or global scope, action, authority,
parameters/fingerprint, credential/grant version, config generation, boot
generation, creation/acceptance times and finite result. Principal is derived
at the server from the session/native registration/authenticated mesh hop;
request JSON cannot select it. Prepare, execute and query all require current
door/action permissions, or the existing global SOS start/clear permission for
global SOS. A door grant cannot imply global SOS-clear permission.
Query is allowed to the creating principal and an
authorized administrator; merely knowing the ID grants nothing. Execute
revalidates permissions and target configuration. Configuration or grant changes
reject an unstarted record; they never retarget it to a different lock.

States are `prepared -> accepted -> dispatching -> dispatched -> actuator_ack`.
Unstarted terminal states are `rejected_not_started`, `expired_not_started`,
`failed_before_dispatch`. Ambiguous dispatch becomes `unknown_after_dispatch`.
Dispatch acquisition and its necessary local side-effect intent must be durable
in one Store transaction before external I/O. Only one acquisition per ID is
allowed. Restart invalidates prepared records. Accepted records with durable
proof that no dispatch acquisition occurred resolve as `failed_before_dispatch`;
dispatching or uncertain records become unknown and are never automatically
resent. A user can explicitly prepare a new intent after a proven unstarted
failure. Monotonic deadlines from an old
boot are never reused or extended.

`dispatched` means the adapter accepted a send, not that a door opened.
An authenticated actuator ACK must match operation, authority and configured
actuator; it is separately recorded as `actuator_ack`. A delayed valid ACK can
resolve an unknown result without resending. Sensor observations are separate
`{state, observed_at_ms, operation_id?}` evidence; an uncorrelated sensor change
does not prove causality. Without operation-aware actuator deduplication, MQTT
redelivery prevents an end-to-end exactly-once guarantee. Never advertise one.

Limits: 128 prepared records and 2048 accepted/active/unresolved-unknown records
per authority. Retain terminal query results at least 24 hours; unresolved
unknowns are never silently evicted. Each result is at most 4096 bytes; query
pages contain at most 32 rows. Across all states, reserve at most 4096 rows and
48 MiB of logical record payload, reserving 12 KiB per admitted record for up to
4 KiB each of parameters, result and metadata. Reject new prepare before either
reservation limit would be exceeded. A terminal transition consumes its existing
reservation, not a new slot. Reclaim only terminal records older than 24 hours;
no eviction of younger completed/expired records to admit traffic. Physical
SQLite/WAL overhead, checkpointing and no-space behavior need T05/target tests;
the logical byte ceiling is not a claimed total database-file size.
Store rows on disk; do not load the entire ledger
into memory. At capacity reject new prepare explicitly, preserving existing
queries and control paths. Old one-shot ABI endpoints retain their legacy
best-effort semantics and may safely adapt to one internal prepare/execute only
after implementation. They cannot deduplicate independent legacy invocations or
automatically retry uncertain writes. New supported UIs migrate in T36; legacy
entry points remain explicitly listed as weaker until migrated.

SOS preparation must remain immediately accessible. Failure to prepare or
reach authority shows an unsent/unknown state and available alternative help;
it must not invent delivery, silently clear an active SOS, or retry with new IDs.

## C05: Administrator and panel sessions

Bind administrator sessions to the entire current `admin.password_hash` LWW
record version in the same serialized snapshot as the credential. Check on each
request against the latest locally known version. Apply invalidation to local
changes, remote synchronization and configuration restoration. Idle expiry is
30 minutes of interactive activity; absolute lifetime is 8 hours; capacity is
64. Polls/heartbeats do not refresh interaction. Expire first, then evict the
least recently interactive/oldest session, excluding the token just issued.
Keep tokens in memory; restart invalidates all of them. Never persist a new
session token as an accidental consequence of ledger persistence.
The current separate metadata/config transactions do not already make credential
updates atomic; T08 must give the credential plus record version one durable
commit boundary and test rollback/restore before advertising this capability.

A partitioned node can continue using its locally known credential. On learning
a changed record it rejects old sessions immediately. Token expiry alone does
not prevent repeated login with an isolated node's old password. Report
revocation pending propagation; do not promise instantaneous global revocation.
Strict offline revocation would require a separately approved online authority
and an explicit loss of offline administration.

Panel identity, short-lived Web session, call ownership and media lease are
distinct. T31 allocates a random `panel_id`, binds explicit door/action grants,
and uses existing panel credential generation/references for session invalidation.
Panel IDs are at most 64 ASCII characters and never derived from IP or UA.
Legacy shared credentials remain `legacy_shared`; per-device revocation is not
claimed. An independently usable SIP identity requires real PBX provisioning;
without it report `provisioning_required`, not an invented extension.

New identity-bound panel Web sessions use an in-memory random 128-bit token,
30-minute interactive idle expiry, 8-hour absolute expiry and a capacity of 128.
Only explicit user interaction refreshes idle time; background polling does
not. Expire/evict as for admin sessions, protecting the newly issued token.
Restart, identity/grant revocation and observed credential-version changes
invalidate the session. Renewal requires authenticated panel identity bootstrap
(platform secure storage/local Core or user login), never the old cookie alone
after its expiry. Do not put long-lived identity credentials in browser URLs.
Tokens/CSRF values are opaque secrets; diagnostic and protocol example outputs
must redact them. Existing legacy shared sessions remain explicitly weaker until
T31 migrates their callers; missing identity cannot become a privileged default.

## C06: Independent requests and Core time

| Request lane | Period | Deadline | In-flight limit |
|---|---:|---:|---:|
| state | 1000 ms | 3000 ms | 1 |
| call-info | 5000 ms | 4000 ms | 1 |
| locale | language change only | 4000 ms | 1 |
| SOS write | user intent | 4000 ms | 1 per operation |
| heartbeat | 2000 ms | 1500 ms | 1 |

Each lane owns its timer, generation and settle-once cancellation. A timed-out
old callback cannot mutate a new lane/call. Use the existing compatible request
layer for old browsers, including an actually configured timeout. Keep the
existing server owner lease at 10000 ms. Network/5xx retries use 500/1000/2000 ms
backoff only inside the remaining lease. Explicit stale owner, ended call or
revoked authorization retires only that old session. No endless lease extension.

Reuse the already introduced `active_calls`, `server_now_ms`, `remaining_ms` and
`expires_at_ms` snapshots; do not create a second countdown API. Wall fields
are Core-corrected Unix milliseconds, never client OS wall time. Add
`lease_remaining_ms` (0..10000) to authoritative heartbeat results, bound to
call/revision/owner. Estimate expiry conservatively from the request's monotonic
start plus server remaining duration; arrival never grants a fresh full lease.
After a client/authority restart or foreground return, reacquire a snapshot.
Background browsers are not promised indefinite ownership. Stale state does
not automatically clear an active SOS.

## C07: Media authorization and transport

Publish authorization binds authenticated principal, door, `call_id`,
`stage_revision`, `dialog_owner`, `media_generation` and expiry. Add a random
128-bit `media_generation` encoded as 32 lowercase hex characters and a strictly increasing decimal-string
`frame_sequence` starting at 1, at most 9223372036854775807 (19 digits), for that
generation. No leading zeros, signs, exponents or wrap/reuse; renew the
generation instead. Publication metadata is transient and never a CRDT event.
Core derives principal and owner from authenticated state. Missing identity
fields reject upload. End/revoke invalidates the generation and its cached
frames immediately; revalidate again just before the final frame-bus write.
The server-derived publisher is the authenticated panel identity or native
node/call binding, not a request-selected panel ID. Authorizations are
in-memory, expire within 10000 ms and never outlive the current owner lease or
Web session. Return `publish_remaining_ms` as an integer 0..10000. Renewal
reauthorizes the exact tuple and returns a new generation; old generations
cannot be revived. Authority restart, call/revision/owner change or explicit
revocation clears the authorization and frame cache. A late frame never renews
a lease. Clients estimate this duration from monotonic request start, like C06.

The browser uses relative same-origin URLs. Core resolves peers from trusted
configuration; arbitrary upload/proxy URLs, redirect-based retargeting,
forwarded browser Cookies and long-lived credentials are forbidden.
The current PSK-authenticated encrypted SecureChannel is a reusable primitive,
not an already safe media transport: it currently runs crypto/callbacks on the
Core Runloop and has an unbounded pending queue.
Existing SNAP is limited to 300 KiB/5000 ms and drops oversized JPEGs; BLOB is
limited to 3 MiB with 256 KiB chunks/10000 ms. They are not the new 1 MiB/3000 ms
media protocol, nor a ready-made 4 MiB import transport. Preserve those old
limits and version the new lane instead of silently raising shared limits.

T16 must implement a separate bounded media execution context using that
existing authenticated encryption primitive, not the CRDT/event channel.
Control-loop checks issue generation-bound authority snapshots; workers own
network/crypto buffers; the final Core-loop check rejects stale snapshots.
The trusted peer connection authenticates each hop and maps a delegated principal
only from the authenticated originating node's validated authorization. A
browser-supplied identity is never accepted as delegation. Until that binding,
worker ownership, shutdown and queue bounds pass review/tests, cross-node
`media_publish_v1` stays unsupported (`DESIGN_BLOCKED` for that transport lane).
There is no bare-HTTP or public upload fallback.

Maximum encoded frame: 1 MiB; decoded pixels: 307200; either dimension: 1024.
Validate length and JPEG dimensions before allocation/decode, with a strict
request-reader bound. The current 8 MiB HTTP/TCP thresholds do not already
provide this rejection behavior. Per publisher: one in-flight plus one latest
pending frame, replacing older pending data. Per node: at most 8 authorizations,
one media worker, 2 MiB aggregate encoded frame queue and 2 frames/second per
publisher. Admission respects both global and per-publisher limits; full queues
drop superseded frames or reject, never grow. Network deadline: 3000 ms.
Keep media buffers separate from control/SOS capacity. Targets may advertise a
lower measured limit; unsupported targets must not advertise publication.

UI states are `local_capture_ready`, `sending`, `remote_core_accepted`,
`interrupted`. None means the remote screen displayed the frame. A future
render ACK must match the same generation/sequence before strengthening that
claim. Local preview is not end-to-end media evidence.

## C08: Configuration CAS, conflicts and import

Add `expected_revision`, an opaque at-most-256-byte local revision, to the common
configuration mutation service. Snapshot, compare, merge, validate and commit
occur in one serialized Store transaction, followed by memory publication and
events only after success. Missing revision on new endpoints returns
`revision_required`; existing explicitly legacy single-write endpoints retain
their documented weaker behavior until migrated. No default current revision.

Three-way merge uses base/mine/current and preserves unknown fields. Missing,
null and deletion are distinct. Arrays without stable identity conflict as
whole arrays. Local CAS is not cluster consensus. Reuse existing LWW transport
and add durable authenticated conflict intent records atomically with each local
edit: random 128-bit `change_id` encoded as 32 lowercase hex characters, parent version(s), author node, changed field
paths and non-secret candidate values. Bound a record to 64 KiB, 256 changed
fields and 2 parent LWW record versions per changed field. The parent versions
use the C02 `{hlc, author, seq}` encoding and survive restart; absent parents mean
the field was absent in the observed base, not permission to overwrite it.
Secret fields retain only references/version/conflict
metadata, never plaintext candidates. Persist unresolved conflicts; at capacity
reject new affected writes rather than silently lose recoverable intent.
T28 must define a bounded storage/index implementation before advertising
`config_conflicts_v1`; current winner-only LWW is insufficient. Reconnection
may select an effective LWW value while preserving visible unresolved intent.
Only an explicit admin resolution produces a new change referencing both
parents; do not continually auto-write merged values at every peer.

Keep ordinary batch input at 256 entries. Reserve separate staging, preflight
and commit operations for imports; do not feed 4096 items into the old batch
or progressively write chunks into live configuration. Import limits are
4 MiB uploaded bytes, 4096 expanded leaf mutations, maximum nesting depth 16,
one active stage per authenticated admin principal and a 10-minute TTL.
Tokens are 128 random bits, bound to principal, upload digest, authority boot,
base revision and expiry, never bearers by themselves. Restart invalidates
staging; cleanup removes its owned temporary data. Rate/capacity rejection must
preserve active configuration and the user's original import file.

Preflight reports full differences, schema problems, missing secret references
and assets. Commit reauthorizes and compares the same base revision, reuses the
common validator, then commits the whole snapshot atomically at one node.
Crash recovery yields old or new state, never a half-import. This is not a
simultaneous cluster-wide switch. Missing secrets are restored through platform
secure storage; ordinary JSON export is not a complete disaster-recovery backup.
Do not create an ad-hoc encrypted backup format or include plaintext secrets.

## C09: Limits, qualification and ownership

Numeric limits above are protocol admission ceilings, not claims measured on
old hardware. T01 verified actual current reader limits, baseline behavior and
available toolchains, not memory usage of unimplemented ledgers/importers.
Each owning task must demonstrate bounded allocation/storage and behavior at
the limit; target tasks T40-T48 must qualify their applicable runtime. A lower
measured target limit is advertised explicitly and enforced at the server.
If a required target cannot meet the contract, record BLOCKED_ENV or
DESIGN_BLOCKED with its narrow cause; do not raise its minimum OS, remove safety
checks or mark the whole plan complete. Cross-node media and conflict-retention
implementation gates above remain open; T02 review does not satisfy them.

| Definition owner | Fields/behavior frozen here | Consumers |
|---|---|---|
| T04 | HTTP scheduling and `not_started/outcome_unknown` | Every HTTP write |
| T05 | `operation_id`, durable execution states, ledger limits | T06/T07/T12/T36 |
| T06 | Routes, authority binding, principals, CSRF and result envelope | Web/native/HA adapters |
| T07 | Correlated actuator ACK and sensor evidence | Operation UI |
| T08 | Admin credential-version binding and session expiry | Admin Web/native |
| T09/T10 | Request lanes and settle-once behavior | T11/T12/T17/T25 |
| T11 | `lease_remaining_ms` and lease retry semantics | Web call lifecycle |
| T19 | Existing Core time snapshot fields | T21/T22/T23/T24 |
| T15 | Media generation/sequence and authorization tuple | T16/T17/T18 |
| T16 | Media transport and resource ceilings | Publishers/receivers |
| T26 | `expected_revision` and local atomic comparison | T27/T29/T30 |
| T28 | `change_id`, parent versions and retained conflicts | Configuration editors |
| T29 | Import staging/preflight/commit and limits | T30 |
| T31 | `panel_id`, grants and provisioned SIP mapping | T32/T36 |

Changes to these meanings require an ADR amendment and counterexample fixtures;
consumers do not privately redefine the same field. Evidence always includes
full source revision, dirty-file manifests, version/build, toolchain/OS/ABI,
SIP backend, signing state and raw logs. Host, simulated, linked, signed,
installed and device-tested results are distinct. Publishing, deployment,
physical unlocking and real SOS remain separately authorized actions.
