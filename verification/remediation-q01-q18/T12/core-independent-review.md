# T12 Core panel operation adapter: independent review

Reviewer: t02_translation. Date: 2026-09-23 JST. Result: PASS within the frozen host-production scope after R1 was corrected.

This reviewer implemented the Web consumer but did not implement the Core adapter. Review used the immutable `build/remediation-t12-20260923/green-source` tree, the frozen Core source manifest, actual production HTTP test code, and its raw red/green logs. No production Core files were changed by the reviewer.

## Finding history

**R1 (blocking, resolved): mixed administrator and panel cookies selected the wrong principal.** The first adapter preferred any valid `dbsess` before checking the panel CSRF. A user logged into Admin in the same browser therefore had panel requests rejected, and signing into Admin between preparation and execution could change the effective creator. The final adapter recognizes a live `dbpanel` plus matching server-held panel CSRF first. This selector grants no additional permission: the panel branch still restricts the action, Origin, CSRF, live credential and node grant. The actual HTTP tests now prepare with a panel, add a valid admin cookie before query/execute, and also prepare with both cookies then query with only the original panel. Both paths preserve the same creator.

## Reviewed boundaries

- `operationHttp` performs only bounded preliminary admission; `operationRequestOnLoop` repeats live session authorization on the Core loop. A random cookie-shaped value is not enough to pass final authorization.
- No HTTP body chooses authentication kind or subject. The adapter hashes the server-recognized short-lived session and combines it with the authenticated originating node. The hash is not returned in operation JSON and is not a long-lived panel identity.
- Only `sos_start` is admitted for this transition adapter. Panel requests cannot acquire `door_open` or `sos_clear`, even if the page node has those separate native/admin grants.
- A current `devices.<node>.operations.sos_start` grant and the configured fixed authority are required on both sides. SecureChannel supplies the originating node; forwarded subject/credential/grant assertions are accepted only through this trusted node path. No browser Cookie or long-lived panel bearer is forwarded.
- All panel operation methods require the random session CSRF. Mutations require the exact trusted Origin; GET permits browsers that omit Origin, while checking it if supplied. No wildcard CORS or broad Origin fallback was introduced.
- The durable ledger principal includes authentication kind, originating node and session hash. A second legitimate session cannot execute or query the creator's operation. Credential generation changes invalidate old sessions. A renewed session does not gain ownership of the old handle.
- The existing durable prepare/execute/query and dispatcher transaction/deadline boundaries remain intact. This change does not provide independent panel provisioning, instant partition-wide credential revocation, notification delivery, or physical-action confirmation.

## Evidence and source identity

`evidence/panel-red.log` has three real HTTP cases failing against the old adapter with 401 at preparation. `evidence/panel-green.log` passes **3 cases and 195 assertions**, including lost execution response with one event, repeated queries/execute of one handle, a second session, unsupported actions, CSRF, Origin, grant revocation, credential revocation and mixed-cookie context. Commands and exits are recorded in `panel-red.json` and `panel-green.json`.

The reviewer inspected these results and their test assertions rather than rerunning an unrelated full build. The source manifest SHA256 is `fa033ca5f5f306b80b20ab195fd5b5d443dd95a204a21fe9496fff8e3e17c7aa`.

| Frozen source | SHA256 |
|---|---|
| `core/src/node/operation_service.inc` | `ce565d423fee1c1eb6598c64978ba86960c08fe08b1a8e800fc505a443dfe28b` |
| `core/src/node/node.cpp` | `50c8adc056cb18270ba3512f4d416eafbe9b0575a887dad17773bb83b8698ef2` |
| `core/src/store/operation_ledger.cpp` | `9cfc69af9a873a8d26210b859a1cefa23e2b0964967d9a484f463a906cc1ec5b` |
| `core/src/node/operation_dispatcher.cpp` | `8d95509a4587addaea4474aa6cf3b7d2287498ff1ab5c8bb8ee7d54b47cd8bc5` |
| `core/tests/test_panel_operations.cpp` | `a5d03ea06464ce038006373c8fb8a1a074708f06a48de83b37e039c069a5bcd9` |

## Qualification limits

Two real host Nodes and real local HTTP/mesh requests were used by the recorded test run. No real SOS recipient, physical actuator, browser engine, embedded WebView, signed application, or device was exercised. Web consumer evidence is separate. The runtime reads the actual session response field `csrf_token`; the earlier Web fixture mismatch was independently caught during this review and corrected with a preserved red test. T15's locked-Mac simulator qualification is unrelated and remains open.
