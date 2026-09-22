# T09 independent integration review

Reviewer: `/root`. Result: PASS_IN_SCOPE after the early-state-failure fix.

The first revision could stall the next load when state failed before call-info:
the load gate reopened at two seconds, while the four-second call-info lane
remained occupied. The second load received no handle and its Promise never
settled. A production-page regression reproduces that failure. The revised page
retires only its own request in `finally` and rejects refused lane admission.
Tests also cover old-page cleanup after a new page starts a successor request.

The shared ES5 request adapter preserves single settlement, bounded timers,
transport cancellation and request generation. It does not automatically retry
writes. Its current integration is limited to call-info; separate state, locale
and heartbeat scheduling remains in later cards. All 14 Web test scripts pass
against the combined candidate. This is host production-module evidence, not
old-browser or hardware qualification. Browser interaction was blocked by an
open Chrome extension UI and a disconnected IAB backend.

Exact reviewed file hashes and raw evidence paths are recorded in
`evidence/independent-review.json`.
