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


## Final re-review — frozen green-r4

Final verdict: **PASS_IN_REVIEWED_PRODUCTION_SOURCE_AND_REGRESSION_SCOPE**. The initial CHANGES_REQUESTED finding history and red logs remain preserved; `independent-review-initial.md` retains the original report bytes.

All 12,633 files in `source-green-r4.json` were independently hashed against the frozen tree, with zero mismatches. The 13 directly reviewed source/test/document inputs also match the current worktree. The reviewer directly executed the frozen `green-r4-build/doorbell_tests --test-case=config import review:* --no-colors=true`: **2 cases / 45 assertions PASS, exit 0**. The same two bodies had produced the original four failures; only the requested POSIX platform guard was added before r4.

- **R1 FIXED:** reconciliation chooses the longest covering sanitized physical unit, rather than projecting an embedded UI container from the full target. Physical mutations are sorted parent-before-child before preview and durable mutation. The exact materialized-target equality check remains enforced. The prior `.local` plus semantic leaf counterexample now restores the full expected configuration.
- **R2 FIXED:** affected door containers are inspected both before and after `rebuildCfg`, after successful persistence. This preserves removed as well as added/changed notices; existing event signature deduplication remains. The production event counterexample now emits the expected notice event.
- **R3 FIXED IN SOURCE:** root `sip` joins the existing descendant/self-device reapply condition. The scheduled callback still executes `SipCtl.updateSettings(sipSettings())`. No real SIP backend or registration claim is made from a stub build; the discarded status probe is not acceptance evidence.

The implementation owner's receipt fixes were also reviewed. Restored ledgers reject malformed/duplicate operation IDs, wrong object fields, malformed principal/digest/token fingerprints, invalid successful result schema and inconsistent result bindings. Preflight reports invalid/full receipt storage without a live write. Cancel checks active authentication and stage binding but no longer depends on loading receipt metadata. No silent receipt eviction was introduced.

The new `query` branch is read-only with respect to configuration and receipts: it checks the active administrator session/CSRF, well-formed operation ID, principal and digest/token bindings, then returns a copy of the saved result or `operation_not_found`. It returns before active-stage commit/preflight logic and cannot execute an existing stage. HTTP retains exact trusted-Origin authorization and no-store responses; the native ABI retains the same session/CSRF requirement. Fixed-TTL expired-stage memory cleanup can occur, but query neither renews the stage nor performs a persistent configuration mutation. The owner's added query tests cover unknown-before-commit, unchanged snapshots, matching original result, mismatched digest, invalid CSRF and fresh authentication after restart; this reviewer inspected those tests and did not duplicate the owner's run.

Source references in the frozen tree: `config_import_service.inc` receipt recovery lines 23–53, physical projection/order lines 157–175, and authenticated action/query lines 232–325; `node.cpp` old/new notice collection around 6304 and SIP root handling around 6367; the five HTTP routes around 10160 and the native entry point in `doorbell_capi.cpp` around 624.

Evidence hashes and exact commands are in `evidence/independent/green-r4.json` and `source-review-r4.json`. The actual host artifact has an ad-hoc linker signature, no TeamIdentifier or release signing identity; the codesign output is retained. Host Debug/macOS arm64/SIP-stub limitations remain. Full regression, historical SDK and the separate crash-test independent approval belong to the parent; this report does not self-approve the reviewer's crash-test authorship or qualify hardware/network-wide atomicity.
