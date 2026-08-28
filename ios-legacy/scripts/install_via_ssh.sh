#!/usr/bin/env bash
# 越獄済み iPad 1 (OpenSSH 導入済み) へ Doorbell.app を配置する。
# USB (usbmux 経由 iproxy) か WiFi(IP 直指定) のどちらでも可。
#   USB:  ./install_via_ssh.sh              (iproxy で localhost:2222 → 端末 22)
#   WiFi: ./install_via_ssh.sh <ipad-ip>    (直接 scp)
# 前提: 端末は越獄済み + OpenSSH + AppSync Unified。既定パスワードは alpine
#       (必ず端末側で passwd 変更推奨)。SSHPASS 環境変数でパスワード指定可。
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
  # USB: iproxy でローカルポートを端末 SSH(22) へ転送
  command -v iproxy >/dev/null || { echo "iproxy が必要 (brew install libimobiledevice)"; exit 1; }
  echo "USB 経由: iproxy 2222 -> 端末 22 を起動"
  iproxy 2222 22 >/dev/null 2>&1 &
  IPROXY_PID=$!
  trap 'kill $IPROXY_PID 2>/dev/null' EXIT
  sleep 2
  PORT=2222; HOST=localhost; SSHHOST="root@localhost"
fi

OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
echo "=== /Applications へ配置 ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "mkdir -p /Applications"
run_scp $OPTS -P "$PORT" -r "$APP" "$SSHHOST:/Applications/"
echo "=== 権限 + uicache ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "chmod +x /Applications/Doorbell.app/Doorbell; uicache || (killall SpringBoard)"
echo "完了。ホーム画面に「ドアホン」が出るはず (出なければ端末を再起動)。"
