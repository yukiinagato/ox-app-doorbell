# Durable operations API

`operations_v1` advertises the Core prepare/execute/query protocol. It does not
advertise an updated platform UI, actuator acknowledgement, or physical
exactly-once execution. Existing shells migrate separately; their old one-shot
entry points remain available for the compatibility cycle.

## Authority and permission configuration

Configure `doors.<door>.operations.authority_node` for each unlock target and
`cluster.operations.sos_authority_node` for global SOS. Values are existing
32-character lowercase-hex node IDs. A missing, disconnected, or unsupported
fixed authority fails closed. The page node never substitutes itself or an
elected survivor. Authority changes require manual reconciliation of outstanding
operations before reassignment; partition failover is unsupported.

Every initiating native node or HTTP page node needs explicit grants:

```json
{"doors":["front"],"sos_start":true,"sos_clear":false}
```

Store this object at `devices.<node>.operations`. Missing fields mean no grant;
a door grant does not grant SOS. At most 64 distinct door IDs are accepted.
Door IDs use 1–128 ASCII letters, digits, `_` or `-`. Unknown fields, duplicate
fields/doors, invalid node IDs and non-boolean SOS flags are rejected, including
whole-device/container writes carrying an embedded operations object. Grants
and authority bindings persist and replicate as existing versioned configuration.

Administrative HTTP calls require a current administrator session. POST also requires a nonempty
`X-Doorbell-CSRF` token from login/session and an allowed exact Origin. The page
node repeats these checks on the state loop. Native calls derive their principal
from their local node. Authenticated mesh forwarding derives the node from the
SecureChannel peer, preserves the authentication type and credential/grant
versions, and the authority independently checks its current versions and grants.
An `admin` assertion cannot bypass a device grant. A native node cannot query or
execute another principal's handle; an authorized administrator can query a
record only while retaining the recorded target's permission. Execute remains
creator-only. Client JSON cannot select a principal or privileges. Web SOS additionally accepts a current `dbpanel` session, only for `sos_start`.
Prepare/execute require its own CSRF token and exact trusted Origin. Query also
requires its CSRF token; a supplied Origin must be trusted, while an absent
Origin is allowed for same-origin browser GET requests. A valid panel CSRF
selects the panel principal even when the browser also has an administrator
cookie. The principal combines the authenticated page node with a server-derived
hash of that one session. Only that session can execute or query the handle;
shared bearer credentials alone cannot use this adapter. The page checks session
expiry and its bound credential on every request. The authority independently
checks replicated panel credential metadata and the page node's explicit SOS
grant. A partition cannot enforce a revocation it has not received. These are
session identities, not independently provisioned panels or SIP accounts; those
remain the separate panel identity feature.

## Requests

Prepare: `POST /api/operations/prepare` with:

```json
{"schema_version":2,"action":"door_open","door":"front","parameters":{}}
```

Actions are `door_open`, `sos_start`, and `sos_clear`. SOS has no door. Parameters
are currently an empty object, or omitted. `request_id`, when supplied, is
32 lowercase hex characters and correlates one request attempt only. The server
creates a random request ID when omitted. Prepare returns a fresh random
`operation_id`, fixed `authority_node`, `config_generation`, state `prepared`,
and `prepared_remaining_ms` up to 30000. Preparing again creates another intent;
never automatically prepare again after a lost write response.

Execute: `POST /api/operations/<operation_id>/execute` with the same action, door
and empty parameters plus the returned `operation_id` and `authority_node`.
Query: `GET /api/operations/<operation_id>?authority_node=<node>&action=door_open&door=front`.
For SOS, omit `door`. The scope fields are routing hints and are checked against
the persisted intent and current permission before any details are returned.
Unknown/duplicate fields and bodies over 8 KiB are rejected. Query accepts only
`authority_node`, `action`, optional `door`, and optional `request_id`.

The additive native entry points are
`db_core_operation_prepare_json_v2`, `db_core_operation_execute_json_v2`, and
`db_core_operation_query_json_v2`. They accept the same JSON object; query also
supplies the operation and authority IDs. Returned strings belong to the caller
and are released with `db_free`. Invoke on a worker: calls wait at most four
seconds and reject execution on the Core state-loop thread. No public platform
struct layout changes.

## Results and boundaries

Responses have `schema_version:2`, `request_id`, `ok`, and `retry_mode`. Known
records include `operation_id`, `authority_node`, `execution_state`, and the
opaque `config_generation` shared with configuration snapshots. No target,
credential digest, grant version, or secret is returned. Query returns HTTP 200;
accepted/dispatching/dispatched/unknown execute results return 202. Transport
status never proves that a door opened.

- `prepared`: execute the same handle before its original 30-second deadline.
- `dispatched`: one durable dispatch acquisition admitted an adapter send;
  `unknown_reason:ack_unavailable` explicitly records the lack of actuator proof.
- `unknown_after_dispatch`: never resend the adapter operation; query the same
  handle. A crash/ambiguous send may have occurred.
- Unstarted terminal states preserve the fact that no dispatch acquisition ran.
  An explicit new user intent may prepare a new handle.

Missing/expired authentication returns 401 `auth_required`; forbidden access
403 `permission_denied`; changed configuration 409 `config_conflict`; differing
parameters 409 `idempotency_conflict`; invalid schema 400 `invalid_request`;
unsupported peer/protocol 501 `unsupported_capability`; unknown ID 404
`operation_not_found`; unavailable authority 503 `authority_unavailable`.
Body overflow is 413 `capacity_exceeded`; worker/ledger capacity is 503. A queued
request that cannot begin returns 503 `not_started`. A begun request without a
reply returns 503 `outcome_unknown`. The latter is never an invitation to prepare
a replacement. Storage failures are explicit 503 `storage_error` or
`storage_unavailable`; a queried durable state remains the recovery source.

At most 32 local HTTP/native waiters and 32 outgoing mesh requests are retained,
with a four-second deadline. Queue-start qualification and expiry use the same
mutex. Waiting happens on workers; mesh replies run asynchronously on the state
loop. Shutdown cancels queued work and wakes waiters before HTTP workers join.
Posted requests own their data and cannot access a destroyed Node on a surviving
borrowed loop. No HTTP connection or caller stack escapes into a callback.

Only the configured authority acquires the Store dispatch transaction. New door
operations directly enqueue one bounded MQTT packet containing operation and
authority IDs. They do not append replayable `dtmf_action` events. The target's
command and a digest of the broker host/port/topic binding are frozen; the active
adapter must match that binding. The authority must also be the active MQTT
bridge under the existing bridge policy, otherwise dispatch is refused. New
operation enqueue requires a connected client and fewer than 256 queued packets
and 1 MiB of queued packet bytes. These bounds apply to new operation admission;
the legacy MQTT queue is unchanged. Queue admission is neither broker ACK nor
physical evidence. MQTT delivery and an actuator without operation deduplication
cannot provide end-to-end exactly-once execution.

SOS dispatch durably appends one event carrying the operation/authority IDs.
Retries cannot append another intent. Its `dispatched` state acknowledges this
local event submission only; it does not prove remote alert delivery or an
actuator acknowledgement. T07 covers adapter evidence; T12/T36 cover SOS/UI
migration and the visible unknown states.

## Compatibility callers

Old door/SOS C ABI methods, current native shells, old HTTP endpoints, SIP feature
codes and automatic rules retain their existing one-shot best-effort behavior.
They have no stable operation ID, do not deduplicate independent invocations,
and must not retry unknown outcomes automatically. The T06 caller map records
these remaining callers and their migration owners. The new capability covers
only the tested versioned routes and ABI, not these older paths.
