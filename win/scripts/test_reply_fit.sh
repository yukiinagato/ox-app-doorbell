#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-reply-fit-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/reply-fit-test.exe" \
  "$ROOT/win/DoorbellApp/Ui/ReplyFit.cs" \
  "$ROOT/win/DoorbellApp/Ui/ReplyDismissGuard.cs" \
  "$ROOT/win/tests/ReplyFitTests.cs"
mono "$TMP/reply-fit-test.exe"
