#!/usr/bin/env bash
# Phase B: doorbell-core (C++17) を Phase A0 の armv7/iOS5.1 toolchain でクロスビルドし、
# core + capi + third_party を 1 本の libdoorbell_all.a に束ねて armv7 を検証する。
#
# 実機 (旧 iPad 第1/2世代) は無いので検証上限はコンパイル+リンク成功 + lipo/otool/nm 確認。
# 使い方:  bash ios-legacy/scripts/build_core_ios5.sh
#
# 前提:
#   * tools/toolchain/ios5-armv7/{lib,include}  (Phase A0 の自前 libc++ — gitignore)
#   * tools/sdk/iPhoneOS7.1.sdk                 (Xcode DMG から展開 — gitignore)
# どちらも core/cmake/ios5-armv7.cmake が存在確認する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE="$ROOT/core"
BUILD_DIR="$ROOT/build-ios5"
OUT_DIR="$ROOT/ios-legacy/lib"
TC="$ROOT/tools/toolchain/ios5-armv7"

CMAKE="$(command -v cmake || true)"
for c in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
  [[ -z "$CMAKE" && -x "$c" ]] && CMAKE="$c"
done
[[ -n "$CMAKE" ]] || { echo "error: cmake が見つからない (brew install cmake)"; exit 1; }

echo "== configure (armv7 / iOS 5.1) =="
"$CMAKE" -S "$CORE" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$CORE/cmake/ios5-armv7.cmake" \
  -DCMAKE_BUILD_TYPE=Release

echo "== build doorbell_core =="
"$CMAKE" --build "$BUILD_DIR" --target doorbell_core -j "$(sysctl -n hw.ncpu)"

echo "== bundle -> libdoorbell_all.a (core + capi + third_party) =="
# core (capi 含む) + third_party を 1 本に。iOS 殻 (ObjC/Swift) は -ldoorbell_all だけで済む。
mkdir -p "$OUT_DIR"
ALL="$OUT_DIR/libdoorbell_all.a"
xcrun libtool -static -no_warning_for_no_symbols \
  -o "$ALL" \
  "$BUILD_DIR/libdoorbell_core.a" \
  "$BUILD_DIR/libdb_third_party.a"

echo
echo "===== VERIFY ====="
echo "-- lipo -info --"
lipo -info "$ALL"

echo "-- 最小デプロイ (LC_VERSION_MIN_IPHONEOS は各 .o に。archive 内 1 つを抜き出して確認) --"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && ar x "$ALL" common.cpp.o 2>/dev/null || true )
if [[ -f "$TMP/common.cpp.o" ]]; then
  otool -l "$TMP/common.cpp.o" | grep -A2 LC_VERSION_MIN_IPHONEOS | sed 's/^/   /'
fi

# 未解決 (外部未定義) 記号の検査。C++ ランタイム記号 (___cxa_*, __ZNSt*, unwind) は
# 殻の最終リンクで静的 libc++/libc++abi/libunwind + builtins が供給する — ここでは
# 「iOS 5.1 の libSystem に存在しない post-iOS5 記号」がゼロであることだけ確認する。
echo "-- post-iOS5 libc 記号 (存在してはいけない: 0 であること) --"
BAD="$(nm -u "$ALL" 2>/dev/null | grep -Eo '_(aligned_alloc|clock_gettime|__emutls_get_address|arc4random(_buf|_uniform)?|getentropy|timespec_get)\b' | sort -u || true)"
if [[ -n "$BAD" ]]; then
  echo "   NG: 以下の post-iOS5 記号が未定義参照にある:"; echo "$BAD" | sed 's/^/     /'
  exit 1
else
  echo "   OK: aligned_alloc / clock_gettime / __emutls_get_address / arc4random / getentropy / timespec_get いずれも無し"
fi

echo
echo "ok: $ALL"
lipo -info "$ALL"
