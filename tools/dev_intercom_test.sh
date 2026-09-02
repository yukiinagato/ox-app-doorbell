#!/usr/bin/env bash
# Two-process semi-automated indoor intercom test for answer takeover.
#
# Scenario 1 (takeover while the external phone is still ringing):
#   A is door station 8001. It registers with development Asterisk and press calls extension 602,
#   which rings without answering.
#   B is an indoor panel. It sends a direct INVITE to A's SIP listener on UDP 47190 without using
#   Asterisk. X-Doorbell-Mode: answer makes A cancel the 602 leg, establish two-way audio with B,
#   and produce more than 50 RTP packets in each direction.
#
# Scenario 2 (fallback after the external phone has already answered):
#   A calls the auto-answer echo extension 600 and reaches CONFIRMED.
#   B sends a direct answer call. A keeps the primary leg and accepts B as a one-way monitor.
#
# Prerequisites: deploy/dev/asterisk is running and build/doorbell_host exists.
# The test attempts a dialplan reload when extension 602 is missing.
# Usage: tools/dev_intercom_test.sh (exit code 0 means every check passed)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_BIN="$ROOT/build/doorbell_host"
WORK="$(mktemp -d /tmp/db-intercom-XXXXXX)"
LOG_A="$WORK/a.log"; LOG_B="$WORK/b.log"
HTTP_A=47281; HTTP_B=47282
AST="docker exec doorbell-dev-asterisk asterisk -rx"
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

wait_log() { # file pattern timeout_s desc
  local f=$1 pat=$2 t=$((10*$3))
  while (( t-- > 0 )); do
    grep -q "$pat" "$f" 2>/dev/null && { ok "$4"; return 0; }
    sleep 0.1
  done
  ng "$4 (timeout: '$pat' did not appear in $f)"; return 1
}

# Inspect A's /api/status with grep instead of jq, waiting at most $2 seconds.
wait_status() { # pattern timeout_s desc
  local pat=$1 t=$((10*$2))
  while (( t-- > 0 )); do
    curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status" 2>/dev/null \
      | grep -q "$pat" && { ok "$3"; return 0; }
    sleep 0.1
  done
  ng "$3 (timeout: '$pat' did not appear in status)"; return 1
}

[[ -x "$HOST_BIN" ]] || { echo "build/doorbell_host is missing. Run cmake -S core -B build && cmake --build build first."; exit 2; }
if command -v lsof >/dev/null && lsof -nP -iUDP:47190 | grep -q .; then
  echo "Aborting: another process uses UDP 47190, so door station A cannot listen for direct calls."; exit 2
fi

# Verify that extension 602 exists as a continuously ringing dialplan target; reload if needed.
if ! $AST "dialplan show 602@from-door" 2>/dev/null | grep -q "Ringing"; then
  echo "Extension 602 is missing from the dialplan; attempting a reload from deploy/dev/asterisk/conf/extensions.conf."
  $AST "dialplan reload" >/dev/null 2>&1
  sleep 1
  $AST "dialplan show 602@from-door" 2>/dev/null | grep -q "Ringing" || {
    echo "Aborting: extension 602 is still missing. Restart deploy/dev/asterisk with the current configuration."; exit 2; }
fi

# Use a dedicated PSK so this test cannot join the default development mesh.
PSK=$(printf '7d%.0s' {1..32})

say "Start A (door station 8001)"
"$HOST_BIN" --data "$WORK/a" --name door-a --role door_station --door d_front \
  --listen 127.0.0.1:47274 --http $HTTP_A --psk "$PSK" \
  --sip-user 8001 --sip-pass devpass8001 --sip-null > "$LOG_A" 2>&1 &
PID_A=$!
sleep 1

CK="$WORK/cookie.txt"
curl -sf -c "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/login" \
  -d '{"password":"devtest"}' >/dev/null || { ng "admin login"; exit 1; }
cfg() { curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/config" \
        -d "{\"key\":\"$1\",\"value\":$2}" >/dev/null || ng "config $1"; }
cfg sip.server '"\"127.0.0.1\""'
cfg sip.port '"5060"'
cfg trigger_rules.ring '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"602\"}]}"'

wait_log "$LOG_A" 'reg: registered' 10 "A: registered with Asterisk"

say "Scenario 1: A press starts an unestablished ringing leg to 602"
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_status '"call":[[:space:]]*"calling"' 10 "A: calling 602 without an established dialog"
if $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!'; then
  ok "Asterisk: channel to 602 exists"
else
  ng "Asterisk: channel to 602 is missing"
fi

say "Start B (indoor panel) with a direct answer call to A"
"$HOST_BIN" --data "$WORK/b" --name indoor-b --role indoor_panel \
  --listen 127.0.0.1:47275 --http $HTTP_B --psk "$PSK" --sip-null \
  --answer-call sip:127.0.0.1:47190 --monitor-delay-ms 3000 > "$LOG_B" 2>&1 &
PID_B=$!

wait_log "$LOG_B" 'calling sip:127.0.0.1:47190 (mode=answer)' 15 "B: direct call uses X-Doorbell-Mode: answer"
wait_log "$LOG_A" 'answer takeover: canceling unestablished primary call #' 10 "A: answer takeover cancels the unestablished primary leg"
wait_log "$LOG_A" 'primary call #.*: bidirectional audio connected' 10 "A: two-way audio connected to the indoor panel"
wait_log "$LOG_B" '"state":"in_call"' 10 "B: two-way call established (in_call)"

# Verify that the external Asterisk leg disappeared.
t=50
while (( t-- > 0 )); do
  $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!' || break
  sleep 0.1
done
if $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!'; then
  ng "Asterisk: the channel to 602 remains and was not canceled"
else
  ok "Asterisk: the channel to 602 disappeared after cancellation"
fi

say "Measure bidirectional RTP for three seconds"
sleep 3
ST_A=$(curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status")
TX=$(printf '%s' "$ST_A" | sed -n 's/.*"rtp_tx":[[:space:]]*\([0-9]*\).*/\1/p')
RX=$(printf '%s' "$ST_A" | sed -n 's/.*"rtp_rx":[[:space:]]*\([0-9]*\).*/\1/p')
if [[ -n "$TX" && -n "$RX" && "$TX" -gt 50 && "$RX" -gt 50 ]]; then
  ok "A: bidirectional RTP (tx=$TX rx=$RX > 50)"
else
  ng "A: RTP is not flowing (tx=${TX:-?} rx=${RX:-?})"
fi

say "Stop B and wait for A to return to idle"
kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_status '"call":[[:space:]]*"idle"' 10 "A: call ended (idle)"

say "Scenario 2: answer falls back after extension 600 auto-answers"
cfg trigger_rules.ring '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}"'
sleep 1
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_status '"call":[[:space:]]*"in_call"' 10 "A: call with 600 is established (CONFIRMED)"

"$HOST_BIN" --data "$WORK/b2" --name indoor-b2 --role indoor_panel \
  --listen 127.0.0.1:47276 --http 0 --psk "$PSK" --sip-null \
  --answer-call sip:127.0.0.1:47190 --monitor-delay-ms 3000 > "$LOG_B" 2>&1 &
PID_B=$!
wait_log "$LOG_A" 'incoming answer call cannot take over established primary call #.* is already answered; falling back to monitor mode' 15 "A: answer falls back without taking over"
wait_log "$LOG_A" 'accepted monitor call #' 10 "A: fallback call accepted as a monitor"
wait_status '"call":[[:space:]]*"in_call"' 5 "A: primary call with 600 remains active"

kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_log "$LOG_A" 'monitor call #.* ended' 10 "A: only the monitor call ended"

say "Result: PASS=$PASS FAIL=$FAIL (logs: $WORK)"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
