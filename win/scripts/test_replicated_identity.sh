#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-replicated-identity-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -out:"$TMP/replicated-identity-test.exe" \
  "$ROOT/win/DoorbellApp/Util/ReplicatedIdentity.cs" \
  "$ROOT/win/tests/ReplicatedIdentityTests.cs"
mono "$TMP/replicated-identity-test.exe"
