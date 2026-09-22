# T20 independent lifecycle review

Date: 2026-09-22. Reviewer: a separate agent that did not implement T20.
Initial verdict: **CHANGES_REQUESTED**. Two source-level timing counterexamples
remain in generation isolation and reset/restart reentrancy. The call-lease and
off-main teardown design itself is appropriate.

This review is read-only for production and tests. It does not set task status,
claim a reproduced UAF, or treat successful compilation as lifecycle evidence.
Line anchors refer to the reviewed working tree at base HEAD
`b26e0d346df99f2879915241b6e98d8ef1aa0707`, which includes earlier user/task edits.
No separate T20 incoming file copy was available from the implementer. Earlier
MainViewController UI/timing changes are excluded from T20 attribution; only
its shutdown preparation and peer-result generation changes are reviewed here.
The parallel-batch source manifest remains the pre-integration hash reference.

## Blocking findings

### R1 — High: an old capture frame can acquire a new Core generation

Evidence: `ios/Doorbell/CameraFeeder.swift:153`,
`ios/Doorbell/CoreBridge.swift:72`,
`ios/Doorbell/CoreBridge.swift:562`,
`ios/Doorbell/MainViewController.swift:249`.

Concrete source-level ordering:

1. An old capture callback passes its final `isAcceptingFrames()` check.
2. The thread is delayed before entering `core.onCameraFrame`.
3. Main closes camera admission and requests Core stop. The callback has no Core
   lease yet, so the current `inFlight` count does not hold teardown open.
4. Stop completes and the same bridge starts a new native generation.
5. The old callback enters `onCameraFrame`; its generationless `withCore` obtains
   a valid lease on the new native instance and writes the old frame there.

The lease prevents a freed-handle call, but does not establish that the input
belongs to the new instance. The second accepting-frames check is useful but is
not atomic with Core lease acquisition. Removing the old main-thread camera
queue drain makes this distinction necessary; restoring synchronous main-thread
draining is not the recommended fix.

Required correction: capture the source Core generation for asynchronous media
work and compare the expected generation inside the same lifecycle lock that
admits/increments the call lease. A separate pre-call generation check leaves
the same check/use window. Bind a capture session to its intended generation so
queued old-session callbacks cannot capture the replacement generation afresh.
Audit encoded-frame entry too: its current public bridge method accepts no
expected Core generation. The encoder's own session generation and VideoToolbox
drain are useful existing protections, but are not a substitute for the Core
generation contract of the bridge ingress.

Required production-boundary test: retain generation G1, stop/start to G2, then
deliver an old raw frame and an old encoded result through the real bridge.
Assert that neither acquires a G2 lease or mutates G2 media state, while a G2
frame is accepted. Also preserve the existing test proving that an already
acquired G1 lease delays destruction.

Status at initial review: OPEN. This ordering was identified in source, not
executed on camera hardware or reported as a reproduced crash.

### R2 — High: queued identity restart can outlive a completed pairing reset

Evidence: `ios/Doorbell/AppDelegate.swift:309`,
`ios/Doorbell/AppDelegate.swift:333`,
`ios/Doorbell/AppDelegate.swift:461`,
`ios/Doorbell/CoreBridge.swift:259`.

Concrete source-level ordering:

1. `applyReplicatedIdentity` sets `identityRestartPending` and schedules
   `restartForIdentityChange` on main.
2. A pairing-reset request runs before that scheduled restart. It sets
   `pairingResetPending` and registers its stop completion first.
3. The already scheduled identity restart still passes its entry guard, which
   checks `identityRestartPending` but not pairing reset. It registers a second
   completion against the same stopping Core.
4. The first completion clears pairing/bootstrap state, displays setup and
   clears `pairingResetPending` on return.
5. The old identity completion then observes `pairingResetPending == false` and
   calls `startConfiguredApplication`, replacing the setup screen and starting
   Core despite the completed reset.

The guard added to `applyReplicatedIdentity` prevents a newly scheduled restart
after reset begins; it does not invalidate one already queued. The stop API
correctly drains one native handle, but ordinary completion closures do not
carry an application-transition generation.

Required correction: reset must immediately retire any queued identity restart
and its continuation. Bind restart/reset work to an application transition token
or an equivalent explicit cancellation policy. Check validity before destructive
UI changes and again before restart. Do not rely only on a temporary Boolean
that is cleared after the first completion. All legitimate stop callbacks must
still run exactly once; a stale application's restart work must become a no-op.

Required production test: exercise both completion registration orders with
the actual AppDelegate transition path or its production transition coordinator.
The reset-first case above must leave setup visible and Core stopped until the
user explicitly completes setup. Repeated reset must wipe once; ordinary
identity restart must still restart after destruction.

Status at initial review: OPEN. This is a source scheduling counterexample;
the current eight bridge tests do not drive this AppDelegate interleaving.

## Verified source properties

| Area | Observation |
|---|---|
| Full C-call lease | `withCore` tests running state and increments `inFlight` under `NSCondition`, releases the lock before the C call and decrements with `defer`. No exposed raw Core accessor remains. |
| Buffer ownership | JSON, returned call IDs, configuration warnings and dynamically resolved JSON results are copied/freed inside their lease. Camera bytes and encoded `Data` remain alive through the synchronous C call. |
| Entry inventory | Instance-dependent call/owner/reply/unlock, pairing/unpair/reset-related, status/config/capability/time/audio, runtime writes, camera/encoder and dynamic password/config functions all route through `withCore`. Lifecycle create/start/stop/destroy use their dedicated state transitions. Version/backend and QR codec helpers do not take a Core instance. |
| Stop admission | `stop` switches to stopping synchronously; new leases are rejected. Teardown waits for both startup and in-flight calls on a serial background queue. |
| Callback lifetime | The generation-specific registration is retained through UI callback removal, native stop and destroy. UI JSON is copied before main delivery; UI/TTS delivery is generation gated. |
| Callback draining | Native `setUiCallback` drains retired callback slots; bridge removal runs off main. Platform device/power callbacks use caches and schedule refresh asynchronously. No new main-queue synchronous wait was found. |
| Concurrent stop | Only the first transition to stopping enqueues teardown. Other callers register completions. Native destruction is executed once per detached handle. Completion dispatch is on main. Application continuation validity still needs R2. |
| Startup races/failure | Stop waits while `starting`; a stopped-during-start handle is never published as running. Failed create/start enters the same teardown path before retry. |
| Old clock/UI results | Core UI registration and `DoorbellClockSource.refresh` reject results from a retired generation. |
| Peer-image results | `MainViewController.pollPeerFrame` checks captured Core generation before assigning image or showing in-call media. Its same-Core call/session identity is outside this Core-lifetime repair and remains an identity/media concern in existing later tasks. |

Relevant implementation anchors: `ios/Doorbell/CoreBridge.swift:45`,
`ios/Doorbell/CoreBridge.swift:137`,
`ios/Doorbell/CoreBridge.swift:216`,
`ios/Doorbell/CoreBridge.swift:244`,
`ios/Doorbell/CoreBridge.swift:274`,
`ios/Doorbell/CoreBridge.swift:333`,
`ios/Doorbell/CoreBridge.swift:492`,
`ios/Doorbell/CoreBridge.swift:757`,
`ios/Doorbell/CoreBridge.swift:938`,
`ios/Doorbell/DoorbellClock.swift:238`,
`ios/Doorbell/MainViewController.swift:1571`,
`core/src/capi/doorbell_capi.cpp:238`,
`core/src/capi/doorbell_capi.cpp:485`.

## Evidence assessed

The reviewer inspected the actual production-linked test methods in
`ios/DoorbellTests/CoreBridgeLifecycleTests.swift` and the completed log
`verification/remediation-q01-q18/T20/evidence/xcode-normal-r4.log`.
That run executed **8 tests, 0 failures**, with `TEST SUCCEEDED`; this is actual
XCTest execution, not just build success. The test barrier sits in production
`withCore` after lease acquisition and before the real C call. Callback tests
invoke actual Core callback-producing operations. The stale-delivery test
captures actual deferred production delivery closures rather than constructing
an unrelated mock state machine.

| Required case | Observed evidence and remaining limit |
|---|---|
| T20-01 | Lease/read barrier and delayed destruction test passed. |
| T20-02 | Reads and camera/encoder entries while stopping were refused; test passed. This does not cover old-generation input after restart. |
| T20-03 | Actual Core callback awaited main work while main requested asynchronous stop; test passed. |
| T20-04 | Old UI callback and clock result tests passed. Full case is not cleared while R1 remains. |
| T20-05 | Two bridge stops, exactly one destruction, stop-during-start and failed-start retry tests passed. Full reset/restart scope is not cleared while R2 remains. |

The simulator Debug test target uses a SIP stub; these results verify the bridge
lifecycle and do not qualify production SIP dialogs, physical media, old iOS
devices or a release artifact. ThreadSanitizer and AddressSanitizer runs were
still pending when this initial review was written. Native static libraries are
not necessarily instrumented merely because the Swift test target enables a
sanitizer; any later evidence must state its actual coverage.

No T20 completion, VERIFIED status or device deployment is asserted here.
The implementer and parent were informed of both blocking findings immediately.

## Re-review of R1, R2 and producer-status finding — 2026-09-22

Code verdict: **PASS** for the reviewed source changes. R1 and R2 are resolved;
the subsequent independent caller-audit finding, R3 below, is also resolved.
The original CHANGES_REQUESTED verdict and counterexamples above remain review
history. This is not a release/device qualification or a task-status mutation.
Native archive provenance has a separate evidence note below.

### R1 closure: expected generation is part of lease admission

`ios/Doorbell/CoreBridge.swift:72` now checks `expectedGeneration` inside the
same lifecycle lock as phase/handle validation and `inFlight` increment. Raw
and encoded frame entries require the producing generation
(`ios/Doorbell/CoreBridge.swift:564`,
`ios/Doorbell/CoreBridge.swift:576`). There is no check-then-acquire gap.

`ios/Doorbell/CameraFeeder.swift:215` derives the frame token from the active
capture output identity and the generation recorded when that session began.
`ios/Doorbell/VideoEncoderVT.swift:147` captures and forwards the original
frame's Core generation into the encoded callback. Neither path relabels an old
frame using the current Core generation when it eventually reaches the bridge.

The production-entry test at
`ios/DoorbellTests/CoreBridgeLifecycleTests.swift:267` suspends a producer after
capturing G1, destroys/restarts Core, resumes both old frame entries and observes
zero G2 acquisitions. It then submits both entries using G2 and observes exactly
two acquisitions. This proves that the tested paths reject old work and still
admit current work. The existing lease-before-C barrier remains covered.

### R2 closure: pairing reset invalidates scheduled and in-flight restart work

`ios/Doorbell/AppDelegate.swift:344` captures an application lifecycle-transition
token before scheduling identity restart. Both restart entry and its stop
continuation check that token (`ios/Doorbell/AppDelegate.swift:354`,
`ios/Doorbell/AppDelegate.swift:377`). Pairing reset increments the token and
clears `identityRestartPending` immediately
(`ios/Doorbell/AppDelegate.swift:493`). A completed reset clearing its temporary
Boolean can no longer make the retired identity token valid again.

The tests at `ios/DoorbellTests/CoreBridgeLifecycleTests.swift:311` and
`ios/DoorbellTests/CoreBridgeLifecycleTests.swift:315` cover reset before the
queued identity restart and reset after identity teardown is pending. They
instantiate the real AppDelegate and real Core, hold a real native call lease,
repeat reset and assert one destroy, no identity restart and Core still stopped.
DEBUG hooks intercept only final persistence/start side effects so tests do not
erase the host's settings; the scheduling and stop state machine under test is
the production one. These tests do not claim to have physically exercised setup
UI or deleted user credentials.

The shared asynchronous-stop migration also updates tvOS pairing reset to defer
clear/restart until completion, with repeated reset guarded
(`ios/DoorbellTV/TVAppDelegate.swift:116`). The tvOS build evidence below is
compilation evidence, not tvOS runtime qualification.

### R3 closure: retired producer status cannot mutate its replacement

The separate caller audit identified old VideoEncoderVT status deliveries that
could latch `h264EncoderFailed` after replacement and old AVCaptureSession
observer callbacks that could publish the replacement's camera failure/state.

`ios/Doorbell/VideoEncoderVT.swift:209` now validates the producing session
generation under the encoder lock before mutating terminal failure. Its status
path captures that generation and source Core generation and validates both at
final main-queue delivery (`ios/Doorbell/VideoEncoderVT.swift:218`). Delayed
callbacks pass their original session generation rather than reading the
replacement's generation when reporting.

`ios/Doorbell/CameraFeeder.swift:168` rejects stale producer reports before
recording them and validates session/Core generations again on main. Runtime
error observer closures capture the generation of their actual session
(`ios/Doorbell/CameraFeeder.swift:224`). Stop and begin both advance the session
generation (`ios/Doorbell/CameraFeeder.swift:107`,
`ios/Doorbell/CameraFeeder.swift:199`), preventing a queued stopped report from
being mistaken for the replacement session's report.

The new tests at `ios/DoorbellTests/CoreBridgeLifecycleTests.swift:364` and
`ios/DoorbellTests/CoreBridgeLifecycleTests.swift:387` drive the real encoder
failure/status path and real AVCaptureSession notification registration. They
cover a status already queued before replacement, an old callback invoked after
replacement, suppression of the retired producer and acceptance of the current
producer's report. They do not require or claim a hardware camera, physical
capture, or successful H.264 encode. The intermediate normal-r6 failure exposed
the shared stop/begin generation; normal-r7 includes the corrected separate
generation and passes. That failure log is retained as actual test history.

### Reviewed source identity

The reviewer independently recomputed every one of the 12 source hashes in
`verification/remediation-q01-q18/T20/source-manifest-final.json`; all matched
the current files at this re-review. Manifest SHA-256:
`b704fc18ecf4033505343e2431cbaf54d04b99328011fe1a2b0aa6088dc5d13d`.
Base HEAD remains `b26e0d346df99f2879915241b6e98d8ef1aa0707` with a dirty tree.

| Reviewed source | SHA-256 |
|---|---|
| `ios/Doorbell/CoreBridge.swift` | `6caa9bae6c524e3322fa2d9856f2835e34c39aac0806ec8d190b5775cd6168c8` |
| `ios/Doorbell/DoorbellClock.swift` | `a2da2e566099c39fa9dabbc6fb444f4ed9801cf8d09795995be1460fc4c03229` |
| `ios/Doorbell/AppDelegate.swift` | `39079fcba1032a43ab73c015384d8c8b8c34e76be122899d79a85890770af0a2` |
| `ios/Doorbell/MainViewController.swift` | `8bb5be087fe0786090f16624220e692408d8a76f9a6a9a9167b2edc1463ec66e` |
| `ios/Doorbell/CameraFeeder.swift` | `6dcaf67b32f5cf3489dc19e98c00b40ae3263d53e7e9572ffc16edbdba450a56` |
| `ios/Doorbell/VideoEncoderVT.swift` | `f9acb00c1b1ebe792f42dde88c17b2bab9b09c459e6a21db1c6d3b6f0b76a5f4` |
| `ios/DoorbellTV/TVAppDelegate.swift` | `4e4e90647b5fde01ec8b4445b75c925c5cb8c870b4b05ca1662cfac113e7e0ec` |
| `ios/DoorbellTests/CoreBridgeLifecycleTests.swift` | `5845ac5c7f0d5094d01bc4e05de7c1c61a634d03fb311ef03d0b0bf1faa0a254` |

### Re-reviewed execution evidence

The reviewer inspected completed logs rather than relying solely on metadata
exit codes. No duplicate full build was started by this review.

| Evidence under `T20/evidence/` | Observed result | Log SHA-256 |
|---|---|---|
| `xcode-normal-r7.log` | Final 13 lifecycle/producer tests, zero failures, TEST SUCCEEDED | `d9e9c7ddf211390bd930303b2956b90a0b5007f54b6be510a0bbb470dc923955` |
| `xcode-full-final.log` | Final 143 tests, zero failures, TEST SUCCEEDED | `3ca4adf5d0cf03261070789b070d04fa2f160f9a27d818e308c9c388f6ae856d` |
| `xcode-tvos-final.log` | Final tvOS simulator BUILD SUCCEEDED | `6ed88daf8d19d3287eaabe9ce44374f1906f5180c857f2496fa9cab15d0be768` |
| `xcode-tsan.log` | Earlier R1/R2 snapshot: 11 tests, zero failures, TEST SUCCEEDED | `0d92e764a9e457a84e57254b473417300997f66abc3a4eab6cc1cb95c3b8cb1f` |
| `xcode-asan.log` | Earlier R1/R2 snapshot: 11 tests, zero failures, TEST SUCCEEDED | `273d212ea6eb8d9bea66ad988d2d8a95f90ecc650746e76949470521e4197891` |

Final producer-source sanitizer reruns were pending at this point; the earlier
11-test runs are not attributed to the later R3 source. Native C++ archives were
not built with matching sanitizer instrumentation, so these runs provide
instrumented Swift/bridge coverage, not comprehensive native C++ memory/thread
coverage. The iOS lifecycle test executable uses the explicitly permitted Debug
SIP stub. The final tvOS build manifest identifies real PJSIP, but that command
only compiled the app; it did not exercise SIP or tvOS runtime behavior. Neither
kind of evidence qualifies physical devices or a deployed build.

### Native archive evidence note

Source identity verification passed, but the archive at the simulator link path
had changed during parallel build activity. The final source manifest records
`8a7264d5d418d61d8cc4887673c1451d5e3fbfeac8027c10f30b86602313af7f` for
`ios/build/core/iphonesimulator/arm64/min-12.0/libdoorbell_all.a`; the independently
observed current file was
`063b3fcfa14efc5d61fd63b773570367822a202af34017f8fef90bd4a8ef3b1d`.
The implementer/coordinator were asked to reconcile actual linked artifacts and
preserve historical manifests. Do not replace the earlier test's recorded hash
with the current file's hash or infer an exact tested archive from a mutable
link path. This is pending evidence clarification, separate from the resolved
source defects and observed successful test executions.

Archive clarification received and independently verified: the manifest's
`native_archives` field was a pre-build observation, not a claim of the final
linked input. The implementer preserved it and recorded completed app Mach-O
hashes/UUIDs and per-run archive copies in the following separate records.
The reviewer recomputed the listed app binaries and preserved archive hashes;
all matched. The mutable archive-path mismatch is therefore **resolved as an
evidence-identity clarification**, not silently rewritten in historical data.

| Completed run identity record | SHA-256 | Verified app / archive identity |
|---|---|---|
| `T20/evidence/xcode-full-final-artifacts.json` | `14899450ab13cdfc15a4649b8eb5e6c1b1f998c45c032f9ba44af9b016873cfd` | iOS 0.1.36 (37), app `9d1e5e42104fb7d1557c9e18541fe379c60fad80f5ab699bf8f58c36e4918f24`, debug dylib `45b9c17db2012d9ccca04f9fedb11ca3bdc1d7462be5078344d48c46ebb24f39`, preserved native archive `063b3fcfa14efc5d61fd63b773570367822a202af34017f8fef90bd4a8ef3b1d` |
| `T20/evidence/xcode-tvos-final-artifacts.json` | `21f6f2740f974bc1350275e4917a1b39667ccaa9c7baa411d1797265322130fd` | tvOS 0.1.13 (14), app `7b91369603f42f7299c11d632075bc510a9655827bd643f8c40a1e46bf2757a6`, debug dylib `8462145a7fedb095106be99173c7a5f60b2fae0444e8732ecf0eda4f2dbc4728`, preserved native archive `ac04bdd65dae98c6db973d2be5d39c345dd7d2c9ee572d258e6fdcb24ee13ad1` |

These are local unsigned/simulator artifact identities. The app versions are
read from generated build artifacts, not from a deployed device. The older
11-test sanitizer archive identity is not backfilled with either final archive.

## Final sanitizer closure and independent verdict

Final verdict: **PASS_IN_SCOPE — native_lifecycle on the iOS simulator**.
R1/R2/R3 have no remaining blocking source finding in the reviewed snapshot.
T20-01 through T20-05 have the production lifecycle evidence described above,
including the added stale-producer and AppDelegate reset orderings. No physical
device, release SIP, deployment or broader T36 completion is inferred.

The final ThreadSanitizer and AddressSanitizer runs each executed all **13 tests
with zero failures** and `TEST SUCCEEDED`. The reviewer inspected both completed
logs, their zero-exit command records and the post-run artifact records; no
sanitizer diagnostic was observed in these runs. All 12 source hashes still
match the final manifest. Per-run app binary hashes and retained native archive
copies were independently recomputed and match their artifact records.

| Final sanitizer evidence | SHA-256 |
|---|---|
| `T20/evidence/xcode-tsan-final.log` | `0668d2f2e1cf26ddafa7ee5b095c6ffb13fcfb39f65eaff4b6f7d9f4c12ae213` |
| `T20/evidence/xcode-tsan-final.json` | `bb90bde462a55220aa8bd0b26d04fa261fe0fcc35a439ec29c0271a505d46aae` |
| `T20/evidence/xcode-tsan-final-artifacts.json` | `7d7325839d67e2c0db686d95eca1a45779749532eba63a5317b29a67e433fa75` |
| `T20/evidence/xcode-asan-final.log` | `6fc71bb9d58d9feb39345a8b65c6e7fd55151a539479fae779d3c4d8e9ee0385` |
| `T20/evidence/xcode-asan-final.json` | `ebfab5c6f978ce1345ed7cca7af9fd694ca9d0c933f81a65745c1f447c39a5ef` |
| `T20/evidence/xcode-asan-final-artifacts.json` | `a7390889eca6e714beb8eb57bfbfb4d817f7c7bcbbaf8a370eec7bf216fa729e` |

The final sanitizer native archive copies are respectively
`c2b1f9adeb7ddbc0414a47435d67bd7f488f356d1c1fac4972e3ed736aab6055`
and `d60c8e4b021691b9956b39de835f40882d59c8572bab56f288d740f458d4101a`.
They are intentionally distinct run identities. The pre-run manifest is not
rewritten to claim either archive was used by another run.

Sanitizer scope remains limited to the instrumented Xcode Swift/Objective-C
target and its bridge boundaries. The custom native C/C++ archive records empty
C/CXX sanitizer flags; absence of a diagnostic is **not** comprehensive native
C++ race/UAF coverage. iOS tests use the Debug SIP stub; tvOS has build-only
evidence with real PJSIP. Simulated capture notifications and encoder status
callbacks do not qualify physical capture or codec performance. No previously
observed device UAF or physical action is claimed.

Machine-readable closure: `verification/remediation-q01-q18/T20/independent-review.json`.
This reviewer changed review artifacts only and did not mark the task VERIFIED.
