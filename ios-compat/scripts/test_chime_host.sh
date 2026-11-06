#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/ios-compat/host-tests"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -I"$ROOT/ios-compat/tests/chime-fakes" \
  -I"$ROOT/ios-kiosk/src/Media" \
  "$ROOT/ios-kiosk/src/Media/DBSiren.m" \
  "$ROOT/ios-kiosk/src/Core/DBBootConfig.m" \
  "$ROOT/ios-compat/tests/chime_async_test.m" \
  -framework Foundation -o "$OUT/chime_async_test"
"$OUT/chime_async_test"
