#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE="${DB_IOS_HELPER_DEB:-$REPO_ROOT/build/ios-compat/artifacts/ios5-armv7-keepalive/doorbell-keepalive.deb}"
LOCAL_PORT="${DB_IOS_SSH_LOCAL_PORT:-2222}"
ACTION="stage"
DEVICE_HOST=""

usage() {
  cat <<'EOF'
usage: install_helper_ios5.sh [--stage|--enable|--disable|--status] [ipad-ip]

  --stage    install the reviewed helper binary and inactive launchd template only (default)
  --enable   stage, validate exact mobile UID/GID 501, then enable the root service
  --disable  unload the service and remove only its active definition/runtime state
  --status   show launchd and bounded helper status without changing the device

Enabling requires DB_CONFIRM_ROOT_HELPER=YES. The package never enables the service by itself.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) ACTION="stage" ;;
    --enable) ACTION="enable" ;;
    --disable) ACTION="disable" ;;
    --status) ACTION="status" ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *)
      [[ -z "$DEVICE_HOST" ]] || { usage >&2; exit 2; }
      DEVICE_HOST="$1"
      ;;
  esac
  shift
done

command -v sshpass >/dev/null || { echo "error: sshpass is required" >&2; exit 1; }
[[ -n "${SSHPASS:-}" ]] || {
  echo "error: set SSHPASS to the device's commissioned root SSH password" >&2
  exit 1
}
export SSHPASS
if [[ -n "$DEVICE_HOST" ]]; then
  DEVICE_PORT=22
else
  command -v iproxy >/dev/null || { echo "error: iproxy is required" >&2; exit 1; }
  if ! pgrep -f "iproxy $LOCAL_PORT 22" >/dev/null 2>&1; then
    iproxy "$LOCAL_PORT" 22 >/dev/null 2>&1 &
    PROXY_PID=$!
    trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
    sleep 3
  fi
  DEVICE_HOST=127.0.0.1
  DEVICE_PORT="$LOCAL_PORT"
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
SSH=(sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$DEVICE_PORT" "root@$DEVICE_HOST")
REMOTE_PACKAGE="/var/root/doorbell-keepalive.deb"
ACTIVE_PLIST="/Library/LaunchDaemons/jp.keihan.doorbell.keepalive.plist"
STAGED_PLIST="/usr/local/share/doorbell/jp.keihan.doorbell.keepalive.plist"

status() {
  "${SSH[@]}" \
    "launchctl list | grep jp.keihan.doorbell.keepalive || true; "\
    "if [ -f /var/run/doorbell-keepalive-status.json ]; then "\
    "sed -n '1,80p' /var/run/doorbell-keepalive-status.json; else echo helper-status-unavailable; fi"
}

if [[ "$ACTION" == "status" ]]; then
  status
  exit 0
fi

if [[ "$ACTION" == "disable" ]]; then
  "${SSH[@]}" \
    "if [ -f '$ACTIVE_PLIST' ]; then launchctl unload '$ACTIVE_PLIST' >/dev/null 2>&1 || true; fi; "\
    "/usr/bin/killall doorbell-keepalive >/dev/null 2>&1 || true; "\
    "/bin/rm -f '$ACTIVE_PLIST' /var/run/doorbell-keepalive.sock "\
    "/var/run/doorbell-keepalive-status.json /var/db/doorbell-keepalive-mode "\
    "/var/db/doorbell-keepalive-safe-mode.json"
  echo "helper disabled; the staged package remains available for an explicit future enable"
  exit 0
fi

[[ -f "$PACKAGE" ]] || {
  echo "error: helper package not found: $PACKAGE" >&2
  echo "run ios-compat/scripts/build_helper_ios5.sh first" >&2
  exit 1
}
LOCAL_SHA="$(shasum -a 256 "$PACKAGE" | awk '{print $1}')"
"${SSH[@]}" "cat > '$REMOTE_PACKAGE'" < "$PACKAGE"
REMOTE_SHA="$("${SSH[@]}" "openssl sha256 '$REMOTE_PACKAGE'" | awk '{print $NF}')"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] || {
  echo "error: uploaded helper package digest mismatch" >&2
  exit 1
}
"${SSH[@]}" "dpkg -i '$REMOTE_PACKAGE'"
echo "helper staged but not enabled (sha256 $LOCAL_SHA)"

if [[ "$ACTION" != "enable" ]]; then
  exit 0
fi
[[ "${DB_CONFIRM_ROOT_HELPER:-}" == "YES" ]] || {
  echo "error: enabling a root service requires DB_CONFIRM_ROOT_HELPER=YES" >&2
  exit 1
}
"${SSH[@]}" \
  "test \"\$(id -u mobile)\" = 501 && test \"\$(id -g mobile)\" = 501 && "\
  "test -x /usr/bin/uiopen && test ! -L /usr/bin/uiopen && "\
  "test -x /usr/local/libexec/doorbell-keepalive && "\
  "test ! -L /usr/local/libexec/doorbell-keepalive && test -f '$STAGED_PLIST'"
"${SSH[@]}" \
  "if [ -e '$ACTIVE_PLIST' ] && ! cmp -s '$STAGED_PLIST' '$ACTIVE_PLIST'; then "\
  "echo 'refusing to replace a different active helper definition' >&2; exit 31; fi; "\
  "cp '$STAGED_PLIST' '$ACTIVE_PLIST.tmp'; chown root:wheel '$ACTIVE_PLIST.tmp'; "\
  "chmod 0644 '$ACTIVE_PLIST.tmp'; mv '$ACTIVE_PLIST.tmp' '$ACTIVE_PLIST'; "\
  "launchctl unload '$ACTIVE_PLIST' >/dev/null 2>&1 || true; launchctl load '$ACTIVE_PLIST'"
sleep 4
status
