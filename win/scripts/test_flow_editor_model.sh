#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/doorbell-win-flow-editor-model-test"
mkdir -p "$TMP"
csc -nologo -langversion:7.3 -r:System.Web.Extensions.dll -out:"$TMP/flow-editor-model-test.exe" \
  "$ROOT/win/DoorbellApp/Core/FlowEditorModel.cs" \
  "$ROOT/win/DoorbellApp/Core/FlowIcons.cs" \
  "$ROOT/win/tests/FlowEditorModelTests.cs"
mono "$TMP/flow-editor-model-test.exe"
