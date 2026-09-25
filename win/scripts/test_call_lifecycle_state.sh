#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-call-lifecycle-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/call-lifecycle-test.exe" \
  "$ROOT/win/DoorbellApp/Core/CallLifecycleState.cs" \
  "$ROOT/win/DoorbellApp/Core/PeerFrameUrlBuilder.cs" \
  "$ROOT/win/DoorbellApp/Core/CallTiming.cs" \
  "$ROOT/win/DoorbellApp/Core/PeerFrameGate.cs" \
  "$ROOT/win/tests/call_lifecycle_state_test.cs"
mono "$TMP/call-lifecycle-test.exe"
