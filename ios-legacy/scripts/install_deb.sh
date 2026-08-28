#!/usr/bin/env bash
# doorbell.deb を越獄 iPad へ dpkg 正規経路で導入する。
#   USB : ./install_deb.sh                 (iproxy 2223 -> 端末22)
#   WiFi: ./install_deb.sh <ipad-ip>       (直接)
# 前提: 端末は越獄済み + OpenSSH。既定 root パスワード alpine (SSHPASS で上書き可)。
#       署名無し app を起動するには端末に AppSync Unified も必要。
# 注意: iOS5 の sshd は古い暗号のみ → 下記 KEX/Cipher/MAC を明示 (変数に入れず inline)。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEGACY="$(cd "$SCRIPT_DIR/.." && pwd)"
DEB="$LEGACY/build/doorbell.deb"
[ -f "$DEB" ] || { echo "先に build_deb.sh で $DEB を作成"; exit 1; }
export SSHPASS="${SSHPASS:-alpine}"
command -v sshpass >/dev/null || { echo "sshpass が必要 (brew install sshpass)"; exit 1; }

if [ $# -ge 1 ]; then
  HOST="$1"; PORT=22
  echo "WiFi 経由: root@$HOST"
else
  command -v iproxy >/dev/null || { echo "iproxy が必要 (brew install libimobiledevice)"; exit 1; }
  echo "USB 経由: iproxy 2223 -> 端末22"
  pkill -f 'iproxy 2223' 2>/dev/null || true; sleep 1
  iproxy 2223 22 >/dev/null 2>&1 &
  IPROXY_PID=$!; trap 'kill $IPROXY_PID 2>/dev/null' EXIT
  sleep 3
  HOST=127.0.0.1; PORT=2223
fi

# iOS5 sshd 用レガシー暗号 (必ず inline で書く。変数に入れると parse エラー)
echo "=== .deb 転送 (binary-safe: cat over ssh) ==="
sshpass -e ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=25 \
  -oKexAlgorithms=+diffie-hellman-group1-sha1 -oHostKeyAlgorithms=+ssh-rsa \
  -oCiphers=+aes128-cbc,3des-cbc -oMACs=+hmac-sha1 -oPubkeyAuthentication=no \
  -p "$PORT" "root@$HOST" 'cat > /var/root/doorbell.deb' < "$DEB"

echo "=== dpkg -i (正規登録: postinst が uicache 実行) ==="
sshpass -e ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oConnectTimeout=60 \
  -oKexAlgorithms=+diffie-hellman-group1-sha1 -oHostKeyAlgorithms=+ssh-rsa \
  -oCiphers=+aes128-cbc,3des-cbc -oMACs=+hmac-sha1 -oPubkeyAuthentication=no \
  -p "$PORT" "root@$HOST" 'dpkg -i /var/root/doorbell.deb; echo "--- 登録確認 ---"; ls -ld /Applications/Doorbell.app; killall SpringBoard 2>/dev/null; echo done'

echo
echo "完了。ホーム画面に「ドアホン」が出るはず。起動しない(バウンス)場合は AppSync Unified を確認。"
