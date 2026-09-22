# Concurrent incoming-call design review

Date: 2026-09-22. Review type: independent source/design inspection only.
Verdict: the intended behavior is sound, but the implementation contract needs
the additions below before the queue can reliably provide that behavior.
No production code, task dependencies or acceptance status changed in this review.

Reviewed the current working tree, including existing uncommitted work, at base
HEAD `b26e0d346df99f2879915241b6e98d8ef1aa0707`. The source observations below are
not observations of that clean commit or a claim of device execution.

| Design | SHA-256 at review |
|---|---|
| `docs/en/concurrent-incoming-calls.md` | `34eee079a926c3f54f1150ba47f5d837ba2af011b68c5407b70bb076ec341900` |
| `docs/zh/concurrent-incoming-calls.md` | `4bf486a5442bd42b8aaecd07962c79349d527c6322204846d64774a878873076` |

The English and Chinese documents agree on the substantive requirements. Both
correctly identify replacement of an unanswered selection and silent rejection
of a different incoming call during conversation. This follows directly from
`ios/Doorbell/IncomingViewController.swift:172` and
`ios/Doorbell/AppDelegate.swift:521`. Their definition of concurrency as
overlapping calls, without delaying the first notification, is implementable.
Stable selection, one live stream, local Ignore, no implicit hold and no
automatic answer are appropriate constraints.

## Required design additions

### D1 — High: define the source and lifetime of resident eligibility

The requirement to reconcile current eligibility on resume has no complete
source in the existing snapshot. `core/src/node/node.cpp:8634` publishes call
identity, revision, owner, state and corrected timing, but no per-resident
notification eligibility or admission order. The source container is keyed by
door (`core/src/node/node.cpp:2082`), so its iteration order is not arrival order.
Core decides whether a chime targets this node while evaluating the rule's
device selection (`core/src/node/node.cpp:7707`), including the established
indoor fallback when no chime action exists (`core/src/node/node.cpp:7778`).

Specify which Core-authorized targeted notification admits each queue item and
how that admission is retained through backgrounding, reconnect and process
restart. Do not reconstruct eligibility from every replicated `active_calls`
row or reevaluate rules independently in UIKit. A saved admission still needs
current call/revision/authority validation before enabling actions. Define what
happens when a higher revision changes the target set, the resident identity
changes, or a snapshot is temporarily incomplete. Unknown eligibility must not
be represented as an actionable incoming call.

Preserve local admission order explicitly. Do not sort a recovered queue by the
door-sorted snapshot or invent historical arrival times. The compatibility
router already preserves one targeted receipt and treats temporary absence from
a snapshot differently from a matching terminal state
(`ios-kiosk/src/Screens/DBRouter.m:319`,
`ios-kiosk/src/Screens/DBRouter.m:342`). It is a useful existing semantic to
extend deliberately, not proof that a multi-call recovery store exists.

Acceptance detail: MC-01 and MC-11 must include an untargeted replicated call,
target changes across revisions, incomplete snapshots and an identity change.

### D2 — High: own queue admission outside the incoming modal

`ios/Doorbell/AppDelegate.swift:409` consumes the chime revision before
presentation. `ios/Doorbell/AppDelegate.swift:530` then returns if another modal
is presented. A repeated chime for that revision is rejected by the gate
(`ios/Doorbell/CallRevisionLifecycle.swift:56`). Putting the queue only in
`IncomingViewController` therefore still loses a call while settings or another
modal is visible. Dismissing that controller also destroys its media and event
subscription (`ios/Doorbell/IncomingViewController.swift:128`).

Specify a resident-session presentation coordinator that admits targeted calls
before attempting presentation, retains the queue independently of a visible
incoming controller and schedules presentation when the modal permits it. This
is a presentation projection, not a second authority for call ownership.
Define local Ignore/mute retention by exact identity and its behavior on higher
revisions. Ignoring A or yielding the incoming view to an SOS must not discard
waiting B. Current Ignore dismisses the complete screen
(`ios/Doorbell/IncomingViewController.swift:748`); current selected visual SOS
also closes it (`ios/Doorbell/IncomingViewController.swift:905`). Preserve the
existing SOS media/lifecycle policy while retaining independent pending rows.

Acceptance detail: exercise MC-01, MC-07, MC-11 and MC-12 with another modal
already visible, the incoming controller dismissed and a repeated chime.

### D3 — High: distinguish selected row, pending attempt and owned dialog

The design freezes a connected call but does not explicitly freeze an answer
attempt before connection. Current Answer may wait 400 ms after ending monitor;
the closure captures a host and later uses mutable controller state
(`ios/Doorbell/IncomingViewController.swift:693`). Selection replacement does
invalidate that timer, but native state callbacks remain global:
`ios/Doorbell/CoreBridge.swift:404` exposes generic SIP call/hangup and
`ios/Doorbell/IncomingViewController.swift:823` handles `in_call`/`idle` without
a call identity. `ios/Doorbell/IncomingViewController.swift:916` sets the screen
to connected before checking whether `reportCallAnswered` was accepted.

Specify an immutable pending operation context and local attempt generation,
separate from the currently browsed row. Bind delayed work, completion and media
callbacks to that context through the existing operation/identity prerequisites.
Either serialize selection during the pending transition, with a visible reason,
or cancel the exact pending attempt before explicitly starting another. A late
idle/in-call callback from A must not change B. A rejected answer must not be
presented as a confirmed owned dialog; reconcile authority and release only the
losing local leg. Do not emit a winner's call-ended event.

Core already validates exact call/revision and owner when reporting lifecycle
(`core/src/node/node.cpp:10893`, `core/src/node/node.cpp:10922`), and a monitor
does not claim the ringing call (`core/src/node/node.cpp:5332`). Retain those
checks. Do not assume they make an untagged UI callback safe. The native Unlock
button currently sends only a door (`ios/Doorbell/IncomingViewController.swift:803`);
the planned tuple validation must use the existing T06/T07 migration contract,
not an assertion that the current legacy entry point already checks the tuple.

Acceptance detail: MC-02 through MC-06 and MC-08 must include pending answer,
monitor-to-answer delay, another resident winning during that delay and late
callbacks after End A / explicit Answer B. No new dependency is proposed.

### D4 — High: make audible policy cover all current players

Incoming presentation is not the current ringtone owner.
`ios/Doorbell/MainViewController.swift:1402` independently accepts chimes and
plays configured audio without testing whether the resident is already in a
conversation. `ios/Doorbell/AppDelegate.swift:368` plays update sounds for raw
call events without checking whether that call targeted the resident. A queue
controller that adds a waiting beep would not prevent these existing sounds.

Name the single resident notification-policy owner and route the existing
ringtone and update-sound paths through it. Preserve configured normal/SOS
channels and administrative sound-only chimes. State how repeated revisions,
new revisions, locally ignored calls and untargeted raw updates affect audio,
visual and accessibility announcements. During A, a targeted B can produce only
the qualified configured waiting indication; an untargeted B cannot trigger a
new incoming sound simply because its state was replicated.

Acceptance detail: MC-02, MC-04, MC-06, MC-07 and MC-12 must observe every actual
audio source and distinguish waiting alerts from speech and SOS.

### D5 — Medium: specify terminal selection and monitoring retention

The design's "no eligible call remains" behavior is underspecified relative to
the existing deliberate resident video retention after cancellation.
`ios/Doorbell/CallRevisionLifecycle.swift:73` retains a cancelled visitor view
until the configured local return countdown, pauses it during a conversation
and allows the resident to stop it. Cancellation currently changes the label
without closing the screen (`ios/Doorbell/IncomingViewController.swift:888`).

Define the transition table for selected A ending/cancelling/being answered
elsewhere while B waits. Retaining A as a non-actionable monitoring context is
different from retaining A in the pending-call queue. State when explicit B
selection is required, whether A's local return countdown continues and how it
avoids dismissing B. If selection changes after a terminal event, invalidate any
old in-progress touch/activation so Unlock cannot acquire a new target under a
finger. A new call ID on the same door is a different item, not an update of A.

Identityless compatibility events cannot become queue-wide terminal signals.
Current `reply` handling checks only door, and some lifecycle matching permits
empty identity fields (`ios/Doorbell/IncomingViewController.swift:852`). Require
an exact matching authoritative reconciliation before destructive queue changes
when legacy events omit identity/revision.

Acceptance detail: MC-05, MC-06, MC-08 and MC-10 need cancelled monitoring,
same-door/new-call replacement, late identityless events and touch-down before a
selection/rotation update followed by touch-up afterwards.

### D6 — Medium: define bounded presentation and profile-specific capabilities

"Bounded snapshots" and testing eight calls do not define bounds. Specify queue
retention and visible-page behavior, thumbnail request concurrency, decoded
pixel/memory budgets, age and eviction, and cancellation when a cell is reused.
Overflow must remain visible and reachable without replacing a connected or
selected call. A thumbnail or stopped stream must not appear live. Text-only
waiting rows are the simplest baseline where snapshot resources are unqualified.
The selected live stream's lifetime must include dismissal, background, memory
pressure and SOS transitions; no hidden view may retain an extra active decoder.

Do not infer equivalent implementations from shared UX semantics. Modern Swift
hides call controls when PJSIP is unavailable and disables Answer/microphone/
Unlock on tvOS (`ios/Doorbell/IncomingViewController.swift:332`). The compatibility
router selects Core PJSIP or its own MiniSIP session at build time
(`ios-kiosk/src/Screens/DBRouter.m:787`). Its screen already invalidates delayed
answer work by generation (`ios-kiosk/src/Screens/DBIncomingScreen.m:1868`) and
supports an explicit JPEG/audio-only memory-safe fallback
(`ios-kiosk/src/Screens/DBIncomingScreen.m:1822`). Extend the applicable shell,
not archival `ios-legacy`, and preserve its existing ownership and fallback rules.

Record supported actions, notification channels, decoder/snapshot fallback and
layout/accessibility evidence separately for each actual supported OS/device
profile. Do not claim hold, haptics, full modern accessibility behavior or a
second dialog from a host build. MC-09/MC-10 need resource and hit-target evidence;
MC-12 needs memory/SOS transitions, not only a static screenshot.

## Acceptance and plan boundary

All **MC-01 through MC-12 remain NOT_RUN**. This review performed no simulator,
device, transport, physical lock or SOS execution and supplies no runtime PASS.
The variants above refine those twelve scenarios; they do not replace the
original T36-01 through T36-04 acceptance cases or add task prerequisites.

T36's existing prerequisites remain **T06, T07, T12, T13, T14, T17, T31, T35**.
Its original multi-shell implementation and evidence obligations remain intact.
Shared bridge lifecycle stability remains the design's placement condition;
this review does not convert it into a new numbered dependency or waive an
existing dependency. The proposed UI coordinator owns ordering, admission
receipts and selection only; authority, operation outcomes, call ownership and
media authorization remain with the established Core/contracts.

Review self-check: source anchors were read in the current working tree; every
referenced repository path/line was checked for existence. Only this review
artifact was written by this review task.

## Design response review — 2026-09-22

Response verdict: **ACCEPTED AS REQUIREMENTS; IMPLEMENTATION NOT RUN**. The
English/Chinese additions address D1–D6 at the design-requirement level. They do
not establish that missing Core recovery/capacity contracts or any queue code
already exist. The initial findings above are retained as review history.

| Finding | Response assessed |
|---|---|
| D1 | `docs/en/concurrent-incoming-calls.md:85` explicitly rejects rebuilding eligibility from global snapshots. `docs/en/concurrent-incoming-calls.md:132` specifies identity retirement, revision revalidation, local ordering, incomplete snapshots and authoritative bounded recovery. Missing offline recovery remains explicit work within T31/T36. |
| D2 | `docs/en/concurrent-incoming-calls.md:94` requires admission before presentation; the resident-session coordinator owns receipts and selection independently of modal lifetime. Ignore is scoped to identity/revision. |
| D3 | `docs/en/concurrent-incoming-calls.md:100` binds asynchronous answers and callbacks to one attempt and generation and invalidates old attempts when selection changes. Existing winning-owner checks and operation prerequisites remain. |
| D4 | `docs/en/concurrent-incoming-calls.md:94` includes AppDelegate and MainViewController playback in the same policy. The scenario variants explicitly exercise all existing sound sources, alongside the document's resident-targeting requirement. |
| D5 | `docs/en/concurrent-incoming-calls.md:111` defines terminal/monitoring/return-timer transitions. `docs/en/concurrent-incoming-calls.md:121` freezes touch-down identity and requires authoritative reconciliation for identityless compatibility events. |
| D6 | `docs/en/concurrent-incoming-calls.md:126` freezes the initial waiting view to text only: zero thumbnail requests and zero waiting-row decoders. One selected live stream, platform release/downgrade policy and separately qualified future snapshots are explicit. Metadata/overflow limits must be frozen and measured within existing T31/T36 work before claiming completeness. |

The corresponding Chinese additions at
`docs/zh/concurrent-incoming-calls.md:62` and
`docs/zh/concurrent-incoming-calls.md:79` preserve the same obligations. General
references earlier in each document to optional snapshots are constrained by
the later explicit text-only first-implementation baseline; they are not an
authorization to add waiting thumbnails without qualification.

| Updated design | SHA-256 reviewed |
|---|---|
| `docs/en/concurrent-incoming-calls.md` | `ab28f533eee655bdee4b00466313e7fd4db6516e884ea8009099b1ec2de23db9` |
| `docs/zh/concurrent-incoming-calls.md` | `a93b515c6abe8b436214c3b92f5c193d475d9b5354f91298f486994338ef8184` |

MC-01–MC-12 remain **NOT_RUN**. Original T36 prerequisites and multi-shell gates
remain unchanged. This response review edited only this review artifact and
adds no runtime or device claim.
