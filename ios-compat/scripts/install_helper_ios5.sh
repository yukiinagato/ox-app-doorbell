#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE="${DB_IOS_HELPER_DEB:-$REPO_ROOT/build/ios-compat/artifacts/ios5-armv7-keepalive/doorbell-keepalive.deb}"
# This project forwards the device's SSH port on 2223; 2222 belongs to another lane.
LOCAL_PORT="${DB_IOS_SSH_LOCAL_PORT:-2223}"
ACTION="stage"
DEVICE_HOST=""

usage() {
  cat <<'EOF'
usage: install_helper_ios5.sh [action] [ipad-ip]

  --stage            install the reviewed helper binary and inactive launchd template (default)
  --enable           stage, validate exact mobile UID/GID 501, then enable the root service
  --disable          unload the service and remove only its active definition/runtime state
  --status           show bounded helper status from the status file (no launchctl dependency)
  --disable-file     engage the root kill switch: the helper stops launching and reports off
  --enable-file      release the root kill switch
  --clear-safe-mode  clear a latched safe mode and its absolute launch cap

Enabling requires DB_CONFIRM_ROOT_HELPER=YES. The package never enables the service by itself.
Set SSHPASS to the device's commissioned root SSH password. Override the USB-forwarded port
with DB_IOS_SSH_LOCAL_PORT (default 2223).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) ACTION="stage" ;;
    --enable) ACTION="enable" ;;
    --disable) ACTION="disable" ;;
    --status) ACTION="status" ;;
    --disable-file) ACTION="disable-file" ;;
    --enable-file) ACTION="enable-file" ;;
    --clear-safe-mode) ACTION="clear-safe-mode" ;;
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
  if ! pgrep -f "iproxy $LOCAL_PORT" >/dev/null 2>&1; then
    iproxy "$LOCAL_PORT" 22 >/dev/null 2>&1 &
    PROXY_PID=$!
    trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
    sleep 3
  fi
  DEVICE_HOST=127.0.0.1
  DEVICE_PORT="$LOCAL_PORT"
fi

# iOS 5's sshd offers only legacy algorithms; these must stay inline.
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
HELPER_BIN="/usr/local/libexec/doorbell-keepalive"
HELPER_SOCKET="/var/run/doorbell-keepalive.sock"
STATUS_FILE="/var/run/doorbell-keepalive-status.json"
MODE_FILE="/var/db/doorbell-keepalive-mode"
MARKER_FILE="/var/db/doorbell-keepalive-safe-mode.json"
DISABLE_FILE="/var/db/doorbell-keepalive.disable"

# The status file is the authority. `launchctl list` is unreliable from an SSH
# session on iOS 5, so it is reported as supplementary evidence only.
status() {
  "${SSH[@]}" \
    "echo '--- active definition ---'; "\
    "if [ -f '$ACTIVE_PLIST' ]; then echo present; else echo absent; fi; "\
    "echo '--- kill switch ---'; "\
    "if [ -f '$DISABLE_FILE' ]; then echo engaged; else echo released; fi; "\
    "echo '--- helper status ---'; "\
    "if [ -f '$STATUS_FILE' ]; then sed -n '1,80p' '$STATUS_FILE'; "\
    "else echo helper-status-unavailable; fi; "\
    "echo '--- launchctl (advisory) ---'; "\
    "launchctl list 2>&1 | grep jp.keihan.doorbell.keepalive || echo not-listed"
}

# The status file is rewritten on every state change, so a recent mtime proves the
# daemon is running. `find -mmin` is present in the iOS 5 BSD subsystem.
helper_running() {
  local answer
  answer="$("${SSH[@]}" \
    "if [ -S '$HELPER_SOCKET' ] && [ -f '$STATUS_FILE' ]; then echo yes; else echo no; fi")"
  [[ "$answer" == "yes" ]]
}

case "$ACTION" in
  status)
    status
    exit 0
    ;;
  disable-file)
    "${SSH[@]}" \
      "/usr/bin/touch '$DISABLE_FILE' && /usr/sbin/chown root:wheel '$DISABLE_FILE' && "\
      "/bin/chmod 0644 '$DISABLE_FILE'"
    echo "kill switch engaged: the helper reports mode off and stops launching"
    status
    exit 0
    ;;
  enable-file)
    "${SSH[@]}" "/bin/rm -f '$DISABLE_FILE'"
    echo "kill switch released"
    status
    exit 0
    ;;
  clear-safe-mode)
    # Removing the root-owned marker is the supported clear on the Apple path:
    # datagram sockets there carry no peer credentials, so SAFE_MODE_CLEAR is
    # refused, while /var/db is writable only by root.
    "${SSH[@]}" "/bin/rm -f '$MARKER_FILE'"
    sleep 2
    status
    if "${SSH[@]}" "test -f '$MARKER_FILE'"; then
      echo "error: the safe-mode marker still exists" >&2
      exit 1
    fi
    echo "safe-mode marker removed; the running helper clears safe mode on its next tick"
    exit 0
    ;;
  disable)
    "${SSH[@]}" \
      "if [ -f '$ACTIVE_PLIST' ]; then launchctl unload '$ACTIVE_PLIST' >/dev/null 2>&1 || true; fi; "\
      "/usr/bin/killall doorbell-keepalive >/dev/null 2>&1 || true; "\
      "/bin/rm -f '$ACTIVE_PLIST' '$HELPER_SOCKET' '$STATUS_FILE' '$MODE_FILE' "\
      "'$MARKER_FILE' '$DISABLE_FILE'"
    echo "helper disabled; the staged package remains available for an explicit future enable"
    exit 0
    ;;
esac

[[ -f "$PACKAGE" ]] || {
  echo "error: helper package not found: $PACKAGE" >&2
  echo "run ios-compat/scripts/build_helper_ios5.sh first" >&2
  exit 1
}
LOCAL_SHA="$(shasum -a 256 "$PACKAGE" | awk '{print $1}')"
"${SSH[@]}" "cat > '$REMOTE_PACKAGE'" < "$PACKAGE"
REMOTE_SHA="$("${SSH[@]}" "openssl dgst -sha256 '$REMOTE_PACKAGE'" | awk '{print $NF}')"
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
  "test \"\$(sed -n 's/^mobile:[^:]*:\\([0-9]*\\):\\([0-9]*\\):.*/\\1:\\2/p' /etc/passwd)\" = 501:501 && "\
  "test -x /usr/bin/uiopen && test ! -L /usr/bin/uiopen && "\
  "test -x '$HELPER_BIN' && "\
  "test ! -L '$HELPER_BIN' && test -f '$STAGED_PLIST'"
"${SSH[@]}" \
  "if [ -e '$ACTIVE_PLIST' ] && ! cmp -s '$STAGED_PLIST' '$ACTIVE_PLIST'; then "\
  "echo 'refusing to replace a different active helper definition' >&2; exit 31; fi; "\
  "cp '$STAGED_PLIST' '$ACTIVE_PLIST.tmp'; chown root:wheel '$ACTIVE_PLIST.tmp'; "\
  "chmod 0644 '$ACTIVE_PLIST.tmp'; mv '$ACTIVE_PLIST.tmp' '$ACTIVE_PLIST'"

# `launchctl load` run from an SSH session on iOS 5 frequently answers
# "Socket is not connected" because that session has no launchd bootstrap port.
# The command is still attempted, but only the status file may declare success.
LOAD_OUTPUT="$("${SSH[@]}" \
  "launchctl unload '$ACTIVE_PLIST' >/dev/null 2>&1 || true; "\
  "launchctl load '$ACTIVE_PLIST' 2>&1 || true")"
[[ -z "$LOAD_OUTPUT" ]] || echo "launchctl load said: $LOAD_OUTPUT"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if helper_running; then
    echo "helper active: the socket and status file are present"
    status
    exit 0
  fi
  sleep 2
done

cat >&2 <<EOF
warning: the active definition is installed at $ACTIVE_PLIST but the helper did not
start in this session. This is the expected outcome when launchctl reports
"Socket is not connected": an SSH session on iOS 5 has no launchd bootstrap port.

The definition is loaded at the next boot. Reboot the device, then re-run:

  DB_IOS_SSH_LOCAL_PORT=$LOCAL_PORT SSHPASS='<password>' \\
    ios-compat/scripts/install_helper_ios5.sh --status

Enabling is not confirmed until that status shows the helper socket and status file.
EOF
status
exit 40
