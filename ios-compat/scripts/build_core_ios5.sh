#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
PROFILE="ios5-armv7-pjsip-off"
BUILD_DIR="$REPO_ROOT/build/ios-compat/$PROFILE"
ARTIFACT_DIR="$REPO_ROOT/build/ios-compat/artifacts/$PROFILE"
ARTIFACT="$ARTIFACT_DIR/libdoorbell_all.a"
MANIFEST="$ARTIFACT_DIR/manifest.json"
INSTALL=0

usage() {
  echo "usage: $0 [--install]"
  echo "  --install  atomically copy the verified archive to ios-kiosk/lib"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

CMAKE="$(command -v cmake || true)"
for candidate in /opt/homebrew/bin/cmake /usr/local/bin/cmake; do
  [[ -z "$CMAKE" && -x "$candidate" ]] && CMAKE="$candidate"
done
[[ -n "$CMAKE" ]] || { echo "error: cmake is required" >&2; exit 1; }

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

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" show -s --format=%ct "$REVISION")}"
export ZERO_AR_DATE=1
JOBS="${DB_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR"
echo "== configure $PROFILE (build id: $BUILD_ID) =="
"$CMAKE" -S "$CORE_DIR" -B "$BUILD_DIR" \
  -DCMAKE_TOOLCHAIN_FILE="$CORE_DIR/cmake/ios5-armv7.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DDB_BUILD_ID_ARG="$BUILD_ID"

echo "== build core =="
"$CMAKE" --build "$BUILD_DIR" --target doorbell_core -j "$JOBS"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/doorbell-ios-core.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_ARCHIVE="$TMP_DIR/libdoorbell_all.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$TMP_ARCHIVE" \
  "$BUILD_DIR/libdoorbell_core.a" "$BUILD_DIR/libdb_third_party.a"

lipo -info "$TMP_ARCHIVE" | grep -q 'armv7' || {
  echo "error: generated archive is not armv7" >&2
  exit 1
}
BAD="$(nm -u "$TMP_ARCHIVE" 2>/dev/null | \
  grep -Eo '_(aligned_alloc|clock_gettime|__emutls_get_address|arc4random(_buf|_uniform)?|getentropy|timespec_get)\b' | \
  sort -u || true)"
[[ -z "$BAD" ]] || { echo "error: post-iOS5 imports detected: $BAD" >&2; exit 1; }

TMP_MANIFEST="$TMP_DIR/manifest.json"
CORE_SOURCE_HASH="$(python3 - "$REPO_ROOT" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "-z", "--cached", "--others",
     "--exclude-standard", "--", "core"],
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
SDK_SETTINGS_HASH="$(shasum -a 256 "$REPO_ROOT/tools/sdk/iPhoneOS7.1.sdk/SDKSettings.plist" | awk '{print $1}')"
LIBCXX_HASH="$(shasum -a 256 "$REPO_ROOT/tools/toolchain/ios5-armv7/lib/libc++.a" | awk '{print $1}')"
LIBCXXABI_HASH="$(shasum -a 256 "$REPO_ROOT/tools/toolchain/ios5-armv7/lib/libc++abi.a" | awk '{print $1}')"
LIBUNWIND_HASH="$(shasum -a 256 "$REPO_ROOT/tools/toolchain/ios5-armv7/lib/libunwind.a" | awk '{print $1}')"
CLANG_VERSION="$(xcrun clang --version | head -1)"
CMAKE_VERSION="$($CMAKE --version | head -1)"
SOURCE_DIRTY=false
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal -- core)" ]] || SOURCE_DIRTY=true
python3 - "$TMP_ARCHIVE" "$TMP_MANIFEST" "$BUILD_ID" "$REVISION" "$PROFILE" \
  "$CORE_SOURCE_HASH" "$SDK_SETTINGS_HASH" "$LIBCXX_HASH" "$LIBCXXABI_HASH" \
  "$LIBUNWIND_HASH" "$CLANG_VERSION" "$CMAKE_VERSION" "$SOURCE_DIRTY" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    artifact, output, build_id, revision, profile, core_source_hash,
    sdk_settings_hash, libcxx_hash, libcxxabi_hash, libunwind_hash,
    clang_version, cmake_version, source_dirty,
) = sys.argv[1:]
digest = hashlib.sha256(pathlib.Path(artifact).read_bytes()).hexdigest()
manifest = {
    "schema_version": 1,
    "artifact": "libdoorbell_all.a",
    "architectures": ["armv7"],
    "build_id": build_id,
    "core_source_sha256": core_source_hash,
    "minimum_os": "5.1",
    "profile": profile,
    "sha256": digest,
    "sip_backend": "core_pjsip_off_ios_compat_minisip",
    "source_revision": revision,
    "source_dirty": source_dirty == "true",
    "toolchain": {
        "clang": clang_version,
        "cmake": cmake_version,
        "sdk": "iPhoneOS7.1.sdk",
        "sdk_settings_sha256": sdk_settings_hash,
        "libcxx_sha256": libcxx_hash,
        "libcxxabi_sha256": libcxxabi_hash,
        "libunwind_sha256": libunwind_hash,
    },
}
pathlib.Path(output).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

mv "$TMP_ARCHIVE" "$ARTIFACT.tmp"
mv "$ARTIFACT.tmp" "$ARTIFACT"
mv "$TMP_MANIFEST" "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
echo "artifact: $ARTIFACT"
shasum -a 256 "$ARTIFACT"

if [[ $INSTALL -eq 1 ]]; then
  INSTALL_DIR="$REPO_ROOT/ios-kiosk/lib"
  mkdir -p "$INSTALL_DIR"
  cp "$ARTIFACT" "$INSTALL_DIR/libdoorbell_all.a.tmp"
  cmp "$ARTIFACT" "$INSTALL_DIR/libdoorbell_all.a.tmp"
  mv "$INSTALL_DIR/libdoorbell_all.a.tmp" "$INSTALL_DIR/libdoorbell_all.a"
  echo "installed: $INSTALL_DIR/libdoorbell_all.a"
fi
