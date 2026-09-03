#!/usr/bin/env bash
# Standalone CI/preflight/release entry for the formal iOS 9 armv7 profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE_TOOL="$REPO_ROOT/ios-compat/tools/ios9_armv7_profile.py"
PACKAGE_TOOL="$REPO_ROOT/ios-compat/tools/package_ios9_armv7.py"
MANIFEST_TOOL="$REPO_ROOT/ios-compat/tools/write_ios9_armv7_manifest.py"
SIGNING_MODE=""
STATIC_ONLY=0
PREFLIGHT_ONLY=0

usage() {
  cat <<'EOF'
usage: ios-compat/scripts/build_ios9_armv7.sh [options]
  --static-only                 run the untrusted CI/profile checks only
  --signing stock|jailbreak     select the isolated packaging lane
  --preflight-only              validate the commissioned runner without building

Formal lanes require DB_IOS9_SDK_LICENSE_ATTESTED=1 and:
  DB_IOS9_DEVELOPER_DIR         licensed Xcode 7 Developer directory
  DB_IOS9_SDK_ROOT              its selected iPhoneOS 9.x SDK (optional if selected)
  DB_IOS9_SIGNING_IDENTITY      stock lane identity name or SHA-1
  DB_IOS9_PROVISIONING_PROFILE  stock lane provisioning profile

Optional numeric version overrides:
  DB_IOS9_SHORT_VERSION         major.minor.patch
  DB_IOS9_BUILD_VERSION         positive integer
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static-only) STATIC_ONLY=1 ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --signing)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      SIGNING_MODE="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if [[ $STATIC_ONLY -eq 1 ]]; then
  [[ -z "$SIGNING_MODE" && $PREFLIGHT_ONLY -eq 0 ]] || {
    echo "error: --static-only cannot be combined with release options" >&2
    exit 2
  }
  python3 "$PROFILE_TOOL" static
  "$REPO_ROOT/ios-compat/scripts/test_host.sh"
  echo "ok: iOS 9 armv7 untrusted CI gates passed"
  exit 0
fi

[[ "$SIGNING_MODE" = stock || "$SIGNING_MODE" = jailbreak ]] || {
  echo "error: --signing stock|jailbreak is required" >&2
  usage >&2
  exit 2
}

CONTEXT="$(mktemp "${TMPDIR:-/tmp}/doorbell-ios9-armv7-context.XXXXXX")"
trap 'rm -f "$CONTEXT"' EXIT
python3 "$PROFILE_TOOL" preflight --signing "$SIGNING_MODE" --output "$CONTEXT"

json_value() {
  python3 - "$CONTEXT" "$1" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for component in sys.argv[2].split("."):
    value = value[component]
print(value)
PY
}

CACHE_KEY="$(json_value cache_key)"
SDK_ROOT="$(json_value sdk_root)"
PJSIP_ROOT="$(json_value pjsip.root)"
APP_CLANG="$(json_value tools.app_clang)"
CORE_CLANG="$(json_value tools.core_clang)"
CORE_CLANGXX="$(json_value tools.core_clangxx)"
CLANG_RT="$(json_value tools.clang_rt)"
LIPO="$(json_value tools.lipo)"
OTOOL="$(json_value tools.otool)"
NM="$(json_value tools.nm)"
LIBTOOL="$(json_value tools.libtool)"
AR="$(json_value tools.ar)"
CMAKE="$(json_value tools.cmake)"
MAKE="$(json_value tools.make)"
SHORT_VERSION="$(json_value short_version)"
BUILD_VERSION="$(json_value build_version)"

CACHE_ROOT="$REPO_ROOT/build/ios-compat/cache/$CACHE_KEY"
ARTIFACT_ROOT="$REPO_ROOT/build/ios-compat/artifacts/$CACHE_KEY"
if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  echo "ok: commissioned iOS 9 armv7 $SIGNING_MODE preflight passed"
  echo "cache: $CACHE_ROOT"
  echo "artifacts: $ARTIFACT_ROOT"
  exit 0
fi

SOURCE_STATUS="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal -- \
  core ios-kiosk ios-compat)"
[[ -z "$SOURCE_STATUS" ]] || {
  echo "error: formal iOS 9 release requires a clean core/ios-kiosk/ios-compat tree" >&2
  exit 1
}

REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" show -s --format=%ct "$REVISION")}"
export ZERO_AR_DATE=1
JOBS="${DB_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
CORE_BUILD="$CACHE_ROOT/core"
APP_BUILD="$CACHE_ROOT/app"
STAGED_INFO="$CACHE_ROOT/ios9-armv7.Info.plist"
CORE_ARCHIVE="$CACHE_ROOT/libdoorbell-ios9-armv7-pjsip.a"
mkdir -p "$CORE_BUILD" "$APP_BUILD" "$ARTIFACT_ROOT"

echo "== configure Core ($CACHE_KEY) =="
DB_IOS9_SDK_ROOT="$SDK_ROOT" \
DB_IOS9_CORE_CLANG="$CORE_CLANG" \
DB_IOS9_CORE_CLANGXX="$CORE_CLANGXX" \
  "$CMAKE" -S "$REPO_ROOT/core" -B "$CORE_BUILD" \
    -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/ios-compat/cmake/ios9-armv7.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DDB_PJSIP_ROOT="$PJSIP_ROOT" \
    -DDB_BUILD_ID_ARG="$REVISION"
"$CMAKE" --build "$CORE_BUILD" --target doorbell_core db_third_party -j "$JOBS"

CORE_MEMBERS="$($AR -t "$CORE_BUILD/libdoorbell_core.a")"
printf '%s\n' "$CORE_MEMBERS" | grep -q 'sipctl.cpp' || {
  echo "error: real sipctl.cpp is absent from Core" >&2
  exit 1
}
if printf '%s\n' "$CORE_MEMBERS" | grep -q 'sipctl_stub.cpp'; then
  echo "error: formal Core archive contains sipctl_stub.cpp" >&2
  exit 1
fi
PJSIP_LIBRARIES=("$PJSIP_ROOT"/lib/lib*.a)
[[ -f "${PJSIP_LIBRARIES[0]}" ]] || {
  echo "error: commissioned PJSIP archive set disappeared after preflight" >&2
  exit 1
}
"$LIBTOOL" -static -no_warning_for_no_symbols -o "$CORE_ARCHIVE.tmp" \
  "$CORE_BUILD/libdoorbell_core.a" "$CORE_BUILD/libdb_third_party.a" \
  "${PJSIP_LIBRARIES[@]}"
mv "$CORE_ARCHIVE.tmp" "$CORE_ARCHIVE"
[[ "$($LIPO -archs "$CORE_ARCHIVE")" = armv7 ]] || {
  echo "error: combined Core archive is not armv7-only" >&2
  exit 1
}
COMBINED_SYMBOLS="$($NM -g "$CORE_ARCHIVE")"
for symbol in _db_core_create_v2 _pjsua_create _pjsua_call_make_call _pjsua_call_answer; do
  printf '%s\n' "$COMBINED_SYMBOLS" | grep -Eq "[[:space:]]$symbol$" || {
    echo "error: combined Core archive does not define $symbol" >&2
    exit 1
  }
done
if printf '%s\n' "$COMBINED_SYMBOLS" | grep -Eq '[[:space:]]_ms_(call|listen|poll|hangup)'; then
  echo "error: combined Core archive contains MiniSIP" >&2
  exit 1
fi

# Keep plist staging explicit and atomic; release versions never come from source edits.
python3 - "$REPO_ROOT/ios-compat/profiles/ios9-armv7.Info.plist" \
  "$STAGED_INFO" "$SHORT_VERSION" "$BUILD_VERSION" <<'PY'
import pathlib
import plistlib
import sys

source = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
info = plistlib.loads(source.read_bytes())
info["CFBundleShortVersionString"] = sys.argv[3]
info["CFBundleVersion"] = sys.argv[4]
temporary = output.with_suffix(output.suffix + ".tmp")
temporary.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=True))
temporary.replace(output)
PY

echo "== compile and link shared Objective-C shell =="
"$MAKE" -f "$REPO_ROOT/ios-compat/make/ios9-armv7.mk" \
  DB_IOS9_BUILD_ROOT="$APP_BUILD" \
  DB_IOS9_SDK_ROOT="$SDK_ROOT" \
  DB_IOS9_CLANG="$APP_CLANG" \
  DB_IOS9_CORE_ARCHIVE="$CORE_ARCHIVE" \
  DB_IOS9_INFO_PLIST="$STAGED_INFO" \
  DB_IOS9_CLANG_RT="$CLANG_RT" \
  DB_IOS9_LIPO="$LIPO" \
  DB_IOS9_OTOOL="$OTOOL" \
  DB_IOS9_NM="$NM" verify

APP="$APP_BUILD/Doorbell.app"
EXE="$APP/Doorbell"
if [[ "$SIGNING_MODE" = stock ]]; then
  PROFILE_PATH="$(json_value signing.profile_path)"
  IDENTITY_SHA1="$(json_value signing.identity_sha1)"
  cp "$PROFILE_PATH" "$APP/embedded.mobileprovision"
  ENTITLEMENTS="$CACHE_ROOT/stock-entitlements.plist"
  security cms -D -i "$PROFILE_PATH" > "$ENTITLEMENTS.raw"
  python3 - "$ENTITLEMENTS.raw" "$ENTITLEMENTS" "$(json_value bundle_identifier)" <<'PY'
import pathlib
import plistlib
import sys

profile = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
entitlements = dict(profile["Entitlements"])
bundle = sys.argv[3]
for key in ("application-identifier", "com.apple.developer.team-identifier"):
    value = entitlements.get(key)
    if key == "application-identifier" and isinstance(value, str) and value.endswith("*"):
        entitlements[key] = value[:-1] + bundle
groups = entitlements.get("keychain-access-groups")
if isinstance(groups, list):
    entitlements["keychain-access-groups"] = [
        value[:-1] + bundle if isinstance(value, str) and value.endswith("*") else value
        for value in groups
    ]
pathlib.Path(sys.argv[2]).write_bytes(
    plistlib.dumps(entitlements, fmt=plistlib.FMT_XML, sort_keys=True)
)
PY
  rm -f "$ENTITLEMENTS.raw"
  codesign --force --sign "$IDENTITY_SHA1" --entitlements "$ENTITLEMENTS" \
    --timestamp=none "$APP"
  codesign --verify --deep --strict "$APP"
  ARTIFACT="$ARTIFACT_ROOT/Doorbell-ios9-armv7-${SHORT_VERSION}-${BUILD_VERSION}-stock.ipa"
  python3 "$PACKAGE_TOOL" --mode stock --app "$APP" --output "$ARTIFACT" \
    --source-date-epoch "$SOURCE_DATE_EPOCH"
else
  LDID="$(json_value signing.ldid)"
  # Signed with the jailbreak entitlement set, never bare: on this install path tccd refuses the
  # camera and microphone outright -- no prompt, no TCC.db row -- unless the signature claims
  # them. See ios-compat/tools/jailbreak_entitlements.py. These keys are private to Apple and are
  # rejected by App Store and Ad Hoc signing, so they exist on this branch only.
  JB_ENTITLEMENTS="$CACHE_ROOT/jailbreak-entitlements.plist"
  python3 "$REPO_ROOT/ios-compat/tools/jailbreak_entitlements.py" \
    "$(json_value bundle_identifier)" "$JB_ENTITLEMENTS"
  "$LDID" "-S$JB_ENTITLEMENTS" "$EXE"
  "$LDID" -e "$EXE" >/dev/null
  ARTIFACT="$ARTIFACT_ROOT/Doorbell-ios9-armv7-${SHORT_VERSION}-${BUILD_VERSION}-jailbreak.deb"
  python3 "$PACKAGE_TOOL" --mode jailbreak --app "$APP" --output "$ARTIFACT" \
    --version "${SHORT_VERSION}-${BUILD_VERSION}" \
    --source-date-epoch "$SOURCE_DATE_EPOCH"
fi

python3 "$MANIFEST_TOOL" \
  --context "$CONTEXT" \
  --app "$APP" \
  --core-archive "$CORE_ARCHIVE" \
  --artifact "$ARTIFACT" \
  --output "$ARTIFACT_ROOT/manifest.json"
echo "ok: formal iOS 9 armv7 $SIGNING_MODE package: $ARTIFACT"
