#!/usr/bin/env bash
# Deterministic local/CI entry point for the unsigned iOS 9 arm64 release gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PJSIP_SOURCE="$ROOT/core/third_party/pjsip/src"
PJSIP_MANIFEST="$ROOT/core/third_party/pjsip/ios/iphoneos/arm64/min-9.0/artifact-manifest.json"
DERIVED_DATA="${IOS9_DERIVED_DATA:-$ROOT/ios/build/derived/iphoneos-arm64-min-9.0}"
BUILD_LOG="$DERIVED_DATA/DoorbellIOS9-Release.log"

if [[ ! -d "$PJSIP_SOURCE/pjlib" ]]; then
  "$ROOT/tools/fetch_pjsip.sh"
fi
if [[ ! -f "$PJSIP_MANIFEST" || "${REBUILD_PJSIP:-0}" = "1" ]]; then
  PLATFORMS=iphoneos MIN_IOS_VER=9.0 DEVICE_ARCH=arm64 \
    "$ROOT/tools/build_pjsip_ios.sh"
fi

mkdir -p "$DERIVED_DATA"
set +e
xcodebuild \
  -project "$ROOT/ios/Doorbell.xcodeproj" \
  -scheme DoorbellIOS9 \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tee "$BUILD_LOG"
XCODEBUILD_STATUS=${PIPESTATUS[0]}
set -e
[[ $XCODEBUILD_STATUS -eq 0 ]] || exit "$XCODEBUILD_STATUS"

TARGET_BUILD_DIR="$DERIVED_DATA/Build/Products/Release-iphoneos"
TARGET_NAME=DoorbellIOS9 \
CONFIGURATION=Release \
PLATFORM_NAME=iphoneos \
ARCHS=arm64 \
IPHONEOS_DEPLOYMENT_TARGET=9.0 \
SRCROOT="$ROOT/ios" \
TARGET_BUILD_DIR="$TARGET_BUILD_DIR" \
EXECUTABLE_PATH=DoorbellIOS9.app/DoorbellIOS9 \
INFOPLIST_PATH=DoorbellIOS9.app/Info.plist \
VERIFY_FINAL_BUNDLE=1 \
  "$ROOT/ios/scripts/verify_ios9_release.sh"

if grep -E "deployment target.*9[.]0.*supported deployment target|supported range is.*12[.]0" "$BUILD_LOG" >/dev/null; then
  echo "note: the installed Xcode reports iOS 9.0 as an unsupported deployment target; artifact checks still passed"
fi
echo "ok: iOS 9 arm64 release gate passed; log: $BUILD_LOG"
