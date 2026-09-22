# T35 Windows independent review

Reviewer: `t02_translation`, 2026-09-23 JST. Final disposition: **PASS_IN_REVIEWED_SOURCE_AND_GUARD_SCOPE** on r3. R1 was found on r2 and is closed below; actual target WPF qualification remains separate.

## Reviewed source and evidence

- Frozen source: `build/remediation-t35-windows-20260923/source-r2`.
- Manifest: `source-candidate-r2.json`, SHA256 `7bedd6a1e5ace48ccb04c644a2ea5598b70de03f176985e0d09ce72092fc782e`. All 98 listed input hashes matched when reviewed.
- Production paths: `MainWindow.VisitorActions.cs`, `Ui/VisitorActionGuard.cs`, `Ui/SosSlider.cs`, relevant constructor, call-state, SOS, countdown, lifecycle and config sections in `MainWindow.xaml.cs`, plus `MainWindow.xaml` and `MainWindow.Shell.cs` layout wiring.
- Inspected the recorded 15-assertion production guard run, 70 source/XML contracts and managed API compilation. These records correctly distinguish Mono and API compilation from an actual WPF executable or UI run.
- Independently compiled and executed the unchanged production guard for the cancelled-input counterexample below. Compile exit 0; run exit 1. Exact commands, source/test/binary hashes and raw output: `evidence/independent-cancelled-input-red.json` and `.log`.

## R1: abandoned physical capture rejects the next current accessible action

`BindVisitorAction` captures on pointer/key down, but only a later Click consumes that capture. Releasing a pointer outside the button, cancelling touch, or losing keyboard focus can end a physical input without Click. After call A is replaced by call B, a current UI Automation activation has no PreviewDown; the stale A capture therefore rejects the first valid B action. A second activation works because the failed consume cleared the old capture.

The independent test executes the actual guard with Begin(A), no Consume for the cancelled gesture, then current visible Consume(B). It returns false. This is a production-helper reproduction combined with source inspection of the event bindings, not a claim that pointer/UIA delivery was executed on Windows.

Cleanup must retain the guard through the synchronous Click associated with a normal release. Microsoft's [WPF ButtonBase implementation](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/PresentationFramework/System/Windows/Controls/Primitives/ButtonBase.cs) releases mouse capture before raising Click, so unconditional synchronous cleanup on lost capture would undermine the old-gesture protection. A deferred cleanup bound to the original input identity can retire an abandoned gesture without clearing a successor.

Implementation owner accepted R1 and is adding token-bound deferred physical-input completion. Required closure cases: cancelled A permits a later current accessibility action; cleanup A cannot clear active B; before deferred cleanup, release of an old phase still cannot act on the new phase; fresh physical/accessible actions remain valid.

## Other reviewed boundaries

- The visitor guard includes call identity, Core generation, view revision and action kind. Cancel also requires ringing and rejects `_inCall`; End requires visible connected UI. Current visible accessibility activation remains allowed when no physical capture is outstanding.
- Call transitions, suspension and closure advance the view identity. A new physical input replaces the previous capture. No new door-unlock permission or call cancellation semantics were introduced in the reviewed changes.
- Modal SOS confirmation has a distinct review revision plus Core generation. A stale review cannot consume or revoke a successor. Confirming checks current visibility, loading, enabled state and existing emergency/countdown state.
- Each countdown owns its timer instance, revision and Core generation. Stop clears the instance, advances the revision, collapses the overlay and resets the slider; queued old ticks cannot decrement or commit a replacement countdown.
- Slider unload/hide/disable revokes queued slider-level accessible requests. Owner unload/hide, call transitions, minimization/suspension and window closure stop the countdown/review. The slide completion also rejects cancelled drags and unavailable controls.

No additional definite blocker was identified in these source paths during this review. This is not runtime certification of routed input ordering, nested WPF modal dispatch, focus, keyboard accessibility, layout or OS lifecycle behavior.

## Limits

No production files were changed by this reviewer. No Windows device, actual WPF application, screen-reader session, native Core/SIP action, door or SOS was run. The implementation report must retain all four WPF UI gates as NOT_RUN until the target environment is available. API reference compilation and Mono tests cannot close those gates.

## R1 closure on r3

The implementation owner froze `source-candidate-r3.json` (SHA256 `3d8b165108885f55e030f8f9625de7007b9274a9f09c7ae425417fc27e9165df`) at `build/remediation-t35-windows-20260923/source-r3`. All manifest input hashes were rechecked.

`Begin` now returns a monotonically advancing physical-input token. `CompleteInput` only clears that same token. The production bindings schedule completion on mouse/touch/key release and lost capture/focus via `Dispatcher.BeginInvoke(DispatcherPriority.Send, ...)`. Completion is deferred until after the current routed event, retaining the original identity for its synchronous Click; an older queued completion cannot clear a later physical input.

Independently compiled and ran the actual r3 production guard and its 19 acceptance assertions: compile exit 0, run exit 0. The four new checks cover abandoned input followed by current accessibility activation, old cleanup versus a successor, original phase enforcement before deferred completion, and the current activation after completion. Raw evidence: `evidence/independent-guard-green-r3.json` and `.log`. The r2 failing reproduction remains unchanged.

The r3 delta is limited to token-bound completion and its bindings/tests; no new issue was found in that delta. Actual WPF event delivery still needs its target gate; this closure confirms the production state machine and reviewed wiring, not a Windows runtime result.
