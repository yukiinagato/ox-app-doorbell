# Independent review of T29 production implementation

Initial verdict: **CHANGES_REQUESTED**, reviewed against frozen `green-r3-source` / linked `green-r3-build` (production identical to r2). This review does not self-approve the separate crash tests authored by this reviewer; their evidence is assigned to the parent for independent verification.

## Findings

- **R1 — valid device snapshot rejected (P1):** `config_import_service.inc` reconciles existing child records by projecting from the complete target. A legitimate `devices.<id>.local` physical record plus a separate semantic UI leaf therefore becomes an embedded UI container during import. `configWriteValidEffective` correctly rejects that generated record, so a valid snapshot cannot restore even an unrelated device-name change. The independent real HTTP test seeds both records and reproduces `invalid_write_scope`, rejected commit and unchanged snapshot. The fix should reconcile existing child records against the sanitized physical units (longest covering unit), keeping the final materialization comparison and semantic validation.
- **R2 — imported door announcement misses its event (P2):** whole-entity import emits a `doors` record and may emit a `doors.<id>` reconciliation record; `onConfigChanges` only schedules `notice_changed` for a `.notice` leaf. A newly restored announcement commits successfully but publishes no notice event. The independent real HTTP test observed zero events where the existing announcement contract requires one. Include affected old/new doors when a door container is replaced, including removals, and retain signature deduplication.
- **R3 — imported SIP entity does not request live reapply (P1, source finding):** import emits the whole `sip` entity while `onConfigChanges` accepts only `sip.` descendants or self-device changes for `scheduleSipReapply`. A node without matching old physical children can retain the running SIP settings after durable import. Include the root `sip` case. A speculative credential-source probe was discarded: the status handler itself calls `sipSettings`, so it cannot prove `SipCtl.updateSettings` ran. No SIP network/runtime qualification is claimed from the stub.

## Reproduction and ownership

`core/tests/test_config_import_review.cpp` contains the two valid independent production regressions. It executes actual HTTP authentication, stage, preflight and commit on Node/SQLite, using the existing test clock. `red-r1.json` records the source, exact compiler/linker/test commands, frozen production archives and binary SHA. Compile/link succeeded; execution exited 1: 2 cases, 45 assertions, 4 expected failures. Original logs are preserved. Later exploratory red-r2/r3 runs are separately marked for the invalid SIP oracle; the two valid counterexamples remain unchanged.

The implementation owner's previously identified receipt-schema, full-ledger preflight and cancel-with-corrupt-ledger issues are not attributed to this review. Their final fixes still require source verification on the frozen final candidate.

## Other paths inspected

The stage is bound to the administrator credential fingerprint, session digest, boot epoch, exact uploaded-request digest, configuration revision and fixed monotonic TTL. Every action checks the current session/CSRF; HTTP adds trusted Origin, while native C ABI requires the session and CSRF directly. Full-tree/context validation, duplicate/depth/node/byte limits, secret reference and local asset checks, semantic UI leaf validation, materialized-target equivalence, journal budgets, transaction metadata, publication ordering and local-only replication semantics were inspected. No additional blocking finding is asserted for these paths at this point.

Final source/green evidence review is pending the implementation owner's corrected frozen candidate. Host tests use macOS arm64, unsigned Debug and SIP stub. They do not qualify physical devices or network-wide simultaneous switching.
