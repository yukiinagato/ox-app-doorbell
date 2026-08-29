#!/usr/bin/env bash
# ios-kiosk (ARC 書き直し版) の Doorbell.app を core + ミニ SIP と 1 本にリンクして組む。
# 前提 (いずれも gitignore):
#   * ios-kiosk/lib/libdoorbell_all.a           (core 束; armv7)
#   * tools/toolchain/ios5-armv7/lib/{libc++,libc++abi,libunwind}.a
#   * tools/sdk/iPhoneOS7.1.sdk
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIOSK="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$KIOSK/.." && pwd)"

echo "== 前提チェック =="
missing=0
for f in "$KIOSK/lib/libdoorbell_all.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++abi.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libunwind.a" \
         "$ROOT/tools/sdk/iPhoneOS7.1.sdk"; do
  if [[ ! -e "$f" ]]; then echo "  欠落: $f"; missing=1; fi
done
[[ $missing -eq 0 ]] || { echo "error: 前提物が足りない"; exit 1; }
command -v ldid >/dev/null 2>&1 || { echo "error: ldid が無い (brew install ldid)"; exit 1; }

echo "== clean + build (make) =="
make -C "$KIOSK" clean
make -C "$KIOSK" app

echo
echo "===== VERIFY ====="
make -C "$KIOSK" verify

APP="$KIOSK/build/Doorbell.app"
echo
echo "ok: $APP"
echo "設置: bash ios-kiosk/scripts/install_via_ssh.sh"
