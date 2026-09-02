#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORE_LIB="$REPO_ROOT/ios-kiosk/lib/libdoorbell_all.a"

[[ -f "$CORE_LIB" ]] || {
  echo "error: $CORE_LIB is missing; run build_core_ios5.sh --install" >&2
  exit 1
}
command -v ldid >/dev/null 2>&1 || {
  echo "error: ldid is required (brew install ldid)" >&2
  exit 1
}

make -C "$REPO_ROOT/ios-kiosk" app
make -C "$REPO_ROOT/ios-kiosk" verify
python3 "$REPO_ROOT/ios-compat/tools/write_ios5_app_manifest.py" \
  --app "$REPO_ROOT/ios-kiosk/build/Doorbell.app" \
  --core-manifest "$REPO_ROOT/build/ios-compat/artifacts/ios5-armv7-pjsip-off/manifest.json" \
  --output "$REPO_ROOT/build/ios-compat/artifacts/ios5-armv7-app/manifest.json"
