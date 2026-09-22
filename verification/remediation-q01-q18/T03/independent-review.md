# T03 independent review

Date: 2026-09-22. Reviewer: `/root/t02_translation`.
Result: PASS within the T03 production-test scope; no blocking executable defect found.
The reviewer did not implement T03. Production files were not changed during this review.

## Reviewed source

HEAD: `b26e0d346df99f2879915241b6e98d8ef1aa0707`, with the incoming and current dirty tree.
The full tracked diff at review capture has SHA256
`1eecaae3d3d9368f64c0669e62677594ebbc52c78c7952d6418ca8b7f82961fe`.
Concurrent tasks may change the overall diff independently. Exact reviewed file hashes,
commands, exit codes, timestamps and raw log hashes are recorded in
`evidence/independent-review.json` (SHA256
`8a44a10fd48b16d9e5e86c8c876e2eb6e35f486d069ec6e0f1f8ad63f36f672e`).

Key source hashes:

| File | SHA256 |
|---|---|
| `core/src/node/node.cpp` | `8c110ca3f4199ab121da9c06784fc1d59a847a60d94427da1c721ed1da8f719e` |
| `core/src/capi/doorbell_capi.cpp` | `0522403739317e90bc469195bb1c157182ca5116474772a7997f559c2542dd6c` |
| `webui/admin/app.js` | `b0738afbd726c5ef7288a2283437b7e81d8e6205531185513724ae974a950f5b` |
| `i18n/strings.yaml` | `6db958d561364a1a16852c90c5c11c17129183a41312a4f39f2462fe022e88e5` |

## Contract and path checks

- `unlockCommandFor` reads only the selected door's explicit `unlock.command`.
  Both the status projection and `openDoorOnLoop` reuse it; removing A's binding cannot select
  B's binding or the first SIP HA action. The door-existence check remains intact.
- The HTTP route keeps authentication and unknown-door checks. Forced button visibility does
  not authorize execution. The native ABI's cached status check is not the final authority:
  `Node::openDoor` still rechecks the binding on the Core loop before appending the intent.
- The command validator continues to restrict explicit values to 1–32 allowed ASCII characters.
  SIP DTMF parsing and `execDtmfAction` are unchanged; their independent HA actions remain usable.
- The Web editor derives its initial value from this door's configuration, not from a legacy
  status result or the first suggestion. The production `textlist` renderer uses a text input
  and datalist, so a suggestion is not an automatically selected binding. Saving an empty
  command removes it; visibility-only changes do not create a command. Explicit saves remain
  scoped to the selected door and do not rewrite feature codes.
- English, Japanese and Chinese catalog entries consistently require administrator confirmation,
  explain blank-to-remove behavior and report the same command validation bounds. The three
  configuration documents describe explicit migration and separate accepted intent from physical
  unlocking. The generator reports all 15 generated files current.

## Evidence inspected and checks executed

The recorded red run fails actual behavior assertions: a light feature code incorrectly marked
unlocking configured, emitted a command and returned success. It is not a compile-error surrogate.
The green Core run covers the four task subcases, the native ABI path and related visibility/
notice behavior: 4 doctest cases, 250 assertions, exit 0. Every relevant source hash in the green
record matched the files inspected by this review. The existing Web theme and admin runtime
records also matched their reviewed source hashes.

The independent review additionally executed the following in
`/Users/ox/Documents/project/app-doorbell`; all exited 0:

| Command | Observed result | Raw log |
|---|---|---|
| `node build/remediation-t03-20260922/review-ui.cjs` | Executed the production editor and field renderer with the real AdminLogic export: blank default despite a stale configured status, no implicit suggestion, explicit save, clear, invalid input and three locales passed | `evidence/review-editor.log` |
| `node webui/tests/theme_notice.test.js` | Unlock planning and existing theme/notice checks passed | `evidence/review-theme.log` |
| `node webui/tests/settings.test.js` | Existing settings and call-return checks passed | `evidence/review-settings.log` |
| `python3 tools/gen_i18n.py --check` | 15 generated files current | `evidence/review-i18n.log` |

## Non-blocking finding and limits

One stale route comment at `core/src/node/node.cpp:10009` still states that an installation
already wired to the command topic needs no new configuration. That sentence contradicts the
new explicit-binding migration. The primary agent accepted deleting it after the already-running
builds finish, avoiding source changes during compilation. This is a comment-only cleanup; the
source hashes above intentionally identify the executable source reviewed before that cleanup.
The integration manifest must record the final file hash.

Core evidence counts persisted `dtmf_action` intents and native callback dispatches. It does not
prove MQTT delivery, physical actuator execution or exactly-once opening. No real lock or SOS was
invoked. This review did not repeat the full Core suite or platform builds, and did not exercise
a real browser datalist or old-device UI. Application version/build changes, regenerated embedded
assets, platform builds and device qualification remain the primary integration task's evidence.
Pre-existing config concurrency, HTTP scheduling and operation-identity limitations belong to
their respective remediation cards and are not closed by T03.
