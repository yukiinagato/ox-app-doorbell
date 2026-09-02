#!/usr/bin/env bash
# Link the ARC ios-kiosk shell, Core, and MiniSIP into Doorbell.app.
# Required ignored local inputs:
#   * ios-kiosk/lib/libdoorbell_all.a           (combined armv7 Core archive)
#   * tools/toolchain/ios5-armv7/lib/{libc++,libc++abi,libunwind}.a
#   * tools/sdk/iPhoneOS7.1.sdk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$KIOSK/.." && pwd)"

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

echo "== clean + build (make) =="
make -C "$KIOSK" clean
make -C "$KIOSK" app

echo
echo "===== VERIFY ====="
make -C "$KIOSK" verify

APP="$KIOSK/build/Doorbell.app"
echo
echo "ok: $APP"
echo "Install with: bash ios-kiosk/scripts/install_via_ssh.sh"
