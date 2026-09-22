# Staged configuration import

Imports use the existing administrator authentication, configuration validator,
LWW map and SQLite transaction. They do not enlarge the ordinary 256-operation
batch limit. No client-supplied filesystem path is accepted.

All five operations are `POST /api/config/import/{stage,preflight,commit,cancel,query}`.
Each requires a current administrator session, trusted Origin and
`X-Doorbell-CSRF`. The additive native entry point
`db_core_config_import_json_v2` requires that same session and CSRF value; its
owned JSON result must be released with `db_free`. A stage token is not an
authentication credential.

Stage accepts:

```json
{
  "schema_version": 2,
  "expected_revision": "opaque revision from the administrator snapshot",
  "document": {"schema_version": 2, "config": {}}
}
```

`config` is the complete desired mutable configuration. Missing fields are
removed; unknown fields present in the document are retained if valid. Obtain
the starting document from the administrator snapshot, which omits credential
digests. The existing `admin` configuration is preserved: imports cannot change
it or restore password digests. Schema versions other than 2, duplicate object
members, reserved journal keys and malformed documents are rejected. Legacy
file formats must be explicitly converted by the caller before staging; the
old `/api/config/import` route retains its compatibility behavior and limit.

Successful staging returns `stage_token`, `digest`, `expected_revision` and
`expires_in_ms`. The token has 128 random bits. The SHA-256 digest covers the
exact uploaded stage request bytes, including the document and its envelope.
The stage binds the current administrator credential identity, initiating
session, authority boot, revision and a fixed ten-minute monotonic expiry.
Only one stage exists for the shared administrator principal. Preflight does
not renew it. Cancel, expiry and successful commit release its memory; restart
invalidates it. The original user file is never changed.

Preflight and cancel accept
`{schema_version:2,stage_token,digest}`. Commit additionally requires a stable
`operation_id`, 32 lowercase hexadecimal characters representing 128 random
bits. Every operation rechecks authentication. Another session cannot use an
active stage even when it knows the token. An intervening configuration edit
returns `config_conflict`; fetch a fresh snapshot and review a new stage.

Preflight does not change live configuration. It reports every changed field
as an escaped JSON Pointer with before/after existence and scrubbed values,
the expanded mutation count, validation problems, missing `secret:` references
and missing local assets. It returns `can_commit:false` for any unresolved
dependency or validation failure. Secure storage values and asset bytes are
restored separately through their existing platform services. Ordinary JSON
export is not a complete disaster recovery backup. Commit repeats preflight,
including checking that referenced secrets and assets still exist.

Admission ceilings are 4 MiB for the complete stage request, nesting depth 16
within `config`, 65,536 parsed nodes, 4,096 changed leaf replacements/deletions
and 4,096 physical CRDT mutations. Arrays are one replacement because they have
no stable field identity. Existing CRDT child records are reconciled in that
same transaction. Per-device UI overrides still pass the semantic element
validator; importing a container cannot bypass its constraints.

Imports record one whole-entity intent per changed entity. They retain the
[conflict journal](config-conflicts.md) limits, including 64 KiB per record and
the aggregate history budget. An unresolved conflict or journal capacity
failure blocks the import explicitly; the 4 MiB input ceiling does not promise
that every document fits the retained-history budget. Preflight exposes these
problems before commit. Device memory and maximum-size hardware qualification
remain separate release gates.

Configuration, edit records and the successful operation receipt commit in
one local SQLite transaction. Memory publication and replication follow durable
success. Failure publishes no partial import. Crash recovery yields the old or
new transaction. This is local persistence atomicity, not a simultaneous switch
across the cluster; peers converge using the existing replication status.

The receipt contains the upload digest, token digest, administrator credential
identity and original result, including `committed_revision`. The same operation
ID, token and digest return exactly that result without another write, including
after restart and fresh authentication with the same administrator credential.
The returned revision describes the original commit; it is not a fresh snapshot.
A mismatched ID binding returns `operation_conflict`. Credential replacement
invalidates that access. Receipts are not silently evicted: 128 durable receipts
per node are retained, and further imports fail with `receipt_capacity_exceeded`.
There is no automatic retry, replay or destructive receipt cleanup.

Query accepts the same envelope as commit, but only reads a receipt. A successful
query returns `{ok:true,schema_version:2,state:"committed",result:<original result>}`.
An unknown operation returns `operation_not_found`; query never executes an
active stage. It supports fresh authentication after restart under the same
administrator credential. A missing response is not proof of success or failure.
Persisted receipts are strictly validated; invalid metadata fails closed with
`receipt_store_invalid`. Preflight reports invalid or full receipt storage before
commit. Cancellation remains available even when receipt storage is invalid.
