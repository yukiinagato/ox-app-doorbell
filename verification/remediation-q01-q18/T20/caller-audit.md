# T20 modern Apple caller audit

Status: PASS_IN_SOURCE_REVIEW after the producer-status closure supplement below. The initial finding and source snapshot are preserved as history. This caller audit does not independently claim T20 acceptance or hardware qualification.

Audit date: 2026-09-22. Reviewer: the parallel caller-audit agent, independent of the T20 implementation. No production source was changed, and no test, build, or simulator was started for this audit.

## Reviewed source identity

The working tree is based on `b26e0d346df99f2879915241b6e98d8ef1aa0707` and contains uncommitted implementation work. The exact SHA-256 of every inspected source is in [caller-audit-source-manifest.json](evidence/caller-audit-source-manifest.json), captured at `2026-09-22T13:53:17.309987+00:00`. That manifest, rather than the base commit alone, identifies this review.

Principal reviewed hashes:

| Source | SHA-256 |
| --- | --- |
| `ios/Doorbell/CoreBridge.swift` | `6caa9bae6c524e3322fa2d9856f2835e34c39aac0806ec8d190b5775cd6168c8` |
| `ios/Doorbell/AppDelegate.swift` | `39079fcba1032a43ab73c015384d8c8b8c34e76be122899d79a85890770af0a2` |
| `ios/DoorbellTV/TVAppDelegate.swift` | `4e4e90647b5fde01ec8b4445b75c925c5cb8c870b4b05ca1662cfac113e7e0ec` |
| `ios/Doorbell/DoorbellClock.swift` | `a2da2e566099c39fa9dabbc6fb444f4ed9801cf8d09795995be1460fc4c03229` |
| `ios/Doorbell/MainViewController.swift` | `8bb5be087fe0786090f16624220e692408d8a76f9a6a9a9167b2edc1463ec66e` |
| `ios/Doorbell/CameraFeeder.swift` | `372b1e8999af8630e49713a8146662550f854447006c790939c6c96349481a5e` |
| `ios/Doorbell/VideoEncoderVT.swift` | `eb93b92b2db4f5206e15441f2f19430f7be05e8406584e1202c069e8a01babad` |

The canonical T20 task card and repository working agreement were used as review criteria. Searches covered all production Swift sources under `ios`, excluding `DoorbellTests`; source membership in `Doorbell.xcodeproj/project.pbxproj` was also inspected. The archival Objective-C application was outside this assignment.

## Stop, restart, and destructive follow-up inventory

| Caller | Observed ordering | Result at reviewed snapshot |
| --- | --- | --- |
| iOS initial startup, `startConfiguredApplication` | Load identity and migrate legacy secret, then `core.start`; no preceding asynchronous stop in this path. | No overlapping restart found. |
| iOS identity change, `restartForIdentityChange` | Stop camera/encoder admission; detach old main controller; stop and release its runtime supervisor; request Core stop; restart only from its completion. A lifecycle-transition counter rejects a superseded continuation. | Consistent with asynchronous teardown. |
| iOS local pairing reset | Stop media admission and runtime; request Core stop; `Keychain.removeAll`, `BootConfig.clearPersistedState`, and defaults clearing occur in `finishLocalPairingReset`, reached from the completion. Setup creates the replacement Core only on a later save. | Storage is not erased while old Core leases are draining. |
| iOS termination | Stop runtime and request Core stop; no immediate storage erase or restart follows. | No caller-ordering defect found; process termination may prevent asynchronous completion. |
| tvOS initial startup | `core.start` precedes runtime and root-controller creation. | No overlapping restart found. |
| tvOS local pairing reset | Stop/release runtime; request Core stop; clear persisted state and start replacement only inside `finishLocalPairingReset`, reached from completion. Duplicate reset is guarded. | Consistent with asynchronous teardown. |
| tvOS termination | Stop runtime and request Core stop; no destructive follow-up. | Same termination limitation as iOS. |

These are all production `CoreBridge.start(dataDir:bootJson:)` and `CoreBridge.stop` callers found. The already-known identity/reset and camera-frame fixes were reviewed in their current form and are not re-reported as new findings.

## Handle and asynchronous-result inventory

| Surface | Evidence and assessment |
| --- | --- |
| Native handle ownership | The opaque Core handle is private to `CoreBridge`. Running C ABI calls acquire `withCore` leases; the lifecycle lock is released before the C body and release is deferred. Stop rejects new leases and destruction waits for admitted work. JSON ownership is consumed within the lease. No production Swift caller outside this bridge retains or passes a Core handle. |
| Handle-free C ABI | The external `db_core_version()` call in `DoorbellTheme` is handle-free. QR encoding also has no native Core-instance ownership. These do not need an instance lease. |
| Callback lifetime and Core events | Callback registration remains retained through native destruction. Borrowed event JSON is copied before queueing. The registration's dispatch generation is checked on main before delivery; stop invalidates it. TTS delivery uses the same registration lifetime/generation discipline. |
| Clock, shared by iOS and tvOS | `DoorbellClockSource.refresh` captures `runningGeneration`; its main delivery rejects a reading if that generation changed. Individual native reads are lease-protected. A restart between admission and read cannot publish that result as the captured generation. |
| Camera/encoded bytes | Capture output identity and captured Core generation are carried through camera delivery; both raw and encoded frame bridge calls require the expected generation. An old producer cannot acquire a lease on the replacement Core for its frame bytes. This does not by itself protect runtime-status callbacks; see the open finding. |
| Main-view peer still image | The request captures Core generation and verifies it again on main before image delivery. Existing in-call and HTTP/image validation also remains. |
| Diagnostic refresh | Reads use leased bridge methods, but the UI delivery checks only its view-local refresh counter. The inspected restart paths replace the old controller hierarchy, and the completion references that old controller weakly. No concrete route to a replacement controller was established in this audit. This is not a claim that the diagnostic snapshot is atomic across several native reads. |
| Settings/config writes | Native writes occur synchronously through the bridge; completion is queued to the initiating settings controller via weak references. The HTTP fallback and completion have no Core-generation token, but no immediate erase/restart from the write callback was found. This audit does not qualify HTTP authorization or configuration contracts. |
| Admin/pairing QR rendering | Asynchronous rendering uses the requested URL/URI as its delivery key and handle-free QR generation. It does not deliver a borrowed Core handle or mutate replacement Core state. |
| Runtime-supervisor delivery | iOS root controllers keep their original supervisor weakly, and restart/reset releases that supervisor. Camera/encoder stop and restart within the same controller still need producer-generation checks; weak controller ownership does not supply them. |

## Initial finding: retired producer status can reach the current controller

At the recorded snapshot, `VideoEncoderVT.reportRuntime` captures its handler and queues it on main without checking the encoder-session generation or Core generation at final delivery. The handler in `MainViewController` sets `h264EncoderFailed` for a failure; `encoderPoll` then refuses or stops encoding. Frame-byte generation checks do not guard this separate state mutation.

A production transition exists in `enterSafeModeForMemoryPressure`: it stops the encoder and camera, then starts capture again in the same main controller. A status callback already queued by the retired encoder can execute after that stop and affect the controller that now owns the replacement capture. In particular, a retired failure can latch `h264EncoderFailed`, preventing the later encoder poll from starting the replacement. A retired success can likewise publish a measurement for a producer that has already stopped. This finding is based on the callback and transition code; the precise scheduling was not reproduced by this read-only audit.

`CameraFeeder` has the corresponding status issue. Its runtime-error observer captures only `self`, not the producing capture-session identity. Removing the observer does not add an identity check to an invocation already executing. Such an invocation can call `reportRuntime(runtime_failed)` after `start` replaces the capture session. Frame callbacks check output identity before handing off bytes, but `reportRuntime` and the eventual main-queue `RuntimeSupervisor.recordCameraRuntime` update carry no producer generation. An old queued active result can also follow the new producer's `starting` state. This can report the wrong current camera capability/state without an unsafe native handle access.

The finding was sent to the coordinator, implementation agent, and independent reviewer. Closure requires checking producer identity and Core generation at final status delivery, with stale failure/success coverage. A generation read from the current producer only when scheduling an old callback would not establish the old callback's ownership.

## Verification limits

This report records source inspection and caller inventory only. It does not claim any simulator, sanitizer, historical SDK, physical camera, or tvOS hardware result. The separate T20 test and independent-review evidence must establish those results, and the source manifest must be refreshed or supplemented when the open producer-status fix lands. Async termination completion remains subject to the operating system's process lifetime.

## Producer-status closure supplement

The corrected producer paths were re-read after the independent T20 review closed R3. `CameraFeeder` now captures its session generation in runtime-error handlers and frame status; both producer-generation and Core-generation checks occur again in the main-queue status delivery. Stop increments the producer generation. `VideoEncoderVT` propagates its producing session generation into failure/success reporting, checks it while marking terminal failure, and checks both session and Core generation immediately before invoking the queued UI handler. Thus retiring either producer invalidates its previously queued status, independently of frame-byte admission.

The initial source hashes above remain unchanged as historical evidence. Current source hashes and the independently reviewed report identity are in [caller-audit-closure-source-manifest.json](evidence/caller-audit-closure-source-manifest.json). The open producer-status finding is closed by source inspection in this supplement. [The independent T20 review](independent-review.md) separately records the production callback tests and final simulator sanitizer evidence and its native-archive instrumentation limits; those tests were not rerun by this caller-audit agent. No new production changes were made for this supplement.
