#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-role-contrast-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/role-contrast-test.exe" \
  "$ROOT/win/DoorbellApp/Util/RoleContrast.cs" \
  "$ROOT/win/tests/RoleContrastTests.cs"
mono "$TMP/role-contrast-test.exe"
