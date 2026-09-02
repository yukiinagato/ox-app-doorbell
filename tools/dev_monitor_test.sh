#!/usr/bin/env bash
# Two-process semi-automated door-station monitoring test.
#
# Scenario, matching production TV monitoring behavior:
#   A is door station 8001. It registers with development Asterisk and press establishes a call
#   with the auto-answer echo extension 600.
#   B is a TV or indoor panel. It sends a direct INVITE to A's SIP listener on UDP 47190 without
#   Asterisk. X-Doorbell-Mode: monitor makes A accept one-way microphone audio to B.
#   After B exits, only the monitor call ends and A's primary call with 600 remains active.
#
# Prerequisites: deploy/dev/asterisk is running and build/doorbell_host exists.
# Usage: tools/dev_monitor_test.sh (exit code 0 means every check passed)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="$ROOT/build/doorbell_host"
WORK="$(mktemp -d /tmp/db-montest-XXXXXX)"
LOG_A="$WORK/a.log"; LOG_B="$WORK/b.log"
HTTP_A=47280
PASS=0; FAIL=0
PID_A=""; PID_B=""

cleanup() {
  [[ -n "$PID_B" ]] && kill "$PID_B" 2>/dev/null
  [[ -n "$PID_A" ]] && kill "$PID_A" 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK  %s\n' "$*"; PASS=$((PASS+1)); }
ng()   { printf '   NG  %s\n' "$*"; FAIL=$((FAIL+1)); }

# Wait at most $3 seconds for grep to match.
wait_log() { # file pattern timeout_s desc
  local f=$1 pat=$2 t=$((10*$3))
  while (( t-- > 0 )); do
    grep -q "$pat" "$f" 2>/dev/null && { ok "$4"; return 0; }
    sleep 0.1
  done
  ng "$4 (timeout: '$pat' did not appear in $f)"; return 1
}

[[ -x "$HOST_BIN" ]] || { echo "build/doorbell_host is missing. Run cmake -S core -B build && cmake --build build first."; exit 2; }
if ! nc -uz 127.0.0.1 5060 2>/dev/null; then
  echo "Warning: development Asterisk did not respond at 127.0.0.1:5060/udp. Ensure deploy/dev/asterisk is running."
fi
if command -v lsof >/dev/null && lsof -nP -iUDP:47190 | grep -q .; then
  echo "Aborting: another process uses UDP 47190, so door station A cannot listen for direct calls."; exit 2
fi

# Use a dedicated PSK so this test cannot join the default development mesh.
PSK=$(printf '7e%.0s' {1..32})

say "Start A (door station 8001)"
"$HOST_BIN" --data "$WORK/a" --name door-a --role door_station --door d_front \
  --listen 127.0.0.1:47272 --http $HTTP_A --psk "$PSK" \
  --sip-user 8001 --sip-pass devpass8001 --sip-null > "$LOG_A" 2>&1 &
PID_A=$!
sleep 1

# Configure SIP and the call rule through the admin API; first login establishes the password.
CK="$WORK/cookie.txt"
curl -sf -c "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/login" \
  -d '{"password":"devtest"}' >/dev/null || { ng "admin login"; exit 1; }
cfg() { curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/config" \
        -d "{\"key\":\"$1\",\"value\":$2}" >/dev/null || ng "config $1"; }
cfg sip.server '"\"127.0.0.1\""'
cfg sip.port '"5060"'
cfg trigger_rules.mon '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}"'

wait_log "$LOG_A" 'reg: registered' 10 "A: registered with Asterisk"

say "A: press calls extension 600 as the primary call"
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_log "$LOG_A" 'primary call #.*: bidirectional audio connected' 10 "A: primary call with 600 has two-way audio (in_call)"

say "Start B (TV) with a direct monitor call to A without Asterisk"
"$HOST_BIN" --data "$WORK/b" --name tv-b --role indoor_panel \
  --listen 127.0.0.1:47273 --http 0 --psk "$PSK" --sip-null \
  --monitor-call sip:127.0.0.1:47190 --monitor-delay-ms 2000 > "$LOG_B" 2>&1 &
PID_B=$!

wait_log "$LOG_B" 'calling sip:127.0.0.1:47190 (mode=monitor)' 10 "B: direct call uses X-Doorbell-Mode: monitor"
wait_log "$LOG_A" 'accepted monitor call #' 10 "A: monitor call accepted alongside the primary call"
wait_log "$LOG_A" 'monitor call #.*: one-way microphone audio connected' 10 "A: conference connects one-way microphone audio to the monitor"
wait_log "$LOG_B" '"state":"in_call"' 10 "B: monitor call established (in_call)"

say "Monitor for three seconds, then stop B"
sleep 3
kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_log "$LOG_A" 'monitor call #.* ended' 10 "A: only the monitor call ended"

# Verify through A's /api/status that the primary call remains active.
ST=$(curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status")
if printf '%s' "$ST" | grep -q '"call":[[:space:]]*"in_call"'; then
  ok "A: primary call with 600 remains active"
else
  ng "A: primary call ended unexpectedly: $(printf '%s' "$ST" | head -c 300)"
fi

say "Result: PASS=$PASS FAIL=$FAIL (logs: $WORK)"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
