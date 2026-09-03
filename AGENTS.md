# Repository working agreement

English is the source language for code, identifiers, comments, logs, tests,
build scripts, CI, the root README, and documentation without a language
suffix. Keep Japanese and Chinese translations under `docs/ja`, `docs/zh`, or
files ending in `.ja.md` and `.zh.md`; update them whenever the English source
changes. Application strings come only from `i18n/strings.yaml` and are
generated with `tools/gen_i18n.py`.

## Architecture sources of truth

- `core/include/doorbell/doorbell.h` is the public native ABI. New clients use
  `db_platform_v2`; the legacy struct exists only for one compatibility cycle.
- Core events, versioned configuration, capabilities, rules, and runtime status
  define cross-platform behavior. A client may advertise only features it has
  measured and actually implements.
- `docs/en/config-schema.md` documents persisted configuration. Secrets are
  stored through platform secure storage and referenced as `secret:<name>`;
  never place credentials in URLs, events, logs, or `boot.json`.
- `i18n/strings.yaml` is the only source for user-facing translations.
- `ios-compat` owns the Objective-C compatibility foundation and neutral iOS 5
  tooling. `ios-legacy` is archival UI and must not acquire new features.
  It remains byte-for-byte comparable with the local final tag and is excluded
  from source-language cleanup until the documented hardware rollback gate permits deletion.

## Build and verification

Every change to a shippable application's source or bundled resources must
increment that application's user-visible semantic version and numeric build
number in the same change. Bump only the affected deliverables: Android uses
`android/app/build.gradle.kts`, modern iOS uses `ios/Doorbell/Info.plist`, and
the iOS 5 compatibility app uses `ios-kiosk/src/Info.plist`. Verify deployments
from the version and build number reported by the device; hashes remain an
artifact-integrity check rather than the primary way to identify a release.

```sh
cmake -S core -B build -DDB_WITH_PJSIP=OFF
cmake --build build -j4
./build/doorbell_tests

python3 tools/gen_i18n.py --check
python3 tools/check_english_source.py

(cd android && ./gradlew --no-daemon \
  assembleModernDebug testModernDebugUnitTest lintModernDebug)
(cd android && ./gradlew --no-daemon -PdoorbellTier=legacy19 \
  assembleLegacy19Debug testLegacy19DebugUnitTest lintLegacy19Debug)

ios-compat/scripts/test_host.sh
ios-compat/scripts/build_core_ios5.sh
ios-compat/scripts/build_app_ios5.sh
```

Release builds must fail if they link the SIP stub. Native artifacts must record
the toolchain, target OS/API, architecture, dependency hashes, source revision,
and signing identity. Keep artifacts for different platform, architecture,
minimum OS/API, SIP backend, and signing profile in separate directories.

## Legacy toolchains

- Android API 19 is pinned to NDK r25c (`25.2.9519653`); modern Android uses
  NDK r27. Never share native caches between those lanes.
- iOS 5.1/armv7 uses the licensed local historical SDK and compatibility libc++.
  Do not commit Apple SDKs or generated static libraries.
- iOS 9/armv7 requires its own historical-SDK signing lane. iOS 9/arm64 shares
  modern Swift sources through availability adapters; do not fork another UI.
- Public pull requests must never execute on a trusted signing or jailbreak
  runner. Hardware qualification remains a release gate, not a CI claim.

## Safe changes

The worktree may contain user-owned changes. Inspect and preserve them; never
reset, discard, or overwrite unrelated edits. Use deterministic temporary
directories for experiments. Do not commit secrets, signing material, ignored
binary inputs, or vendor SDKs. Do not push code, tags, releases, Wiki changes,
or deployment state without explicit user authorization.

Keep comments only when they explain an API contract, ownership/lifetime,
threading, a security decision, or a required old-OS/hardware workaround.
Remove narration, completed phase notes, obsolete TODOs, commented-out code,
and documentation duplicated inline.
