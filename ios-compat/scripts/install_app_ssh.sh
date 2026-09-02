#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP="${DB_IOS_APP:-$REPO_ROOT/ios-kiosk/build/Doorbell.app}"
LOCAL_PORT="${DB_IOS_SSH_LOCAL_PORT:-2222}"

[[ -d "$APP" && -x "$APP/Doorbell" ]] || {
  echo "error: signed app not found: $APP" >&2
  echo "run ios-compat/scripts/build_app_ios5.sh first" >&2
  exit 1
}

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

if [[ $# -ge 1 ]]; then
  DEVICE_HOST="$1"
  DEVICE_PORT=22
else
  command -v iproxy >/dev/null || { echo "error: iproxy is required" >&2; exit 1; }
  PROXY_PID=""
  if ! nc -z 127.0.0.1 "$LOCAL_PORT" >/dev/null 2>&1; then
    IPROXY_DEVICE=()
    [[ -n "${DB_IOS_UDID:-}" ]] && IPROXY_DEVICE=(-u "$DB_IOS_UDID")
    if iproxy --help 2>&1 | grep -q 'LOCAL_PORT:DEVICE_PORT'; then
      iproxy "${IPROXY_DEVICE[@]}" "$LOCAL_PORT:22" >/dev/null 2>&1 &
    else
      iproxy "${IPROXY_DEVICE[@]}" "$LOCAL_PORT" 22 >/dev/null 2>&1 &
    fi
    PROXY_PID=$!
    trap '[[ -z "$PROXY_PID" ]] || kill "$PROXY_PID" 2>/dev/null || true' EXIT
    sleep 3
  fi
  DEVICE_HOST=127.0.0.1
  DEVICE_PORT="$LOCAL_PORT"
fi

SSH=(ssh "${SSH_OPTIONS[@]}" -p "$DEVICE_PORT")
# The stock OpenSSH client defaults to SFTP mode, which is unavailable on the
# iOS 5 OpenSSH server.  Legacy SCP mode is required before removing/replacing
# the installed app bundle.
SCP=(scp -O "${SSH_OPTIONS[@]}" -P "$DEVICE_PORT")
if [[ -n "${SSHPASS:-}" ]]; then
  command -v sshpass >/dev/null || { echo "error: SSHPASS requires sshpass" >&2; exit 1; }
  SSH=(sshpass -e "${SSH[@]}")
  SCP=(sshpass -e "${SCP[@]}")
fi

TARGET="root@$DEVICE_HOST"
"${SSH[@]}" "$TARGET" \
  '/usr/bin/killall Doorbell >/dev/null 2>&1 || true; /usr/bin/killall SpringBoard >/dev/null 2>&1 || true; sleep 2; /bin/rm -rf /Applications/Doorbell.app; /bin/mkdir -p /Applications'
"${SCP[@]}" -r "$APP" "$TARGET:/Applications/"
"${SSH[@]}" "$TARGET" \
  '/bin/chmod +x /Applications/Doorbell.app/Doorbell && /usr/bin/openssl sha1 /Applications/Doorbell.app/Doorbell && su mobile -c /usr/bin/uicache'
shasum "$APP/Doorbell" | awk '{print "local SHA1: " $1}'
"${SSH[@]}" "$TARGET" '/usr/bin/killall SpringBoard >/dev/null 2>&1 || true'

echo "app copied; verify UI, MiniSIP listening status, and helper heartbeat on the device"
