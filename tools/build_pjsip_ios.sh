#!/usr/bin/env bash
# iOS 用 pjsip 静的ライブラリのクロスビルド (configure-iphone)。
# 産物: core/third_party/pjsip/ios/{iphoneos,iphonesimulator}/{lib,include}
#       (gitignore 済みパス — プラットフォーム名は Xcode の $(PLATFORM_NAME) と同語彙)
#
# - 実機 arm64 + シミュレータ arm64 (Apple Silicon)。PLATFORMS="iphoneos" 等で絞れる。
#   x86_64 Mac のシミュレータは SIM_ARCH=x86_64 で。
# - 音声のみ (ホスト版 build_pjsip_host.sh と同等の --disable 群)。
#   バックエンドは CoreAudio (AudioUnit) — VoiceProcessingIO (AEC/AGC 内蔵) は
#   coreaudio_dev.m が実行時に検出して自動選択する (PJ_CONFIG_IPHONE の既定)。
# - 最低 iOS 12.0 (シミュレータ arm64 は toolchain 都合で 14.0 に切り上がる — 実害なし)。
# - pjsip は in-tree ビルドのため、src をホスト/Android ビルドと分離した作業樹
#   (third_party/pjsip/ios-build/<platform>) へコピーしてから configure する。
#   作業樹はビルド後に削除 (KEEP_BUILD=1 で保持)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core/third_party/pjsip/src"
OUT="$ROOT/core/third_party/pjsip/ios"
BUILD="$ROOT/core/third_party/pjsip/ios-build"
PLATFORMS=${PLATFORMS:-"iphoneos iphonesimulator"}
MIN_IOS_VER=${MIN_IOS_VER:-12.0}
SIM_ARCH=${SIM_ARCH:-arm64}

[[ -d "$SRC/pjlib" ]] || { echo "先に tools/fetch_pjsip.sh を実行"; exit 1; }
XCODE_DEV="$(xcode-select -p)"
[[ -d "$XCODE_DEV" ]] || { echo "Xcode が見つからない (xcode-select -p)"; exit 1; }

for PLAT in $PLATFORMS; do
  case "$PLAT" in
    iphoneos)
      DEVPATH="$XCODE_DEV/Platforms/iPhoneOS.platform/Developer"
      MIN_IOS="-miphoneos-version-min=$MIN_IOS_VER"
      ARCH="-arch arm64"
      ;;
    iphonesimulator)
      DEVPATH="$XCODE_DEV/Platforms/iPhoneSimulator.platform/Developer"
      MIN_IOS="-mios-simulator-version-min=$MIN_IOS_VER"
      ARCH="-arch $SIM_ARCH"
      ;;
    *) echo "不明な platform: $PLAT"; exit 1 ;;
  esac

  echo "== pjsip ios $PLAT ($ARCH, min $MIN_IOS_VER) =="
  BDIR="$BUILD/$PLAT"
  PREFIX="$OUT/$PLAT"
  rm -rf "$BDIR" "$PREFIX"
  mkdir -p "$BUILD"
  cp -R "$SRC" "$BDIR"

  # iOS 用 config_site.h (Android 版と同じ流儀 — PJ_CONFIG_IPHONE のサンプル既定を
  # 土台に上書き。CoreAudio + VoiceProcessingIO / Speex AEC 無効はサンプル側の既定)
  cat > "$BDIR/pjlib/include/pj/config_site.h" <<'EOF'
/* doorbell 用 pjsip 設定 — iOS (tools/build_pjsip_ios.sh が生成) */
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>

/* 音声のみ (ビデオは Phase 6 で別変体) */
#undef PJMEDIA_HAS_VIDEO
#define PJMEDIA_HAS_VIDEO 0

/* ホスト版 config_site (fetch_pjsip.sh) と同じ呼数/アカウント数 */
#undef PJSUA_MAX_CALLS
#define PJSUA_MAX_CALLS 4
#undef PJSUA_MAX_ACC
#define PJSUA_MAX_ACC 2
EOF

  (
    cd "$BDIR"
    # configure-iphone は DEVPATH/ARCH/MIN_IOS を環境から読む。
    # --disable 群はホスト版 build_pjsip_host.sh と同じ (音声のみ + TLS なし)。
    DEVPATH="$DEVPATH" ARCH="$ARCH" MIN_IOS="$MIN_IOS" \
      ./configure-iphone --prefix="$PREFIX" \
      --disable-video --disable-opencore-amr --disable-silk --disable-sdl \
      --disable-ffmpeg --disable-v4l2 --disable-openh264 --disable-vpx \
      --disable-darwin-ssl --disable-ssl \
      > configure-iphone.log 2>&1 || { tail -30 configure-iphone.log; exit 1; }
    make dep > /dev/null 2>&1 || true
    # pjsip の Makefile は完全な並列安全ではない — 並列後に串行で補完 (host 版と同じ)
    make -j8 > build.log 2>&1 || true
    make >> build.log 2>&1 || { tail -30 build.log; exit 1; }
    make install > /dev/null
  )
  echo "ok: $PREFIX"
  ls "$PREFIX/lib" | head -3
  [[ "${KEEP_BUILD:-0}" = "1" ]] || rm -rf "$BDIR"
done
echo "done: $OUT"
