#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE="ios5-armv7-keepalive"
ARTIFACT_DIR="$REPO_ROOT/build/ios-compat/artifacts/$PROFILE"
HELPER="$ARTIFACT_DIR/doorbell-keepalive"
PACKAGE="$ARTIFACT_DIR/doorbell-keepalive.deb"
MANIFEST="$ARTIFACT_DIR/manifest.json"
SOURCE="$REPO_ROOT/tools/helper/doorbell_keepalive.c"
TEMPLATE="$REPO_ROOT/ios-compat/helper/jp.ox.doorbell.keepalive.plist.example"
SDK="$REPO_ROOT/tools/sdk/iPhoneOS7.1.sdk"

[[ -f "$SOURCE" && -f "$TEMPLATE" && -d "$SDK" ]] || {
  echo "error: helper source, launchd template, or licensed SDK is missing" >&2
  exit 1
}
command -v ldid >/dev/null 2>&1 || {
  echo "error: ldid is required (brew install ldid)" >&2
  exit 1
}

REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
  if [[ "${DB_ALLOW_DIRTY:-0}" != "1" ]]; then
    echo "error: dirty tree; commit first or set DB_ALLOW_DIRTY=1 with DB_BUILD_ID" >&2
    exit 1
  fi
  [[ -n "${DB_BUILD_ID:-}" ]] || {
    echo "error: a dirty build requires an explicit DB_BUILD_ID" >&2
    exit 1
  }
fi
BUILD_ID="${DB_BUILD_ID:-$REVISION}"
[[ "$BUILD_ID" =~ ^[A-Za-z0-9._+-]+$ ]] || {
  echo "error: DB_BUILD_ID contains unsupported characters" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doorbell-ios5-helper.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
UNSIGNED="$TMP_DIR/doorbell-keepalive"
SIGNED="$TMP_DIR/doorbell-keepalive.signed"
CC="$(xcrun -f clang)" \
CFLAGS="-std=c99 -Wall -Wextra -Werror -Os -arch armv7 -miphoneos-version-min=5.1 -isysroot $SDK" \
LDFLAGS="-Wl,-no_uuid" \
  "$REPO_ROOT/tools/helper/build_keepalive_helper.sh" --output "$UNSIGNED"
cp "$UNSIGNED" "$SIGNED"
ldid -S "$SIGNED"

lipo -info "$SIGNED" | grep -q 'armv7' || {
  echo "error: helper is not armv7" >&2
  exit 1
}
otool -l "$SIGNED" | grep -A4 LC_VERSION_MIN_IPHONEOS | grep -q 'version 5.1' || {
  echo "error: helper minimum OS is not iOS 5.1" >&2
  exit 1
}
otool -l "$SIGNED" | grep -q LC_CODE_SIGNATURE || {
  echo "error: helper is not jailbreak-signed" >&2
  exit 1
}
BAD="$(nm -u "$SIGNED" 2>/dev/null | \
  grep -Eo '_(aligned_alloc|clock_gettime|__emutls_get_address|arc4random(_buf|_uniform)?|getentropy|timespec_get)\b' | \
  sort -u || true)"
[[ -z "$BAD" ]] || { echo "error: post-iOS5 imports detected: $BAD" >&2; exit 1; }

mkdir -p "$ARTIFACT_DIR"
cp "$SIGNED" "$HELPER.tmp"
cmp "$SIGNED" "$HELPER.tmp"
mv "$HELPER.tmp" "$HELPER"
chmod 0755 "$HELPER"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$REPO_ROOT/ios-kiosk/src/Info.plist" 2>/dev/null || echo 0.0.0)"
python3 "$REPO_ROOT/ios-compat/tools/package_helper_deb.py" \
  --helper "$HELPER" --launchd-template "$TEMPLATE" --output "$PACKAGE" --version "$VERSION"

SOURCE_HASH="$(python3 - "$REPO_ROOT" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others",
     "--exclude-standard", "--", "tools/helper", "ios-compat/helper",
     "ios-compat/scripts/build_helper_ios5.sh", "ios-compat/tools/package_helper_deb.py"],
).split(b"\0")
digest = hashlib.sha256()
for raw in sorted(path for path in paths if path):
    relative = raw.decode("utf-8")
    digest.update(raw)
    digest.update(b"\0")
    digest.update(hashlib.sha256((root / relative).read_bytes()).digest())
print(digest.hexdigest())
PY
)"
SOURCE_DIRTY=false
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal -- \
  tools/helper ios-compat/helper ios-compat/scripts/build_helper_ios5.sh \
  ios-compat/tools/package_helper_deb.py)" ]] || SOURCE_DIRTY=true
python3 - "$HELPER" "$PACKAGE" "$TEMPLATE" "$MANIFEST.tmp" "$BUILD_ID" "$REVISION" \
  "$VERSION" "$SOURCE_HASH" "$SOURCE_DIRTY" "$(xcrun clang --version | head -1)" <<'PY'
import hashlib
import json
import pathlib
import sys

(helper, package, template, output, build_id, revision, version, source_hash,
 source_dirty, clang_version) = sys.argv[1:]

def digest(path: str) -> str:
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

manifest = {
    "schema_version": 1,
    "profile": "ios5-armv7-keepalive",
    "build_id": build_id,
    "source_revision": revision,
    "source_dirty": source_dirty == "true",
    "source_sha256": source_hash,
    "version": version,
    "architectures": ["armv7"],
    "minimum_os": "5.1",
    "jailbreak_signed": True,
    "service_enabled_by_package": False,
    "helper": {"path": "doorbell-keepalive", "sha256": digest(helper)},
    "package": {"path": "doorbell-keepalive.deb", "sha256": digest(package)},
    "launchd_template_sha256": digest(template),
    "toolchain": {"clang": clang_version, "sdk": "iPhoneOS7.1.sdk"},
}
pathlib.Path(output).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY
mv "$MANIFEST.tmp" "$MANIFEST"

ar -t "$PACKAGE"
shasum -a 256 "$HELPER" "$PACKAGE" "$MANIFEST"
echo "artifact directory: $ARTIFACT_DIR"
