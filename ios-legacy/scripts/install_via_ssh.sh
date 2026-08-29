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

OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa"
echo "=== app/SpringBoard 停止 (コピー中に resume するのを防ぐ) ==="
# これを先にやらないと、コピー中に SpringBoard が app を resume して SIGKILL (dyld) +
# LaunchServices 状態が壊れ、以後アイコンタップ起動が全部 dyld SIGKILL になる。
# 先に app 本体も殺す (respring 後の自動再開を防ぐ。killall は ps 無しで使える)。
run_ssh $OPTS -p "$PORT" "$SSHHOST" "/usr/bin/killall Doorbell >/dev/null 2>&1; /usr/bin/killall SpringBoard >/dev/null 2>&1; sleep 2; true"
echo "=== /Applications へ配置 ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "mkdir -p /Applications"
run_scp $OPTS -P "$PORT" -r "$APP" "$SSHHOST:/Applications/"
echo "=== 権限 + 整合性確認 ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "chmod +x /Applications/Doorbell.app/Doorbell; openssl sha1 /Applications/Doorbell.app/Doorbell"
shasum "$APP/Doorbell" | awk '{print "local  SHA1:", $1}'
echo "=== uicache (必ず mobile ユーザで実行 — root はキャッシュを開けない) ==="
# SpringBoard を止める前に必ず完了させる (ここが失敗/中断するとアイコン起動が壊れる)。
run_ssh $OPTS -p "$PORT" "$SSHHOST" "su mobile -c /usr/bin/uicache && echo uicache-ok"
echo "=== respring (新鮮なキャッシュで起動) ==="
run_ssh $OPTS -p "$PORT" "$SSHHOST" "/usr/bin/killall SpringBoard >/dev/null 2>&1; true"
echo "完了。ホーム画面の「ドアホン」アイコンをタップして起動すること (uiopen だけでなく実タップでも)。出なければ端末を再起動。"
