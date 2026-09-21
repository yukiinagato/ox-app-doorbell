# Repair execution report — 2026-09-22

Repository / branch: `app-doorbell` / detached baseline worktree

Base full SHA / final full SHA: `0fbeed4720efb25dafb79083f86d4c21c39f5087` / uncommitted working tree

Dirty files present before work: none. `HEAD` was the specified base and `git diff 0fbeed4` was empty.

Affected deliverables and version/build changes: Android `0.3.16` / `17`; modern iOS `0.1.32` / `33`; iOS kiosk `0.3.44` / `47`; Windows `0.1.11` / `0.1.11.8`.

Files changed by this task: Core authentication, C ABI callback, and VideoTrack sources and tests; Web admin source and runtime test; generated localization resources from `i18n/strings.yaml`; application version manifests; this English report and its Japanese and Chinese translations. No evidence scripts were changed.

## Implemented repairs

| Task | Status | Production implementation | Regression coverage |
| --- | --- | --- | --- |
| R1 | IMPLEMENTED | Authentication reads, lockout state, migration, and password replacement now execute in one Runloop operation. Rejected scheduling returns a non-success result. | `[R1] capi serializes concurrent administrator password changes`; existing HTTP durability and C ABI password tests. |
| R2 | IMPLEMENTED | C callbacks use immutable paired callback slots with disable-before-detach and in-flight draining. Header documents the self-unregistration exception. | `[R2] capi unregister drains an entered UI callback`. |
| R3 | IMPLEMENTED | Readers that miss fragments wait for a parsed IDR past a recovery barrier; producer `key` hints cannot create recovery points. | `[R3] VideoTrack waits for a parsed IDR after a reader gap`; existing fMP4 round-trip. |
| R4 | IMPLEMENTED | XHR has a single settled completion path, bounded request timeout, contextual 401 handling, valid-login response validation, and distinct localized login errors. | `webui/tests/admin_runtime.test.js` executes the production login handler for 401, 429, and duplicate completion notification. |
| R5 | IMPLEMENTED | Authentication generations gate callbacks; an idempotent runtime owns one timeout-based polling chain and stop clears it with pairing and scanning resources. | `webui/tests/admin_runtime.test.js` exercises duplicate boot and stop. |
| R6 | IMPLEMENTED | Every scan owns a session identity and resources. Stale camera results stop their tracks; dispose is idempotent and covers timer, video, tracks, and DOM. | `webui/tests/admin_runtime.test.js` exercises A-close-B-open stale and current stream cleanup. |

## Actual commands and logs

| Command | Exit / result | Log |
| --- | --- | --- |
| `cmake --build build/repair-host --parallel 4` | 0 / PASS | `build/repair-host/repair-build.log` |
| `doorbell_tests --test-case='[R1]*,[R2]*,[R3]*'` | 0 / PASS, 26 assertions | `build/repair-host/repair-core-targeted.log` |
| Related HTTP, C ABI, fMP4 tests | 0 / PASS, 1,776 assertions | `build/repair-host/repair-core-related.log` |
| All `webui/tests/*.test.js` | 0 / PASS | `build/repair-host/repair-web-all.log` |
| `gen_i18n.py --check`; English-source check; diff check | 0 / PASS | `build/repair-host/repair-i18n.log`, `repair-english.log`, `repair-diff-check.log` |
| `ios-compat/scripts/test_host.sh` | 0 / PASS | `build/repair-host/repair-ios-compat-host.log` |
| Android modern Gradle build/test/lint | BLOCKED: Java Runtime unavailable | `build/repair-host/repair-android-modern.log` |

The initial aggregate `ctest` baseline run did not complete in this host session and was stopped after duplicate invocations. It is not reported as PASS. Targeted Core coverage above ran against the changed production implementation.

## Validation matrix and remaining limitations

| Area | Result |
| --- | --- |
| Host Core, targeted authentication/callback/video tests | PASS |
| Web pure logic and browser-runtime harness | PASS |
| Real HTTP integration | PASS for existing password durability path; concurrent native/Web migration scenario NOT RUN |
| Real VideoTrack software decode after recovery | NOT RUN; fMP4 production round-trip PASS |
| TSan; ASan/UBSan | NOT RUN |
| Android modern / legacy19 | BLOCKED: no Java Runtime; legacy19 not attempted after the same prerequisite failure |
| Modern iOS and iOS compatibility device builds | NOT RUN; compatibility host suite PASS |
| Windows build and host bridge | NOT RUN |
| Real browser and real devices | NOT RUN, including iPad mini 1 / iOS 9.3.6 / armv7 |

Additional findings outside R1–R6: none.

Publish/deployment actions performed: none.
