#!/usr/bin/env bash
# Cross-build PJSIP static libraries with configure-android and the pinned NDK.
# Output: core/third_party/pjsip/android/<api-tier>/<abi>/{lib,include}.
#
# - PJSIP_TIER=api21: NDK r27, android-21, arm64-v8a/armeabi-v7a/x86_64.
# - PJSIP_TIER=api19: NDK r25c, android-19, armeabi-v7a.  Add x86 explicitly
#   with ABIS only when that deployment target is commissioned.
# - Audio only, using OpenSL ES. The android_jni backend is disabled because its
#   JNI_OnLoad conflicts with the application shell.
# - Upstream builds in-tree, so each ABI uses an isolated temporary source copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core/third_party/pjsip/src"
OUT="$ROOT/core/third_party/pjsip/android"
BUILD="$ROOT/core/third_party/pjsip/android-build"
PJSIP_TIER=${PJSIP_TIER:-api21}
case "$PJSIP_TIER" in
  api19)
    EXPECTED_PLATFORM=android-19
    EXPECTED_NDK_MAJOR=25
    DEFAULT_NDK=25.2.9519653
    ABIS=${ABIS:-"armeabi-v7a"}
    ;;
  api21)
    EXPECTED_PLATFORM=android-21
    EXPECTED_NDK_MAJOR=27
    DEFAULT_NDK=27.1.12297006
    ABIS=${ABIS:-"arm64-v8a armeabi-v7a x86_64"}
    ;;
  *) echo "PJSIP_TIER must be api19 or api21"; exit 2 ;;
esac
: "${ANDROID_NDK_ROOT:=$HOME/Library/Android/sdk/ndk/$DEFAULT_NDK}"
export ANDROID_NDK_ROOT
export APP_PLATFORM=${APP_PLATFORM:-$EXPECTED_PLATFORM}

[[ -d "$SRC/pjlib" ]] || { echo "run tools/fetch_pjsip.sh first"; exit 1; }
[[ -d "$ANDROID_NDK_ROOT" ]] || { echo "NDK not found: $ANDROID_NDK_ROOT"; exit 1; }
[[ "$APP_PLATFORM" = "$EXPECTED_PLATFORM" ]] || {
  echo "$PJSIP_TIER requires APP_PLATFORM=$EXPECTED_PLATFORM (was $APP_PLATFORM)"; exit 2;
}
NDK_REVISION=$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' \
  "$ANDROID_NDK_ROOT/source.properties" | head -1)
[[ "$NDK_REVISION" = "$EXPECTED_NDK_MAJOR".* ]] || {
  echo "$PJSIP_TIER requires NDK $EXPECTED_NDK_MAJOR.x (was $NDK_REVISION)"; exit 2;
}
PJSIP_SOURCE_SHA256="$(python3 - "$SRC" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    digest.update(path.relative_to(root).as_posix().encode("utf-8"))
    digest.update(b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)"
SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

for ABI in $ABIS; do
  echo "== pjsip android $PJSIP_TIER/$ABI (${APP_PLATFORM}, NDK $NDK_REVISION) =="
  BDIR="$BUILD/$PJSIP_TIER/$ABI"
  PREFIX="$OUT/$PJSIP_TIER/$ABI"
  rm -rf "$BDIR" "$PREFIX"
  mkdir -p "$BUILD/$PJSIP_TIER"
  cp -R "$SRC" "$BDIR"

  # Build on the upstream Android defaults, then apply the product limits below.
  cat > "$BDIR/pjlib/include/pj/config_site.h" <<'EOF'
/* Generated Doorbell PJSIP configuration for Android. */
#define PJ_CONFIG_ANDROID 1
#include <pj/config_site_sample.h>

/* Core owns video independently; PJSIP is audio-only. */
#undef PJMEDIA_HAS_VIDEO
#define PJMEDIA_HAS_VIDEO 0

/* Keep the call/account limits aligned with the host backend. */
#undef PJSUA_MAX_CALLS
#define PJSUA_MAX_CALLS 4
#undef PJSUA_MAX_ACC
#define PJSUA_MAX_ACC 2

/* OpenSL ES is the audio backend. The android_jni device needs a JavaVM from pjlib,
 * whose JNI_OnLoad would conflict with the application shell's JNI_OnLoad. */
#undef PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI
#define PJMEDIA_AUDIO_DEV_HAS_ANDROID_JNI 0
#undef PJMEDIA_AUDIO_DEV_HAS_OPENSL
#define PJMEDIA_AUDIO_DEV_HAS_OPENSL 1
#undef PJ_JNI_HAS_JNI_ONLOAD
#define PJ_JNI_HAS_JNI_ONLOAD 0
EOF

  (
    cd "$BDIR"
    # configure-android imports ndk-build flags automatically with supported NDKs.
    # The PJSIP MediaCodec audio backend needs API 28, while this product uses PCMU.
    TARGET_ABI="$ABI" ./configure-android \
      --prefix="$PREFIX" \
      --disable-video --disable-opencore-amr --disable-silk --disable-sdl \
      --disable-ffmpeg --disable-v4l2 --disable-openh264 --disable-vpx \
      --disable-ssl --disable-android-mediacodec \
      > configure-android.log 2>&1 || { tail -30 configure-android.log; exit 1; }
    make dep > /dev/null 2>&1 || true
    # Upstream makefiles are not fully parallel-safe; complete with one serial pass.
    make -j8 > build.log 2>&1 || true
    make >> build.log 2>&1 || { tail -30 build.log; exit 1; }
    make install > /dev/null
  )
  ARCHIVE_SET_SHA256="$(python3 - "$PREFIX/lib" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.glob("lib*.a")):
    digest.update(path.name.encode("utf-8"))
    digest.update(b"\0")
    digest.update(hashlib.sha256(path.read_bytes()).digest())
print(digest.hexdigest())
PY
)"
  cat > "$PREFIX/doorbell-build.properties" <<EOF
tier=$PJSIP_TIER
abi=$ABI
app_platform=$APP_PLATFORM
ndk_revision=$NDK_REVISION
pjsip_version=2.15.1
sip_backend=real_pjsip
pjsip_source_sha256=$PJSIP_SOURCE_SHA256
archive_set_sha256=$ARCHIVE_SET_SHA256
source_revision=$SOURCE_REVISION
EOF
  echo "ok: $PREFIX"
  ls "$PREFIX/lib" | head -3
  [[ "${KEEP_BUILD:-0}" = "1" ]] || rm -rf "$BDIR"
done
echo "done: $OUT"
