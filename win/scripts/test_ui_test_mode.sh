#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-ui-test-mode-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/ui-test-mode-test.exe" \
  "$ROOT/win/DoorbellApp/Util/UiTestMode.cs" \
  "$ROOT/win/tests/UiTestModeTests.cs"
mono "$TMP/ui-test-mode-test.exe"
