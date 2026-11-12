#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-time-settings-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/time-settings-test.exe" \
  "$ROOT/win/DoorbellApp/Settings/TimeSettings.cs" \
  "$ROOT/win/tests/TimeSettingsTests.cs"
mono "$TMP/time-settings-test.exe"
