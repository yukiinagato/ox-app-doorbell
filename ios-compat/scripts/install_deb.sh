#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEB="${DB_IOS_DEB:-$REPO_ROOT/build/ios-compat/artifacts/doorbell.deb}"
[[ -f "$DEB" ]] || { echo "error: package not found: $DEB" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "error: sshpass is required" >&2; exit 1; }
export SSHPASS="${SSHPASS:-alpine}"

if [[ $# -ge 1 ]]; then
  DEVICE_HOST="$1"
  DEVICE_PORT=22
else
  command -v iproxy >/dev/null || { echo "error: iproxy is required" >&2; exit 1; }
  if [[ -n "${DB_IOS_UDID:-}" ]]; then iproxy -u "$DB_IOS_UDID" 2223 22 >/dev/null 2>&1 &
  else iproxy 2223 22 >/dev/null 2>&1 &
  fi
  PROXY_PID=$!
  trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
  sleep 3
  DEVICE_HOST=127.0.0.1
  DEVICE_PORT=2223
fi

SSH_OPTIONS=(
  -oStrictHostKeyChecking=no
  -oUserKnownHostsFile=/dev/null
  -oConnectTimeout=25
  -oKexAlgorithms=+diffie-hellman-group1-sha1
  -oHostKeyAlgorithms=+ssh-rsa
  -oCiphers=+aes128-cbc,3des-cbc
  -oMACs=+hmac-sha1
  -oPubkeyAuthentication=no
)

HELPER_BIN="/usr/local/libexec/doorbell-keepalive"
HELPER_SOCKET="/var/run/doorbell-keepalive.sock"

# Respringing and replacing the bundle under a provisioned root helper looks like a
# crash to it. Take a bounded lease first; both calls no-op when no helper exists.
helper_maintenance() {
  sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" \
    "if [ -S '$HELPER_SOCKET' ] && [ -x '$HELPER_BIN' ]; then \
       '$HELPER_BIN' --control $1 --socket '$HELPER_SOCKET' >/dev/null 2>&1 || true; \
     fi; true"
}

sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST" \
  'cat > /var/root/doorbell.deb' < "$DEB"
helper_maintenance "begin --seconds 300"
sshpass -e ssh "${SSH_OPTIONS[@]}" -oConnectTimeout=60 -p "$DEVICE_PORT" \
  "root@$DEVICE_HOST" \
  'dpkg -i /var/root/doorbell.deb && ls -ld /Applications/Doorbell.app && killall SpringBoard 2>/dev/null || true'
helper_maintenance "end"

echo "installation requested; verify the app heartbeat and UI on the device"
