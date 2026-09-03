#!/usr/bin/env bash
# Xcode run-script phase for the native Doorbell Core bundle.
# Core and PJSIP artifacts are keyed by platform, architecture, and minimum OS so
# an iOS 9 target can never consume an iOS 12 archive from the same checkout.
set -euo pipefail

SRCROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
ARCHS="${ARCHS:-arm64}"
CONFIGURATION="${CONFIGURATION:-Release}"
CORE="$SRCROOT/../core"
REPOSITORY_ROOT="$SRCROOT/.."
BUILD_ID="${DB_BUILD_ID:-$(git -C "$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || echo dev)}"
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "error: DB_BUILD_ID contains unsupported characters" >&2
  exit 1
}

case "$PLATFORM_NAME" in
  iphoneos|iphonesimulator)
    MINIMUM_OS="${IPHONEOS_DEPLOYMENT_TARGET:-12.0}"
    ;;
  appletvos|appletvsimulator)
    MINIMUM_OS="${TVOS_DEPLOYMENT_TARGET:-15.0}"
    ;;
  *)
    echo "error: unsupported Apple platform: $PLATFORM_NAME" >&2
    exit 1
    ;;
esac

[[ "$MINIMUM_OS" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
  echo "error: invalid minimum OS value: $MINIMUM_OS" >&2
  exit 1
}
[[ "$ARCHS" =~ ^[A-Za-z0-9_]+([[:space:]][A-Za-z0-9_]+)*$ ]] || {
  echo "error: invalid architecture list: $ARCHS" >&2
  exit 1
}

ARCH_ARRAY=($ARCHS)
CMAKE_ARCHS="$(IFS=';'; echo "${ARCH_ARRAY[*]}")"
ARCH_KEY="$(IFS='+'; echo "${ARCH_ARRAY[*]}")"
BUILD_DIR="$SRCROOT/build/core/$PLATFORM_NAME/$ARCH_KEY/min-$MINIMUM_OS"
PJSIP_ROOT="$CORE/third_party/pjsip/ios/$PLATFORM_NAME/$ARCH_KEY/min-$MINIMUM_OS"
PJSIP_MANIFEST="$PJSIP_ROOT/artifact-manifest.json"

CMAKE="$(command -v cmake || true)"
for CANDIDATE in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
  [[ -z "$CMAKE" && -x "$CANDIDATE" ]] && CMAKE="$CANDIDATE"
done
[[ -n "$CMAKE" ]] || {
  echo "error: cmake is unavailable; install it before building the Apple clients" >&2
  exit 1
}
command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }

REQUIRE_PJSIP=ON
WITH_PJSIP=ON
if [[ "${DB_ALLOW_SIP_STUB:-0}" = "1" ]]; then
  REQUIRE_PJSIP=OFF
fi

if [[ -f "$PJSIP_MANIFEST" ]]; then
  python3 - "$PJSIP_MANIFEST" "$PLATFORM_NAME" "$CMAKE_ARCHS" "$MINIMUM_OS" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
expected_arches = sys.argv[3].split(";")
checks = {
    "schema_version": 1,
    "artifact": "pjsip-static",
    "platform": sys.argv[2],
    "minimum_os": sys.argv[4],
    "sip_backend": "real_pjsip",
}
for key, expected in checks.items():
    if manifest.get(key) != expected:
        raise SystemExit(
            f"error: {path} has {key}={manifest.get(key)!r}; expected {expected!r}"
        )
if manifest.get("architectures") != expected_arches:
    raise SystemExit(
        f"error: {path} has architectures={manifest.get('architectures')!r}; "
        f"expected {expected_arches!r}"
    )
PY
  [[ -f "$PJSIP_ROOT/include/pjsua-lib/pjsua.h" ]] || {
    echo "error: keyed PJSIP headers are missing from $PJSIP_ROOT" >&2
    exit 1
  }
else
  if [[ "$REQUIRE_PJSIP" = ON ]]; then
    echo "error: real keyed PJSIP is required at $PJSIP_ROOT" >&2
    echo "error: run tools/build_pjsip_ios.sh for this platform/architecture/minimum OS" >&2
    exit 1
  fi
  WITH_PJSIP=OFF
  echo "warning: building a development-only SIP stub because DB_ALLOW_SIP_STUB=1" >&2
fi

CONTRACT="$PLATFORM_NAME|$CMAKE_ARCHS|$MINIMUM_OS|$WITH_PJSIP|$PJSIP_ROOT|$BUILD_ID"
STAMP="$BUILD_DIR/.build-contract"
if [[ -f "$STAMP" && "$(cat "$STAMP")" != "$CONTRACT" ]]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"
printf '%s\n' "$CONTRACT" > "$STAMP"

"$CMAKE" -S "$CORE" -B "$BUILD_DIR" \
  -DCMAKE_MAKE_PROGRAM="$(command -v make || echo /usr/bin/make)" \
  -DCMAKE_TOOLCHAIN_FILE="$CORE/cmake/ios.cmake" \
  -DDB_APPLE_PLATFORM="$PLATFORM_NAME" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MINIMUM_OS" \
  -DDB_PJSIP_ROOT="$PJSIP_ROOT" \
  -DDB_WITH_PJSIP="$WITH_PJSIP" \
  -DDB_REQUIRE_PJSIP="$REQUIRE_PJSIP" \
  -DDB_BUILD_ID_ARG="$BUILD_ID" \
  -DDB_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release
"$CMAKE" --build "$BUILD_DIR" --target doorbell_core -j "$(sysctl -n hw.ncpu)"

CORE_ARCHIVE="$BUILD_DIR/libdoorbell_core.a"
THIRD_PARTY_ARCHIVE="$BUILD_DIR/libdb_third_party.a"
[[ -f "$CORE_ARCHIVE" && -f "$THIRD_PARTY_ARCHIVE" ]] || {
  echo "error: Core did not produce both required archives" >&2
  exit 1
}

SIP_BACKEND=stub
if [[ "$WITH_PJSIP" = ON ]]; then
  MEMBERS="$(xcrun ar -t "$CORE_ARCHIVE")"
  if ! printf '%s\n' "$MEMBERS" | grep -E '(^|/)sipctl[.]cpp[.]o$' >/dev/null; then
    echo "error: real sipctl.cpp is absent from $CORE_ARCHIVE" >&2
    exit 1
  fi
  if printf '%s\n' "$MEMBERS" | grep -E '(^|/)sipctl_stub[.]cpp[.]o$' >/dev/null; then
    echo "error: SIP stub object leaked into the real-PJSIP Core archive" >&2
    exit 1
  fi
  if ! xcrun nm -u "$CORE_ARCHIVE" | grep -E '(^|[[:space:]])_pjsua_create$' >/dev/null; then
    echo "error: Core does not reference the PJSIP pjsua_create symbol" >&2
    exit 1
  fi
  SIP_BACKEND=real_pjsip
elif [[ "$CONFIGURATION" = Release ]]; then
  echo "error: Release builds may not use the SIP stub" >&2
  exit 1
fi

LIBRARIES=("$CORE_ARCHIVE" "$THIRD_PARTY_ARCHIVE")
if [[ "$WITH_PJSIP" = ON ]]; then
  while IFS= read -r -d '' LIBRARY; do
    LIBRARIES+=("$LIBRARY")
  done < <(find "$PJSIP_ROOT/lib" -maxdepth 1 -type f -name 'lib*.a' -print0 | sort -z)
fi
ALL_ARCHIVE="$BUILD_DIR/libdoorbell_all.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$ALL_ARCHIVE" "${LIBRARIES[@]}"

ACTUAL_ARCHS="$(xcrun lipo -archs "$ALL_ARCHIVE")"
EXPECTED_ARCHS="${ARCHS}"
[[ "$ACTUAL_ARCHS" = "$EXPECTED_ARCHS" ]] || {
  echo "error: $ALL_ARCHIVE contains '$ACTUAL_ARCHS', expected '$EXPECTED_ARCHS'" >&2
  exit 1
}
if [[ "$SIP_BACKEND" = real_pjsip ]] && \
   ! xcrun nm -gU "$ALL_ARCHIVE" | grep -E '(^|[[:space:]])_pjsua_create$' >/dev/null; then
  echo "error: combined native archive does not define pjsua_create" >&2
  exit 1
fi

SOURCE_REVISION="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
SOURCE_DIRTY=false
git -C "$REPOSITORY_ROOT" diff --quiet -- core || SOURCE_DIRTY=true
PJSIP_MANIFEST_HASH=""
if [[ -f "$PJSIP_MANIFEST" ]]; then
  PJSIP_MANIFEST_HASH="$(shasum -a 256 "$PJSIP_MANIFEST" | awk '{print $1}')"
fi
ARCHIVE_HASH="$(shasum -a 256 "$ALL_ARCHIVE" | awk '{print $1}')"
XCODE_VERSION="$(xcodebuild -version | paste -sd ' ' -)"
SDK_VERSION="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-version)"
CMAKE_VERSION="$($CMAKE --version | head -1)"

python3 - "$BUILD_DIR/artifact-manifest.json" <<PY
import json
import pathlib

manifest = {
    "schema_version": 1,
    "artifact": "doorbell-core-bundle",
    "platform": "$PLATFORM_NAME",
    "architectures": "$CMAKE_ARCHS".split(";"),
    "minimum_os": "$MINIMUM_OS",
    "sip_backend": "$SIP_BACKEND",
    "pjsip_manifest_sha256": "$PJSIP_MANIFEST_HASH",
    "archive_sha256": "$ARCHIVE_HASH",
    "source_revision": "$SOURCE_REVISION",
    "source_dirty": "$SOURCE_DIRTY" == "true",
    "toolchain": {
        "xcode": "$XCODE_VERSION",
        "sdk_version": "$SDK_VERSION",
        "cmake": "$CMAKE_VERSION"
    },
    "signing_identity": "unsigned-static-library"
}
path = pathlib.Path("$BUILD_DIR/artifact-manifest.json")
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

echo "ok: $ALL_ARCHIVE (${#LIBRARIES[@]} archives, $SIP_BACKEND, minimum OS $MINIMUM_OS)"
