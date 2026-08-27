#!/usr/bin/env bash
# Android 用 pjsip 静的ライブラリのクロスビルド (NDK / configure-android)。
# 産物: core/third_party/pjsip/android/<abi>/{lib,include}  (gitignore 済みパス)
#
# - ABI: arm64-v8a / armeabi-v7a / x86_64 (android/app の abiFilters と一致)。
#   ABIS="arm64-v8a" 等で絞れる。
# - APP_PLATFORM=android-21 (minSdk と一致)。
# - 音声のみ (ホスト版 build_pjsip_host.sh と同等の --disable 群)。
#   バックエンドは OpenSL ES — android_jni は JavaVM が要る上、pjlib の JNI_OnLoad が
#   殻 (jni_bridge.cpp) の JNI_OnLoad と衝突するため使わない。
# - pjsip は in-tree ビルドのため、src をホストビルドと分離した作業樹
#   (third_party/pjsip/android-build/<abi>) へコピーしてから configure する。
#   作業樹はビルド後に削除 (KEEP_BUILD=1 で保持)。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core/third_party/pjsip/src"
OUT="$ROOT/core/third_party/pjsip/android"
BUILD="$ROOT/core/third_party/pjsip/android-build"
ABIS=${ABIS:-"arm64-v8a armeabi-v7a x86_64"}
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/27.1.12297006}"
export ANDROID_NDK_ROOT
export APP_PLATFORM=${APP_PLATFORM:-android-21}

[[ -d "$SRC/pjlib" ]] || { echo "先に tools/fetch_pjsip.sh を実行"; exit 1; }
[[ -d "$ANDROID_NDK_ROOT" ]] || { echo "NDK が見つからない: $ANDROID_NDK_ROOT (ANDROID_NDK_ROOT を設定)"; exit 1; }

for ABI in $ABIS; do
  echo "== pjsip android $ABI (${APP_PLATFORM}) =="
  BDIR="$BUILD/$ABI"
  PREFIX="$OUT/$ABI"
  rm -rf "$BDIR" "$PREFIX"
  mkdir -p "$BUILD"
  cp -R "$SRC" "$BDIR"

  # Android 用 config_site.h (ホスト版はサンプル include 無しの最小 — Android は
  # PJ_CONFIG_ANDROID のサンプル既定を土台に上書きする)
  cat > "$BDIR/pjlib/include/pj/config_site.h" <<'EOF'
/* doorbell 用 pjsip 設定 — Android (tools/build_pjsip_android.sh が生成) */
#define PJ_CONFIG_ANDROID 1
#include <pj/config_site_sample.h>

/* 音声のみ (ビデオは Phase 6 で別変体) */
#undef PJMEDIA_HAS_VIDEO
#define PJMEDIA_HAS_VIDEO 0

/* ホスト版 config_site (fetch_pjsip.sh) と同じ呼数/アカウント数 */
#undef PJSUA_MAX_CALLS
#define PJSUA_MAX_CALLS 4
#undef PJSUA_MAX_ACC
#define PJSUA_MAX_ACC 2

/* 音声バックエンドは OpenSL ES。android_jni デバイスは JavaVM (pj_jni_jvm) が必要で、
 * その供給元 pjlib の JNI_OnLoad は殻 (jni_bridge.cpp) の JNI_OnLoad と重複定義になる。 */
#undef PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI
#define PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI 0
#undef PJMEDIA_AUDIO_DEV_HAS_OPENSL
#define PJMEDIA_AUDIO_DEV_HAS_OPENSL 1
#undef PJ_JNI_HAS_JNI_ONLOAD
#define PJ_JNI_HAS_JNI_ONLOAD 0
EOF

  (
    cd "$BDIR"
    # configure-android は NDK>=17 なら自動で ndk-build のフラグを取り込む
    # --disable-android-mediacodec: MediaCodec 音声コーデックは API 28+ 前提
    # (AMediaCodec_setAsyncNotifyCallback) — minSdk 21 では組めないし PCMU しか使わない
    TARGET_ABI="$ABI" ./configure-android \
      --prefix="$PREFIX" \
      --disable-video --disable-opencore-amr --disable-silk --disable-sdl \
      --disable-ffmpeg --disable-v4l2 --disable-openh264 --disable-vpx \
      --disable-ssl --disable-android-mediacodec \
      > configure-android.log 2>&1 || { tail -30 configure-android.log; exit 1; }
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
