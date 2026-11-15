#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-settings-writes-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/settings-writes-test.exe" \
  "$ROOT/win/DoorbellApp/Settings/WriteLane.cs" \
  "$ROOT/win/tests/SettingsWriteTests.cs"
mono "$TMP/settings-writes-test.exe"
