#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT="$REPO_ROOT/build/helper-tests"
CC="${CC:-$(command -v clang || command -v cc)}"

mkdir -p "$OUTPUT"
"$CC" -std=c99 -Wall -Wextra -Werror -O2 -DDB_KEEPALIVE_TESTING \
  "$SCRIPT_DIR/doorbell_keepalive.c" -o "$OUTPUT/doorbell-keepalive-test"
"$CC" -std=c99 -Wall -Wextra -Werror -O2 \
  "$SCRIPT_DIR/tests/test_app.c" -o "$OUTPUT/doorbell-keepalive-test-app"
python3 "$SCRIPT_DIR/tests/test_keepalive.py" \
  --helper "$OUTPUT/doorbell-keepalive-test" \
  --test-app "$OUTPUT/doorbell-keepalive-test-app"
