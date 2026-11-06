#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/build/ios-compat/host-tests"
mkdir -p "$OUT"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -I"$ROOT/ios-compat/tests/style-fakes" -I"$ROOT/ios-kiosk/src/Core" \
  "$ROOT/ios-kiosk/src/Core/DBSemanticStyle.m" \
  "$ROOT/ios-compat/tests/semantic_style_cache_test.m" \
  -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$OUT/semantic_style_cache_test"
"$OUT/semantic_style_cache_test"
