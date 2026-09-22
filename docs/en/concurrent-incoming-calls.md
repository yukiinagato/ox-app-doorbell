# Concurrent incoming calls: resident UI requirements

Source: the user's additional request on 2026-09-22. Primary targets: iPad and
iPhone resident interfaces. Parent task: T36; this design does not complete its
dependencies, implementation or device qualification.

## Observed behavior and intended change

`AppDelegate.presentIncoming` forwards a targeted chime to the visible
`IncomingViewController.receive`. The current receiver replaces its selected
unanswered call when a different call arrives, and returns without displaying
the new call when already in a conversation. There is no visible waiting-call
queue in that screen. These are source observations, not a claimed device test.

Keep the selected call stable and display other eligible calls in a resident
queue. Concurrent means overlapping active calls, not an artificial collection
window that delays the first ring. Only calls targeted to this resident qualify
for incoming notification. A replicated call elsewhere is not permission to
ring every resident panel.

## Layout and interaction

| Situation | iPad | iPhone |
|---|---|---|
| Two or more unanswered calls | Selected call/media with a visible side queue; compact portrait stacks the queue | Selected call/media, followed by a compact queue and waiting count |
| Already speaking to A, B arrives | A's title and controls stay fixed; B appears in the queue with a waiting indication | A stays primary; a waiting summary remains visible without covering controls |
| More calls than fit | Show the count and a reachable full list; preserve list focus and order | Expand the waiting list without obscuring the active-call controls |
| No eligible call remains | Return to the resident home or monitoring state through existing lifecycle rules | Same semantics; no empty incoming modal |

Each queue item identifies the configured door name/location, purpose, call
state and a fresh Core-derived time indication when available. Do not invent a
wait timestamp from an unknown call start; omit it if the source lacks one.
An optional thumbnail is labeled with freshness and is not a second live audio
session. Anonymous/duplicate door names still need a disambiguating location or
stable displayed identifier.

Initial selection is the first eligible call. Later arrivals never silently
retarget Answer, Unlock, Reply or End Call. Keep controls in stable regions;
their action closure binds the selected `(door, call_id, stage_revision)` at
activation and Core revalidates it. Queue identity is `(door, call_id)`; a newer
revision updates that item rather than creating another entry.

Normal calls retain arrival order. Do not continually reorder rows by a ticking
countdown or incoming metadata. Preserve a focused/touched item while new calls
arrive. SOS follows existing Core/rule-selected alert priority; the call queue
does not redefine global SOS clearing or automatically cancel calls.

Selecting another ringing item before answering changes selection explicitly.
Once A is connected, selecting B must not replace A's SIP/media target, imply
hold, or open B's lock through A's controls. If the backend has no qualified
hold/multi-dialog support, show B as waiting. An explicit “End A and answer B”
workflow must name both endpoints, complete A's existing end lifecycle, verify
B is still eligible, and only then answer B. Never auto-answer B when A ends.
If this ordered transition cannot be verified, provide End A followed by an
explicit Answer B action instead of claiming seamless switching.

Local Ignore/mute affects only this resident's matching call. It does not
cancel the visitor or other residents. Clear, answered-by-another-resident,
cancelled and expired events update only the matching identity/revision. A late
event for A cannot close B, remove a new revision or terminate the winner's SIP
dialog. No UI countdown independently cancels a Core call.

## Notification and resource rules

Use one audible notification policy; do not mix several ringtone players.
During a conversation, indicate waiting calls with the existing configured
visual/haptic/brief alert policy without masking speech. Deduplicate repeated
chimes for the same call/revision. Any new sound must be configured and localized
through the existing resource pipeline; do not invent device capabilities.

Decode only the selected qualified live stream by default. Waiting items use
text or bounded snapshots, not one live decoder per door. Show stale/offline
states and disable actions with an explanation when authority is unavailable.
On resume/reconnect, reconcile the queue against Core state and targeting
eligibility; do not restore a stale call as actionable from a saved UI row.

Support Dynamic Type, VoiceOver, long Japanese/Chinese/English names, contrast,
reduced motion, portrait/landscape and iPad split view. Keep effective touch
targets at least 44 points. Announce a meaningful new waiting count once;
do not announce every timer tick or rebuild accessibility focus on each poll.
Use the project's existing Tabler assets; no hand-drawn icon replacement.

## Integration requirements before UI implementation

The present `active_calls` snapshot does not carry sufficient per-resident
notification eligibility. Never reconstruct an incoming queue from all global
active calls. Record targeted admission independently of modal presentation,
then reconcile each admitted identity and revision against Core. Resuming a
session may retain only still-valid targeted entries; recovering notifications
missed while disconnected requires an authoritative, identity-scoped Core
contract in the T31/T36 work. If eligibility cannot be established, show a
non-actionable synchronization state rather than guess another resident's scope.

A modal dialog must not consume a chime before the call has entered the queue.
Admission, notification and presentation are separate steps: a temporarily
covered screen still retains eligible calls and presents them when appropriate.
Existing ring playback in both AppDelegate and MainViewController must share
one policy, so adding a queue cannot introduce a second sound owner.

Capture an answer attempt's identity and generation before its asynchronous
work begins. SIP callbacks and delayed Core results may complete only that
attempt. Starting, declining or selecting another call invalidates the old
attempt; a generic SIP event cannot promote whichever row happens to be
selected later. Preserve the backend's winning-owner checks.

Queue semantics are common across supported shells, while UIKit layouts,
media capability and evidence remain per target. The Objective-C iOS 5
compatibility app needs its own implementation and qualification under T36;
no new feature is added to archival `ios-legacy`.

## Terminal transitions and bounded baseline

| Selected A changes while B waits | Required presentation |
|---|---|
| A cancels or expires | Remove A from the pending queue; retain its permitted monitoring context and local return policy, with call actions disabled. B remains explicitly selectable. |
| Another resident wins A | Release only the losing local leg; show the authoritative outcome without ending the winner. B remains waiting. |
| The resident ends A | End A's exact dialog; preserve B and require explicit selection/answer. |
| A's monitoring return timer fires after selecting B | The old timer has no effect on B or its controller. |
| A new call uses the same door | Treat it as a new identity; never reuse A's pending attempt, local-ignore receipt or terminal timer. |

Freeze the operation target at touch-down as well as activation; if the selected
identity changes before touch-up, cancel the gesture rather than applying it to
a new row. Missing identity fields in compatibility events require an exact
Core reconciliation before removing a queued item or ending a dialog.

Keep the first implementation's waiting rows text-only: zero thumbnail network
requests and zero waiting-row decoders. One selected live stream is the default
ceiling; dismissal, background, memory pressure and SOS must release or downgrade
it according to the existing platform policy. Preview snapshots are a later
qualified option with explicit concurrency, byte/pixel, age and eviction bounds.

The resident-session coordinator owns admission receipts, local order, selection
and notification policy. A changed resident identity retires all previous
receipts and pending attempts. A higher revision must revalidate its target set;
a locally ignored receipt is scoped to that identity/revision. An incomplete
snapshot does not itself prove a terminal state. Core must define a bounded,
identity-scoped admission/recovery result before the queue is advertised as
complete; overflow must be visible and reachable through that same authority,
without evicting the selected or connected item. The maximum retained metadata
and overflow behavior must be frozen and measured per target in T31/T36, not
inferred from the eight-call test.

Extend MC-01/11 with untargeted calls, changed targets/identity and incomplete
snapshots; MC-01/07/11/12 with a covering modal and repeated notifications;
MC-02–06/08 with pending answer and late SIP callbacks; MC-05/06/08/10 with
cancelled monitoring, same-door new calls and touch-down before a change;
MC-02/04/06/07/12 with all existing sound sources; MC-09/10/12 with overflow,
background and memory/SOS transitions. These are variants of the twelve cases,
not additional claims of runtime coverage.

## Additional acceptance scenarios

All scenarios below start at NOT_RUN. They supplement T36 rather than changing
the original task IDs or claiming existing plan coverage.

| ID | Scenario | Required observation |
|---|---|---|
| MC-01 | A and B ring before either is answered | Both visible; first selection and action target remain stable |
| MC-02 | B/C arrive while A is connected | A continues; waiting count/list updates; no automatic target switch |
| MC-03 | User selects B while A is still ringing | Selection changes explicitly and all actions/media identify B |
| MC-04 | Another resident answers B | Only B leaves the waiting queue; A continues |
| MC-05 | B cancels/expires while the user is selecting it | Core refuses stale action; no fallback to a different call |
| MC-06 | Same call receives a higher revision, then an old event | One updated item; old callbacks cannot mutate the winner |
| MC-07 | Ignore A locally | Other residents and B are unaffected |
| MC-08 | A ends while B waits | B stays available; no auto-answer or automatic unlock |
| MC-09 | Two, four and eight overlapping calls | Bounded media/resources; no overlapping hit targets or lost focus |
| MC-10 | Rotation/split view/large text during queue updates | Action identities and semantic positions remain stable |
| MC-11 | Foreground/resume with stale rows | Reconcile current eligible Core state before enabling actions |
| MC-12 | SOS coincides with normal calls | Existing alert/channel rules and clear semantics are preserved |

A fake Core transport/media boundary may drive repeatable UI scenarios, but it
must exercise the production queue/controller. Separate Core authority tests,
simulator layout evidence and actual iPad/iPhone runtime evidence. Do not
present a design mockup or screenshot as proof of concurrency correctness.

## Implementation placement

Implement the iOS resident subtask after the shared bridge lifecycle is stable
and preserve T36's operation, identity and media prerequisites. The queue is a
presentation projection of Core state, not a second call-owner state machine.
Keep its ordering/selection reducer testable with actual call identities; UIKit
owns layout. AppDelegate retains targeted-chime routing. Other resident shells
adopt the same semantics under their own T36 subreports and target gates.
