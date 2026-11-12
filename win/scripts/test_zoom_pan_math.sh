#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-zoom-pan-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/zoom-pan-test.exe" \
  "$ROOT/win/DoorbellApp/Ui/ZoomPanMath.cs" \
  "$ROOT/win/tests/ZoomPanMathTests.cs"
mono "$TMP/zoom-pan-test.exe"
