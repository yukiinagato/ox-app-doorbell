#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP="${DB_IOS_APP:-$REPO_ROOT/ios-kiosk/build/Doorbell.app}"
OUTPUT="${DB_IOS_DEB:-$REPO_ROOT/build/ios-compat/artifacts/doorbell.deb}"

[[ -d "$APP" ]] || { echo "error: app not found: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Info.plist" 2>/dev/null || echo 0.0.0)"
python3 "$REPO_ROOT/ios-compat/tools/package_deb.py" \
  --app "$APP" --output "$OUTPUT" --version "$VERSION"
ar -t "$OUTPUT"
shasum -a 256 "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256.tmp"
mv "$OUTPUT.sha256.tmp" "$OUTPUT.sha256"
