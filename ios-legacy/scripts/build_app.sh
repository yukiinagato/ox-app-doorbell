#!/usr/bin/env bash
# Phase C: iPad1 (armv7/iOS5.1) 門铃殻 (ObjC MRC) を core + ミニ SIP と 1 本にリンクし
# Doorbell.app を組む。実機は無いので検証上限は「コンパイル+リンク成功 + lipo(armv7)
# + otool(健全性) + 未解決記号ゼロ」。UI 実走・発音はしない。
#
# 前提 (いずれも gitignore):
#   * ios-legacy/lib/libdoorbell_all.a           (Phase B の core 束; armv7)
#   * tools/toolchain/ios5-armv7/lib/{libc++,libc++abi,libunwind}.a  (Phase A0)
#   * tools/sdk/iPhoneOS7.1.sdk                   (Xcode DMG から展開)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$LEGACY/.." && pwd)"

echo "== 前提チェック =="
missing=0
for f in "$LEGACY/lib/libdoorbell_all.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libc++abi.a" \
         "$ROOT/tools/toolchain/ios5-armv7/lib/libunwind.a" \
         "$ROOT/tools/sdk/iPhoneOS7.1.sdk"; do
  if [[ ! -e "$f" ]]; then echo "  欠落: $f"; missing=1; fi
done
[[ $missing -eq 0 ]] || { echo "error: 前提物が足りない (Phase A0/B の成果物と SDK を配置)"; exit 1; }
command -v ldid >/dev/null 2>&1 || { echo "error: ldid が無い (brew install ldid)"; exit 1; }

echo "== clean + build (make) =="
make -C "$LEGACY" clean
make -C "$LEGACY" app

echo
echo "===== VERIFY ====="
make -C "$LEGACY" verify

APP="$LEGACY/build/Doorbell.app"
echo
echo "ok: $APP"
echo "設置概要: ldid -S 済みの $APP を iFunbox/Impactor 等で iPad1 の /Applications へ配置し"
echo "        再起動 (uicache)。boot.json は端末の Documents に置く (role=indoor_panel)。"
