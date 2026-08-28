#!/bin/bash
# Xcode run-script phase: doorbell-core を CMake で現在のプラットフォーム向けに静的ビルドし、
# 依存 (third_party + pjsip プリビルド) と 1 本の libdoorbell_all.a に束ねる。
# xcodebuild -project ios/Doorbell.xcodeproj だけで完結する (CI 前提) — 必要なのは
# cmake と python3 (webui 資産埋め込み) だけ。pjsip プリビルド
# (core/third_party/pjsip/ios/<platform> — tools/build_pjsip_ios.sh) が無ければ
# sipctl はスタブになる (SIP 無し・他機能はフル)。
#
# Xcode から渡る環境: SRCROOT / PLATFORM_NAME (iphoneos|iphonesimulator|appletvos|
# appletvsimulator) / ARCHS。手動実行も可:
#   PLATFORM_NAME=iphonesimulator SRCROOT=ios ./ios/scripts/build_core.sh
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
ARCHS="${ARCHS:-arm64}"
CORE="$SRCROOT/../core"
BUILD_DIR="$SRCROOT/build/core/$PLATFORM_NAME"

# cmake は Xcode のスクリプト PATH に居ないことが多い — 常用の場所を探す
CMAKE="$(command -v cmake || true)"
for c in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
  [[ -z "$CMAKE" && -x "$c" ]] && CMAKE="$c"
done
[[ -n "$CMAKE" ]] || { echo "error: cmake が見つからない (brew install cmake)"; exit 1; }

# ARCHS は空白区切り → CMake のセミコロン区切りへ
CMAKE_ARCHS="${ARCHS// /;}"

# アーキ構成が変わったら CMake キャッシュを捨てる (CMAKE_APPLE_ARCH_SYSROOTS の残骸対策)
STAMP="$BUILD_DIR/.arch_stamp"
if [[ -f "$STAMP" && "$(cat "$STAMP")" != "$CMAKE_ARCHS" ]]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
echo "$CMAKE_ARCHS" > "$STAMP"

"$CMAKE" -S "$CORE" -B "$BUILD_DIR" \
  -DCMAKE_MAKE_PROGRAM="$(command -v make || echo /usr/bin/make)" \
  -DCMAKE_TOOLCHAIN_FILE="$CORE/cmake/ios.cmake" \
  -DDB_APPLE_PLATFORM="$PLATFORM_NAME" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHS" \
  -DDB_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build "$BUILD_DIR" --target doorbell_core -j "$(sysctl -n hw.ncpu)"

# 静的 lib を 1 本へ (アプリは -ldoorbell_all だけリンクすればよい)
LIBS=("$BUILD_DIR/libdoorbell_core.a" "$BUILD_DIR/libdb_third_party.a")
PJROOT="$CORE/third_party/pjsip/ios/$PLATFORM_NAME"
if [[ -d "$PJROOT/lib" ]]; then
  while IFS= read -r -d '' f; do LIBS+=("$f"); done \
    < <(find "$PJROOT/lib" -name 'lib*.a' -print0 | sort -z)
fi
xcrun libtool -static -no_warning_for_no_symbols -o "$BUILD_DIR/libdoorbell_all.a" "${LIBS[@]}"
echo "ok: $BUILD_DIR/libdoorbell_all.a (${#LIBS[@]} archives)"
