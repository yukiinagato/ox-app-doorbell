#!/usr/bin/env bash
# Deploy the ios-kiosk Doorbell.app to a jailbroken iPad 1.
# Updates atomically swap a staged bundle and restart only Doorbell. Initial
# installs and explicit --full runs also execute uicache and respring.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Doorbell.app"
[ -d "$APP" ] || { echo "Build $APP with build_app.sh first"; exit 1; }

usage() {
  cat <<'EOF'
usage: install_via_ssh.sh [--full] [ipad-ip]

  default  Fast update of an existing app; restart Doorbell only
  --full   Full install including uicache and a SpringBoard respring
EOF
}

FULL_INSTALL=0
HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full) FULL_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      [ -z "$HOST" ] || { echo "Only one iPad IP address may be specified" >&2; usage >&2; exit 2; }
      HOST="$1"
      ;;
  esac
  shift
done

run_scp() {
  if [ -n "${SSHPASS:-}" ]; then
    command -v sshpass >/dev/null || { echo "SSHPASS requires sshpass" >&2; return 1; }
    sshpass -e scp "$@"
  else
    scp "$@"
  fi
}
run_ssh() {
  if [ -n "${SSHPASS:-}" ]; then
    command -v sshpass >/dev/null || { echo "SSHPASS requires sshpass" >&2; return 1; }
    sshpass -e ssh "$@"
  else
    ssh "$@"
  fi
}

if [ -n "$HOST" ]; then
  PORT=22; SSHHOST="root@$HOST"
  echo "Using Wi-Fi: $SSHHOST"
else
  command -v iproxy >/dev/null || { echo "iproxy is required (brew install libimobiledevice)"; exit 1; }
  if ! nc -z 127.0.0.1 2222 >/dev/null 2>&1; then
    echo "Using USB: starting iproxy from local port 2222 to device port 22"
    if iproxy --help 2>&1 | grep -q 'LOCAL_PORT:DEVICE_PORT'; then
      iproxy 2222:22 >/dev/null 2>&1 &
    else
      iproxy 2222 22 >/dev/null 2>&1 &
    fi
    IPROXY_PID=$!
    trap 'kill $IPROXY_PID 2>/dev/null' EXIT
    sleep 2
  else
    echo "Using USB: reusing the existing iproxy on port 2222"
  fi
  PORT=2222; HOST=localhost; SSHHOST="root@localhost"
fi

OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o HostKeyAlgorithms=+ssh-rsa)
REMOTE_APP="/Applications/Doorbell.app"
REMOTE_STAGE="/Applications/.Doorbell.app.deploying"
MAINTENANCE_MARKER="/var/mobile/Documents/.doorbell-maintenance-restart"
HELPER_BIN="/usr/local/libexec/doorbell-keepalive"
HELPER_SOCKET="/var/run/doorbell-keepalive.sock"

# Killing Doorbell without telling a provisioned root helper looks exactly like a
# crash: the helper relaunches the old image mid-swap and burns safe-mode failure
# slots. Take a bounded maintenance lease first and release it at the end. Both
# calls are no-ops when the helper is absent, which is the default.
helper_maintenance() {
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" \
    "if [ -S '$HELPER_SOCKET' ] && [ -x '$HELPER_BIN' ]; then \
       '$HELPER_BIN' --control $1 --socket '$HELPER_SOCKET' >/dev/null 2>&1 || true; \
     fi; true"
}
maintenance_begin() { helper_maintenance "begin --seconds 300"; }
maintenance_end() { helper_maintenance "end"; }
REMOTE_STATE="$(run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "if [ -d '$REMOTE_APP' ]; then echo installed; else echo missing; fi")"
if [ "$REMOTE_STATE" = "missing" ]; then
  FULL_INSTALL=1
fi

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== Full install (uicache + respring) ==="
else
  echo "=== Fast update without restarting SpringBoard ==="
fi

# Transfer under a staging name to minimize downtime and resume races.
echo "=== Transferring staged bundle ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "mkdir -p /Applications; /bin/rm -rf '$REMOTE_STAGE'"
run_scp "${OPTS[@]}" -O -P "$PORT" -r "$APP" "$SSHHOST:$REMOTE_STAGE"

echo "=== Pausing any root keepalive helper for the swap ==="
maintenance_begin

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== Stopping the app and SpringBoard ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "touch '$MAINTENANCE_MARKER'; /usr/bin/killall Doorbell >/dev/null 2>&1; /usr/bin/killall SpringBoard >/dev/null 2>&1; sleep 2; true"
else
  echo "=== Stopping the app ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "touch '$MAINTENANCE_MARKER'; /usr/bin/killall Doorbell >/dev/null 2>&1; sleep 1; true"
fi

# Replace the old bundle so the executable receives a new inode.
echo "=== Installing under /Applications ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/bin/rm -rf '$REMOTE_APP'; /bin/mv '$REMOTE_STAGE' '$REMOTE_APP'"
echo "=== Verifying permissions and integrity ==="
run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "chmod +x /Applications/Doorbell.app/Doorbell; openssl sha1 /Applications/Doorbell.app/Doorbell"
shasum "$APP/Doorbell" | awk '{print "local  SHA1:", $1}'

if [ "$FULL_INSTALL" -eq 1 ]; then
  echo "=== Running uicache as the mobile user ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "su mobile -c /usr/bin/uicache && echo uicache-ok"
  echo "=== respring ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "/usr/bin/killall SpringBoard >/dev/null 2>&1; true"
  echo "=== Releasing the keepalive maintenance lease ==="
  maintenance_end
  echo "Installation complete. Tap the Doorbell icon on the Home screen to launch it."
else
  # SpringBoard may auto-resume the old process image between the first kill and
  # the atomic bundle swap. Kill once more after placement so uiopen must load
  # the just-verified executable rather than an unlinked old inode.
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "touch '$MAINTENANCE_MARKER'; /usr/bin/killall Doorbell >/dev/null 2>&1; sleep 1; true"
  echo "=== Launching the updated app ==="
  run_ssh "${OPTS[@]}" -p "$PORT" "$SSHHOST" "su mobile -c '/usr/bin/uiopen doorbell://' >/dev/null 2>&1 || true"
  echo "=== Releasing the keepalive maintenance lease ==="
  maintenance_end
  echo "Update complete without restarting SpringBoard. Tap the icon if the app did not open."
fi
