# T16 bounded authenticated return-video relay

Status: **IMPLEMENTED_CANDIDATE / BLOCKED_ENV for full production qualification**.
Base: `39b57222b45d83e2116a65b3d5242718d56fac79`.
Release gate: **NOT_READY**. This document does not close T16, T17, T18 or T31.
No deployment, push, physical unlock or SOS action was performed.

## Implemented path

The existing browser uses relative `/api/panel/media-authorize` and `/call-frame` URLs. Those two routes now use the existing bounded `OperationDispatcher` through `Httpd::routeWorker`. The dispatcher receives a separate media limit set and does not parse JPEG bodies as JSON. The application does not create an HTTP forwarding client or another thread pool.

A resolves exactly one configured `door_station` for the requested door. Missing or ambiguous targets fail closed, including when a competing configured station is offline. A remote target must be a connected, paired Mesh peer in the current device configuration and must not be removed. No URL, host, port, path, redirect or caller-selected peer is accepted in the identity tuple. Unknown and duplicate query keys, including percent-encoded duplicates, are rejected. Existing Cookie, CSRF and trusted-Origin checks remain mandatory; no credentialed wildcard CORS is added. Reverse proxies must use the existing explicit trusted-origin configuration; this patch does not trust arbitrary forwarded headers.

A authorizes the original panel session, its current credential/grant version, door scope, `media.publish`, the owning WebDialogLease, and the current call/revision/dialog owner. Remote publication requires an independent T31 panel identity; shared legacy credentials remain supported only for same-node publication. B does not need A's browser credential in secure storage.

Four transient Mesh commands carry authorization, frame, result and revocation messages over the existing authenticated encrypted channel. Only public principal identity crosses the channel; no browser Cookie, CSRF token, long-lived Bearer, secret material or secret reference is forwarded. JPEGs are never placed in the CRDT or durable event log. This change does not replace or downgrade Mesh authentication.

B mints the generation, stores a fixed monotonic grant deadline and binds it to source peer/epoch, target, principal, call/revision/owner and authorization request. Replaying the same live authorization returns its existing generation and remaining lifetime rather than renewing it. Retired requests are retained in a bounded replay cache; capacity is rejected instead of evicting live tombstones. A revalidates the original live session and call after the reply. Mismatched request IDs, peer, principal, response kind, generation and sequence cannot complete a different request. Redirect statuses are never followed.

Each frame is revalidated by A before dispatch and by B immediately before writing the existing transient `peer_frame` return-video slot. The final check follows bounded JPEG validation and includes current authority, permission, call identity, peer epoch, sequence and deadline. B's frame deadline is derived conservatively from B's original grant clock; monotonic clock epochs from different nodes are not compared. `remote_core_accepted` means Core accepted the slot, **not that a screen displayed it**.

Call cancellation, permission/session expiry, generation replacement, peer removal/reconnect and target ambiguity revoke publication and clear the related cached frame. HTTP waiters are woken before the runloop-owned queues/RPCs are drained during stop; existing HTTP and transport joins stay outside the state-loop drain. Late callbacks cannot reintroduce a retired generation. `/peer-frame.jpg` is limited to the original local publishing session or a loopback native consumer without presented browser credentials. A different valid panel cookie does not gain native privileges merely because its request originated on loopback. Existing LAN-public camera feeds are not changed.

## Explicit resource/input contracts

| Resource | Bound |
|---|---|
| Existing HTTP pool | 16 workers; frame and authorization requests share a 4-worker admission cap |
| Authorization form/query | 2 KiB, exact identity keys |
| JPEG request body | 1 MiB, including chunked transfer enforcement in existing Httpd reader |
| JPEG profile | Baseline sequential, single scan, 8-bit grayscale or RGB/YCbCr; each dimension at most 1024 and at most 307,200 pixels |
| Base64 | Canonical encoding; decoded-size preflight before decode |
| Mesh media envelope | Base64 ceiling plus 4096 bytes; flat bounded JSON string fields |
| Active grants / publisher rate entries | 8 each |
| Source RPCs / queued publishers | 4 each |
| Per publisher | One active frame and one latest pending frame; superseded frames complete with a drop result |
| Rate | 10 frames/second per publisher, burst 2; 20 frames/second aggregate, burst 4 |
| HTTP processing waiter | 3000 ms after body reading; the existing body-read deadline remains separately bounded at 5 seconds |
| Mesh RPC | 2500 ms; cleanup sweep every 50 ms |
| Grant | At most 10 seconds; remote requests reserve the RPC travel budget from the source lease |
| Replay records | 64; live grant plus 30-second retirement retention |
| Existing TCP outbox | Preserve the baseline byte/frame caps; no unbounded alternate sender |

The bounded JPEG decode still consumes Core CPU. No claim is made that its latency is zero or that total process RSS equals the frame-queue bound. Legacy-device decode cost, full-process RSS, HTTP-pool fairness and real non-reading peer behavior require target measurements. Progressive/multiscan JPEG is intentionally rejected; this is a stricter return-video input contract, not a change to the general camera feed.

## Tests and evidence

Executed in this environment: strict C++14 component builds, the production bounds test (50,085 assertions, including deterministic parser/queue loops), and 9 production relay-component groups (40,309 assertions, including 10,000 stale submissions). Both also passed AddressSanitizer and UndefinedBehaviorSanitizer with leak detection enabled. These are assertion counts, **not** 90,394 independent integration scenarios.

The relay component includes the actual new production `.inc`. Its surrounding Node authentication, HTTP dispatcher, clock/runloop and Mesh dependencies are explicit fixtures. JPEG decoding in this fixture uses the installed libjpeg through test-only adapters rather than the repository's stb build. It does not prove full Node, TLS, TCP or SecureChannel integration. `local-tests/run.py` in the delivery package records commands, exit codes, source hashes and logs.

Added for the real repository suite: `test_media_relay_bounds.cpp`, strict target/form/JPEG subcases in the existing publishing fixture, and a two-Node test using real HTTP and the production Mesh transport. The latter sets up an independent panel identity and verifies B's return slot, reply correlation and call-end invalidation. **These full Node tests have not been built or run here.** Existing HTTP-size/TCP tests are retained. The obsolete unknown-target `501` expectation becomes fail-closed `409`; existing T15 identity and privacy assertions are not weakened.

The application script's unique-anchor validation, patch generation, Git check/apply/staging, concurrent edit rejection and symlink/reapply rejection were exercised on a **synthetic anchor repository**. That does not establish application or compilation against the unseen full checkout. The script rechecks the actual local baseline before writing, and refuses newer HEADs or dirty worktrees instead of discarding edits.

| Task acceptance case | Current qualification |
|---|---|
| T16-01 HTTPS browser A to station B, no mixed content/credential leakage | NOT_RUN at required production/browser layer |
| T16-02 arbitrary target, wrong peer, redirect, authority boundary | Component assertions PASS; full production case NOT_RUN |
| T16-03 nonresponding B, continuous frames, concurrent status/SOS, resource measurements | Component queue/timeout assertions PASS; full workload NOT_RUN |
| T16-04 call switch while a frame is in flight | Component final-receiver assertions PASS; full production case NOT_RUN |
| T16-05 size, type, malformed JPEG before large allocation | Component assertions PASS; complete production ingress/codec case NOT_RUN |

## Integration and release gates

The container could not clone the complete repository or obtain its full dependency tree. Public fixed-SHA source was inspected, but a full Core build, all existing regressions, actual HTTPS browser tests, physical/legacy device qualification and independent review are **NOT_RUN**. T16 cannot be marked VERIFIED_IN_SCOPE from these component results.

The package's local workflow runs the repository's standard Core/stub build and full `doorbell_tests`, translation consistency and English-source checks before committing. A passing stub build still does not qualify a production SIP build. Retain T17/T18 browser state/recovery work, T31 independent-identity integration and historical-SDK/device checks as separate outstanding gates. Do not reset a newer worktree to this baseline.

Affected manifest increments: Android 0.3.21/22 to 0.3.22/23; modern iOS 0.1.37/38 to 0.1.38/39; iOS-kiosk 0.3.49/52 to 0.3.50/53. No archived `ios-legacy` file or public native C ABI is modified. No new user-visible string or generated locale is introduced. No SDK, signing material or compiled application binary is included.

`relay-progress.json` is a scoped candidate checkpoint only. It does not overwrite an uninspected global progress ledger or promote any other task's status.
