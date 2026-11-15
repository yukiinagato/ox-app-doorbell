#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-visitor-flow-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -r:System.Web.Extensions.dll -out:"$TMP/visitor-flow-test.exe" \
  "$ROOT/win/DoorbellApp/Core/VisitorFlow.cs" \
  "$ROOT/win/tests/VisitorFlowTests.cs"
mono "$TMP/visitor-flow-test.exe" "$ROOT/tools/conformance/fixtures/visitor-flow-v1.json"
