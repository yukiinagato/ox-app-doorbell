#!/usr/bin/env bash
# Link the ARC ios-kiosk shell, Core, and MiniSIP into Doorbell.app.
# Required ignored local inputs:
#   * ios-kiosk/lib/libdoorbell_all.a           (combined armv7 Core archive)
#   * tools/toolchain/ios5-armv7/lib/{libc++,libc++abi,libunwind}.a
#   * tools/sdk/iPhoneOS7.1.sdk
set -euo pipefail

# --debug-entitlements adds get-task-allow so debugserver can attach. It is off
# by default: a shipped build must not be debuggable.
DEBUG_ENTITLEMENTS=0
for arg in "$@"; do
  case "$arg" in
    --debug-entitlements) DEBUG_ENTITLEMENTS=1 ;;
    -h|--help) echo "usage: $0 [--debug-entitlements]"; exit 0 ;;
    *) echo "error: unknown argument $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$KIOSK/.." && pwd)"
SRC_ENTITLEMENTS="$KIOSK/src/Entitlements.plist"

echo "== Checking prerequisites =="
missing=0
for f in "$KIOSK/lib/libdoorbell_all.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++abi.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libunwind.a" \
         "$ROOT/tools/sdk/iPhoneOS7.1.sdk"; do
  if [[ ! -e "$f" ]]; then echo "  missing: $f"; missing=1; fi
done
[[ $missing -eq 0 ]] || { echo "error: required local inputs are missing"; exit 1; }
command -v ldid >/dev/null 2>&1 || { echo "error: ldid is missing (brew install ldid)"; exit 1; }

ENTITLEMENTS="$SRC_ENTITLEMENTS"
if [[ $DEBUG_ENTITLEMENTS -eq 1 ]]; then
  ENTITLEMENTS="$KIOSK/build/Entitlements.debug.plist"
  mkdir -p "$(dirname "$ENTITLEMENTS")"
  python3 - "$SRC_ENTITLEMENTS" "$ENTITLEMENTS" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    plist = plistlib.load(f)
plist['get-task-allow'] = True
with open(sys.argv[2], 'wb') as f:
    plistlib.dump(plist, f)
PYEOF
  echo "== debug entitlements: get-task-allow added (debuggable build) =="
fi

echo "== clean + build (make) =="
make -C "$KIOSK" clean
make -C "$KIOSK" app ENTITLEMENTS="$ENTITLEMENTS"

echo
echo "===== VERIFY ====="
make -C "$KIOSK" verify ENTITLEMENTS="$ENTITLEMENTS"

APP="$KIOSK/build/Doorbell.app"
echo
echo "ok: $APP"
echo "Install with: bash ios-kiosk/scripts/install_via_ssh.sh"
