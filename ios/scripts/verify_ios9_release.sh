#!/usr/bin/env bash
# Post-link release gate for the arm64-only iOS 9 compatibility target.
set -euo pipefail

[[ "${TARGET_NAME:-}" = "DoorbellIOS9" ]] || exit 0
[[ "${CONFIGURATION:-}" = "Release" ]] || exit 0

EXPECTED_PLATFORM=iphoneos
EXPECTED_ARCH=arm64
EXPECTED_MINIMUM_OS=9.0

[[ "${PLATFORM_NAME:-}" = "$EXPECTED_PLATFORM" ]] || {
  echo "error: DoorbellIOS9 Release must use iphoneos, not ${PLATFORM_NAME:-unset}" >&2
  exit 1
}
[[ "${ARCHS:-}" = "$EXPECTED_ARCH" ]] || {
  echo "error: DoorbellIOS9 Release must be arm64-only, not ${ARCHS:-unset}" >&2
  exit 1
}
[[ "${IPHONEOS_DEPLOYMENT_TARGET:-}" = "$EXPECTED_MINIMUM_OS" ]] || {
  echo "error: DoorbellIOS9 Release must target iOS $EXPECTED_MINIMUM_OS" >&2
  exit 1
}

CORE_DIR="$SRCROOT/build/core/$EXPECTED_PLATFORM/$EXPECTED_ARCH/min-$EXPECTED_MINIMUM_OS"
CORE_ARCHIVE="$CORE_DIR/libdoorbell_all.a"
CORE_MANIFEST="$CORE_DIR/artifact-manifest.json"
EXECUTABLE="$TARGET_BUILD_DIR/$EXECUTABLE_PATH"
INFO_PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"

for REQUIRED in "$CORE_ARCHIVE" "$CORE_MANIFEST" "$EXECUTABLE" "$INFO_PLIST"; do
  [[ -f "$REQUIRED" ]] || { echo "error: required release artifact is missing: $REQUIRED" >&2; exit 1; }
done

python3 - "$CORE_MANIFEST" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
expected = {
    "schema_version": 1,
    "artifact": "doorbell-core-bundle",
    "platform": "iphoneos",
    "architectures": ["arm64"],
    "minimum_os": "9.0",
    "sip_backend": "real_pjsip",
}
for key, value in expected.items():
    if manifest.get(key) != value:
        raise SystemExit(
            f"error: {path} has {key}={manifest.get(key)!r}; expected {value!r}"
        )
if not manifest.get("pjsip_manifest_sha256"):
    raise SystemExit(f"error: {path} does not bind the PJSIP dependency manifest")
PY

[[ "$(xcrun lipo -archs "$CORE_ARCHIVE")" = "$EXPECTED_ARCH" ]] || {
  echo "error: Core bundle is not arm64-only" >&2
  exit 1
}
[[ "$(xcrun lipo -archs "$EXECUTABLE")" = "$EXPECTED_ARCH" ]] || {
  echo "error: application executable is not arm64-only" >&2
  exit 1
}

BUILD_METADATA="$(xcrun vtool -show-build "$EXECUTABLE")"
RECORDED_PLATFORM="$(printf '%s\n' "$BUILD_METADATA" | awk '$1 == "platform" {print $2}' | sort -u | paste -sd ' ' -)"
RECORDED_MINIMUM="$(printf '%s\n' "$BUILD_METADATA" | awk '$1 == "minos" {print $2}' | sort -u | paste -sd ' ' -)"
if [[ -z "$RECORDED_PLATFORM" ]] && \
   printf '%s\n' "$BUILD_METADATA" | grep 'LC_VERSION_MIN_IPHONEOS' >/dev/null; then
  RECORDED_PLATFORM=IOS
  RECORDED_MINIMUM="$(printf '%s\n' "$BUILD_METADATA" | awk '
    $1 == "cmd" && $2 == "LC_VERSION_MIN_IPHONEOS" { in_min = 1; next }
    in_min && $1 == "version" { print $2; exit }
  ')"
fi
[[ "$RECORDED_PLATFORM" = IOS ]] || {
  echo "error: application Mach-O records platform '$RECORDED_PLATFORM', expected IOS" >&2
  exit 1
}
[[ "$RECORDED_MINIMUM" = "$EXPECTED_MINIMUM_OS" ]] || {
  echo "error: application Mach-O records minimum OS '$RECORDED_MINIMUM', expected '$EXPECTED_MINIMUM_OS'" >&2
  exit 1
}

PLIST_MINIMUM="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$INFO_PLIST")"
[[ "$PLIST_MINIMUM" = "$EXPECTED_MINIMUM_OS" ]] || {
  echo "error: application Info.plist records minimum OS '$PLIST_MINIMUM'" >&2
  exit 1
}

DEFINED_SYMBOLS="$(xcrun nm -gU "$EXECUTABLE")"
for SYMBOL in _db_core_create_v2 _pjsua_create; do
  if ! printf '%s\n' "$DEFINED_SYMBOLS" | grep -E "(^|[[:space:]])${SYMBOL}$" >/dev/null; then
    echo "error: linked application does not define required symbol $SYMBOL" >&2
    exit 1
  fi
done
if xcrun nm -u "$EXECUTABLE" | grep -E '(^|[[:space:]])_pjsua_' >/dev/null; then
  echo "error: linked application retains unresolved PJSIP symbols" >&2
  exit 1
fi

FRAMEWORKS_DIR="$(dirname "$EXECUTABLE")/Frameworks"
if [[ "${VERIFY_FINAL_BUNDLE:-0}" = "1" ]]; then
  [[ -d "$FRAMEWORKS_DIR" ]] || {
    echo "error: final iOS 9 bundle does not contain back-deployed Swift runtime libraries" >&2
    exit 1
  }
  RUNTIME_COUNT=0
  while IFS= read -r -d '' RUNTIME_LIBRARY; do
    RUNTIME_COUNT=$((RUNTIME_COUNT + 1))
    [[ "$(xcrun lipo -archs "$RUNTIME_LIBRARY")" = "$EXPECTED_ARCH" ]] || {
      echo "error: runtime library is not arm64-only: $RUNTIME_LIBRARY" >&2
      exit 1
    }
    RUNTIME_METADATA="$(xcrun vtool -show-build "$RUNTIME_LIBRARY")"
    RUNTIME_MINIMUM="$(printf '%s\n' "$RUNTIME_METADATA" | awk '$1 == "minos" {print $2; exit}')"
    if [[ -z "$RUNTIME_MINIMUM" ]]; then
      RUNTIME_MINIMUM="$(printf '%s\n' "$RUNTIME_METADATA" | awk '
        $1 == "cmd" && $2 == "LC_VERSION_MIN_IPHONEOS" { in_min = 1; next }
        in_min && $1 == "version" { print $2; exit }
      ')"
    fi
    python3 - "$RUNTIME_MINIMUM" "$EXPECTED_MINIMUM_OS" <<'PY'
import sys

def version(value):
    return tuple(int(part) for part in value.split("."))

if not sys.argv[1] or version(sys.argv[1]) > version(sys.argv[2]):
    raise SystemExit(
        f"error: Swift runtime minimum OS {sys.argv[1]!r} exceeds {sys.argv[2]}"
    )
PY
  done < <(find "$FRAMEWORKS_DIR" -maxdepth 1 -type f -name 'libswift*.dylib' -print0 | sort -z)
  [[ $RUNTIME_COUNT -gt 0 ]] || {
    echo "error: no back-deployed Swift runtime libraries were found" >&2
    exit 1
  }
fi

echo "ok: DoorbellIOS9 Release is arm64, minimum iOS 9.0, ABI v2, real PJSIP"
