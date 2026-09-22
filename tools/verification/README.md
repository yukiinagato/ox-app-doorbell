# Production-path verification

T01's command inventory and observed results are in
`verification/remediation-q01-q18/T01/command-map.json`. Each executed command
has a separate JSON record and raw log. The source manifest hashes the tested
files, including untracked inputs; a Git revision alone does not identify a
dirty tree. Preserve old records when rerunning a command by choosing a new ID.

`record_command.py` runs one command in its own process group, records its exit
status, and terminates the group on timeout. Its `PASS` means the expected exit
code was observed. Behavioral conclusions and environment classification must
also reference the log. A missing executable is exit 127; a timeout is 124.
Do not put credentials in command arguments or evidence manifests. Pass
`--task-id` for a later task or integration batch; the default remains `T01` for
compatibility with the original command inventory.

`check_mutation_sensitivity.py --repo <checkout> --scratch <owned-directory>`
copies the actual Web production module and its existing tests into a temporary
directory. It runs the original test, removes the late-media-stream cleanup
branch, requires the existing behavioral assertion to fail, restores the branch,
and requires the same test to pass. The temporary copy is removed afterwards.
This verifies the test's sensitivity; it is not a product fix.

`browser_fixture.cpp` links the actual Core library. It starts `Node`, `Runloop`,
SQLite storage, and the embedded HTTP UI, using `InMemNet` instead of a real mesh.
Build it with the recorded `browser-fixture-build-r2` command. Run the resulting
binary with a new disposable data directory and an unused port. The fixture
uses the public test-only password `T01-local-test-only`. Existing database
directories are unsuitable because initial password setup must succeed.
The production HTTP listener can bind all host interfaces; this fixture does
not claim network sandboxing. Do not use production configuration or secrets.
Terminate it with SIGTERM, await exit, then verify port reuse and exclusive
database reopening before removing its owned data directory.

## Local toolchains

For this workstation, the project memory's stable configuration was verified:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/Users/ox/Library/Android/sdk
export PATH="$JAVA_HOME/bin:$PATH"
```

The system Java launcher can report no runtime even when this JDK exists.
Run Android modern and legacy19 invocations sequentially with their explicit
`doorbellTier`; native cache entries must retain their API and NDK identities.
Modern uses NDK 27.1.12297006; legacy19 uses 25.2.9519653.

The local iOS 5 lane uses `tools/sdk/iPhoneOS7.1.sdk` and
`tools/toolchain/ios5-armv7`. For a dirty checkout, provide `DB_ALLOW_DIRTY=1`
and an explicit `DB_BUILD_ID`. Build and install the Core archive locally with
`ios-compat/scripts/build_core_ios5.sh --install` before running
`ios-compat/scripts/build_app_ios5.sh`. Here `--install` only copies the archive
to the ignored `ios-kiosk/lib` directory; it does not deploy to a device.

The separate iOS 9 armv7 formal profile requires a commissioned Xcode 7 / iOS 9.x
SDK lane. The iOS 5 SDK is not a substitute. Record an unmet license-attestation
gate as such; do not infer that every historical SDK is absent. The shared Swift
iOS 9 arm64 entry is `ios/scripts/build_ios9_arm64.sh` and is a different lane.

## Evidence boundaries

The fault map identifies actual production dependencies and deterministic
controls. Existing C callback barriers do not prove Swift acquire/stop safety.
Web fake-XHR timeouts do not prove HTTP queued-write cancellation. These remain
separate acceptance work in their dependent task cards. Browser login/navigation
smoke tests do not qualify media decoding, physical locks, device lifecycle,
old operating systems, or a real multi-node network.
