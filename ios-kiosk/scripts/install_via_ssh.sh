#!/usr/bin/env bash
# ios-kiosk 版 Doorbell.app を越獄済み iPad 1 へ配置する。
# 既存 app の更新は staging 済み bundle へ一気に差し替え、Doorbell だけを再起動する。
# 初回インストール、または --full 指定時だけ uicache + respring を行う。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Doorbell.app"
[ -d "$APP" ] || { echo "先に build_app.sh で $APP を作成"; exit 1; }

usage() {
  cat <<'EOF'
usage: install_via_ssh.sh [--full] [ipad-ip]

  default  既存 app は高速更新 (Doorbell のみ再起動)
  --full  uicache + SpringBoard respring を含む完全インストール
EOF
}

FULL_INSTALL=0
HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "不明なオプション: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$HOST" ] || { echo "iPad IP は 1 つだけ指定できます" >&2; usage >&2; exit 2; }
      HOST="$1"
      ;;
  esac
  shift
done

PASS="${SSHPASS:-alpine}"
run_scp() { if command -v sshpass >/dev/null; then sshpass -p "$PASS" scp "$@"; else scp "$@"; fi; }
run_ssh() { if command -v sshpass >/dev/null; then sshpass -p "$PASS" ssh "$@"; else ssh "$@"; fi; }

if [ -n "$HOST" ]; then
  PORT=22; SSHHOST="root@$HOST"
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

OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa)
REMOTE_APP="/Applications/Doorbell.app"
REMOTE_STAGE="/Applications/.Doorbell.app.deploying"
REMOTE_STATE="$(run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "if [ -d '$REMOTE_APP' ]; then echo installed; else echo missing; fi")"
if [ "$REMOTE_STATE" = "missing" ]; then
  FULL_INSTALL=1
fi

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== 完全インストール (uicache + respring) ==="
else
  echo "=== 高速更新 (SpringBoard は再起動しません) ==="
fi

# 稼働中 bundle には触れず、先に別名で転送する。停止時間と resume 競合を最小化する。
echo "=== staging bundle を転送 ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "mkdir -p /Applications; /bin/rm -rf '$REMOTE_STAGE'"
run_scp "${OPTS[@]}" -O -P "$PORT" -r "$APP" "$SSHHOST:$REMOTE_STAGE"

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== app/SpringBoard 停止 ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/usr/bin/killall Doorbell >/dev/null 2>&1; /usr/bin/killall SpringBoard >/dev/null 2>&1; sleep 2; true"
else
  echo "=== app のみ停止 ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/usr/bin/killall Doorbell >/dev/null 2>&1; sleep 1; true"
fi

# 旧 bundle は必ず削除し、staging bundle を移動する (実行ファイルを新 inode にする)。
echo "=== /Applications へ配置 ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/bin/rm -rf '$REMOTE_APP'; /bin/mv '$REMOTE_STAGE' '$REMOTE_APP'"
echo "=== 権限 + 整合性確認 ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "chmod +x /Applications/Doorbell.app/Doorbell; openssl sha1 /Applications/Doorbell.app/Doorbell"
shasum "$APP/Doorbell" | awk '{print "local  SHA1:", $1}'

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== uicache (必ず mobile ユーザで) ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "su mobile -c /usr/bin/uicache && echo uicache-ok"
  echo "=== respring ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/usr/bin/killall SpringBoard >/dev/null 2>&1; true"
  echo "完了。ホーム画面の「ドアホン」アイコンを実際にタップして起動してください。"
else
  # SpringBoard may auto-resume the old process image between the first kill and
  # the atomic bundle swap. Kill once more after placement so uiopen must load
  # the just-verified executable rather than an unlinked old inode.
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/usr/bin/killall Doorbell >/dev/null 2>&1; sleep 1; true"
  echo "=== 更新した app を起動 ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "su mobile -c '/usr/bin/uiopen doorbell://' >/dev/null 2>&1 || true"
  echo "完了。SpringBoard は再起動していません。app が開かなければアイコンをタップしてください。"
fi
