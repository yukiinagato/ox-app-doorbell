#!/usr/bin/env bash
# 室内対講 (answer 接管) の 2 プロセス半自動テスト。dev_monitor_test.sh の姉妹編。
#
# シナリオ 1 (接管 — 電話が鳴っている間に室内機が応答):
#   A = 門口機 (8001)。dev Asterisk に登録し、press → 602 (鳴りっぱなし・応答しない)
#       へ発呼してリング中になる。
#   B = 室内機。Asterisk 非経由で A の SIP 待受 (udp 47190) へ直接 INVITE
#       (X-Doorbell-Mode: answer) → A は 602 への電話腿をキャンセルし (Asterisk CLI で
#       channel 消滅確認)、B と双方向通話を確立する。RTP 双方向 >50 を実測確認。
#
# シナリオ 2 (降級 — 電話で誰かが既に応答した後):
#   A: press → 600 (自動応答エコー) と通話確立 (CONFIRMED)。
#   B: 直呼 answer → A は主呼を奪わずモニタとして受理 (一方向降級)、主呼は継続。
#
# 前提: deploy/dev/asterisk が稼働中 (docker compose up -d)、build/ に doorbell_host。
#       602 が dialplan に無い場合は自動で dialplan reload を試みる。
# 使い方: tools/dev_intercom_test.sh   (終了コード 0 = 全チェック通過)
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
  ng "$4 (timeout: '$pat' が $f に出ない)"; return 1
}

# A の /api/status を jq 無しで検査 (grep) — 条件が出るまで最大 $2 秒待つ
wait_status() { # pattern timeout_s desc
  local pat=$1 t=$((10*$2))
  while (( t-- > 0 )); do
    curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status" 2>/dev/null \
      | grep -q "$pat" && { ok "$3"; return 0; }
    sleep 0.1
  done
  ng "$3 (timeout: status に '$pat' が出ない)"; return 1
}

[[ -x "$HOST_BIN" ]] || { echo "build/doorbell_host が無い — 先に cmake -S core -B build && cmake --build build"; exit 2; }
if command -v lsof >/dev/null && lsof -nP -iUDP:47190 | grep -q .; then
  echo "中止: udp 47190 を他プロセスが使用中 — 門口機 A の直接待受が立てられない"; exit 2
fi

# 602 (鳴りっぱなし) が dialplan に居ることを確認 — 居なければ reload を試す
if ! $AST "dialplan show 602@from-door" 2>/dev/null | grep -q "Ringing"; then
  echo "dialplan に 602 が無い — reload を試みる (deploy/dev/asterisk/conf/extensions.conf)"
  $AST "dialplan reload" >/dev/null 2>&1
  sleep 1
  $AST "dialplan show 602@from-door" 2>/dev/null | grep -q "Ringing" || {
    echo "中止: 602 が生えない — deploy/dev/asterisk を最新 conf で再起動すること"; exit 2; }
fi

# 開発 mesh (psk 0x5a 既定) に合流しないよう専用 PSK
PSK=$(printf '7d%.0s' {1..32})

say "A (門口機 8001) 起動"
"$HOST_BIN" --data "$WORK/a" --name door-a --role door_station --door d_front \
  --listen 127.0.0.1:47274 --http $HTTP_A --psk "$PSK" \
  --sip-user 8001 --sip-pass devpass8001 --sip-null > "$LOG_A" 2>&1 &
PID_A=$!
sleep 1

CK="$WORK/cookie.txt"
curl -sf -c "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/login" \
  -d '{"password":"devtest"}' >/dev/null || { ng "admin ログイン"; exit 1; }
cfg() { curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/config" \
        -d "{\"key\":\"$1\",\"value\":$2}" >/dev/null || ng "config $1"; }
cfg sip.server '"\"127.0.0.1\""'
cfg sip.port '"5060"'
cfg trigger_rules.ring '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"602\"}]}"'

wait_log "$LOG_A" 'reg: registered' 10 "A: Asterisk 登録"

say "シナリオ 1: A press → 602 リング中 (未確立の電話腿)"
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_status '"call":[[:space:]]*"calling"' 10 "A: 602 呼び出し中 (calling — 未確立)"
if $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!'; then
  ok "Asterisk: 602 への channel が立っている"
else
  ng "Asterisk: 602 への channel が見えない"
fi

say "B (室内機) 起動 — A へ直呼 answer (接管)"
"$HOST_BIN" --data "$WORK/b" --name indoor-b --role indoor_panel \
  --listen 127.0.0.1:47275 --http $HTTP_B --psk "$PSK" --sip-null \
  --answer-call sip:127.0.0.1:47190 --monitor-delay-ms 3000 > "$LOG_B" 2>&1 &
PID_B=$!

wait_log "$LOG_B" '発呼 sip:127.0.0.1:47190 (mode=answer)' 15 "B: 直呼発信 (X-Doorbell-Mode: answer)"
wait_log "$LOG_A" 'answer 接管' 10 "A: answer 接管 (未確立主呼のキャンセル)"
wait_log "$LOG_A" '主呼 #.*音声双方向接続' 10 "A: 室内機と双方向接続"
wait_log "$LOG_B" '"state":"in_call"' 10 "B: 双方向通話確立 (in_call)"

# Asterisk 側の電話腿が消えたこと
t=50
while (( t-- > 0 )); do
  $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!' || break
  sleep 0.1
done
if $AST "core show channels concise" 2>/dev/null | grep -q 'from-door!602!'; then
  ng "Asterisk: 602 への channel が残っている (キャンセルされていない)"
else
  ok "Asterisk: 602 への channel 消滅 (電話腿キャンセル)"
fi

say "通話 3 秒 → RTP 双方向実測"
sleep 3
ST_A=$(curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status")
TX=$(printf '%s' "$ST_A" | sed -n 's/.*"rtp_tx":[[:space:]]*\([0-9]*\).*/\1/p')
RX=$(printf '%s' "$ST_A" | sed -n 's/.*"rtp_rx":[[:space:]]*\([0-9]*\).*/\1/p')
if [[ -n "$TX" && -n "$RX" && "$TX" -gt 50 && "$RX" -gt 50 ]]; then
  ok "A: RTP 双方向 (tx=$TX rx=$RX > 50)"
else
  ng "A: RTP が流れていない (tx=${TX:-?} rx=${RX:-?})"
fi

say "B 終了 → A はアイドルへ"
kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_status '"call":[[:space:]]*"idle"' 10 "A: 通話終了 (idle)"

say "シナリオ 2: A press → 600 (自動応答) と通話確立後の answer は降級"
cfg trigger_rules.ring '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}"'
sleep 1
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_status '"call":[[:space:]]*"in_call"' 10 "A: 600 と通話確立 (CONFIRMED)"

"$HOST_BIN" --data "$WORK/b2" --name indoor-b2 --role indoor_panel \
  --listen 127.0.0.1:47276 --http 0 --psk "$PSK" --sip-null \
  --answer-call sip:127.0.0.1:47190 --monitor-delay-ms 3000 > "$LOG_B" 2>&1 &
PID_B=$!
wait_log "$LOG_A" 'answer 着信だが主呼 #.* は応答済み — モニタへ降級' 15 "A: answer 降級 (奪わない)"
wait_log "$LOG_A" 'モニタ呼受理' 10 "A: モニタとして受理"
wait_status '"call":[[:space:]]*"in_call"' 5 "A: 主呼 (600) は継続中"

kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_log "$LOG_A" 'モニタ呼 #.*終了' 10 "A: モニタ呼のみ終了"

say "結果: PASS=$PASS FAIL=$FAIL  (ログ: $WORK)"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
