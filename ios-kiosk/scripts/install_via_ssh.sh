#!/usr/bin/env bash
# ios-kiosk 版 Doorbell.app を越獄済み iPad 1 へ配置する。
# 手順は ios-legacy で固めた安全手順を踏襲:
#  1) 先に app/SpringBoard 停止 (コピー中の resume 競合防止)
#  2) 旧 bundle を必ず rm -rf してからコピー (同一 inode 原子上書きは
#     以後すべての起動が dyld SIGKILL になる根本原因 — 新 inode へ)
#  3) SHA1 照合
#  4) uicache は必ず mobile ユーザで (root はキャッシュを開けない)
#  5) respring → 実機でのアイコンタップ確認
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Doorbell.app"
[ -d "$APP" ] || { echo "先に build_app.sh で $APP を作成"; exit 1; }

PASS="${SSHPASS:-alpine}"
run_scp() { if command -v sshpass >/dev/null; then sshpass -p "$PASS" scp "$@"; else scp "$@"; fi; }
run_ssh() { if command -v sshpass >/dev/null; then sshpass -p "$PASS" ssh "$@"; else ssh "$@"; fi; }

if [ $# -ge 1 ]; then
  HOST="$1"; PORT=22; SSHHOST="root@$HOST"
  echo "WiFi 経由: $SSHHOST"
else
  command -v iproxy >/dev/null || { echo "iproxy が必要 (brew install libimobiledevice)"; exit 1; }
  if ! pgrep -f "iproxy 2222 22" >/dev/null 2>&1; then
    echo "USB 経由: iproxy 2222 -> 端末 22 を起動"
    iproxy 2222 22 >/dev/null 2>&1 &
    IPROXY_PID=$!
    trap 'kill $IPROXY_PID 2>/dev/null' EXIT
    sleep 2
  else
    echo "USB 経由: 既存の iproxy 2222 を使用"
  fi
  PORT=2222; HOST=localhost; SSHHOST="root@localhost"
fi

OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa"
echo "=== app/SpringBoard 停止 ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "/usr/bin/killall Doorbell >/dev/null 2>&1; /usr/bin/killall SpringBoard >/dev/null 2>&1; sleep 2; true"
echo "=== /Applications へ配置 (旧 bundle は必ず削除 = 新 inode) ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "mkdir -p /Applications; /bin/rm -rf /Applications/Doorbell.app"
run_scp $OPTS -O -P "$PORT" -r "$APP" "$SSHHOST:/Applications/"
echo "=== 権限 + 整合性確認 ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "chmod +x /Applications/Doorbell.app/Doorbell; openssl sha1 /Applications/Doorbell.app/Doorbell"
shasum "$APP/Doorbell" | awk '{print "local  SHA1:", $1}'
echo "=== uicache (必ず mobile ユーザで) ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "su mobile -c /usr/bin/uicache && echo uicache-ok"
echo "=== respring ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "/usr/bin/killall SpringBoard >/dev/null 2>&1; true"
echo "完了。ホーム画面の「ドアホン」アイコンを実際にタップして起動すること (uiopen だけでなく実タップでも)。出なければ端末を再起動。"
