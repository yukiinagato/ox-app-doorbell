#!/usr/bin/env bash
# 門口監聴 (モニタ呼) の 2 プロセス半自動テスト。
#
# シナリオ (TV 監聴の実運用と同型):
#   A = 門口機 (8001)。dev Asterisk に登録し、press → 600 (自動応答エコー) と通話中になる。
#   B = TV/室内機。Asterisk 非経由で A の SIP 待受 (udp 47190) へ直接 INVITE
#       (X-Doorbell-Mode: monitor) → A がモニタ受理し「マイク→モニタ 一方向接続」する。
#   B 終了 → A のモニタ呼だけが終わり、主呼 (600) は継続していることを確認。
#
# 前提: deploy/dev/asterisk が稼働中 (docker compose up -d)、build/ に doorbell_host。
# 使い方: tools/dev_monitor_test.sh   (終了コード 0 = 全チェック通過)
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

# grep が当たるまで最大 $3 秒待つ
wait_log() { # file pattern timeout_s desc
  local f=$1 pat=$2 t=$((10*$3))
  while (( t-- > 0 )); do
    grep -q "$pat" "$f" 2>/dev/null && { ok "$4"; return 0; }
    sleep 0.1
  done
  ng "$4 (timeout: '$pat' が $f に出ない)"; return 1
}

[[ -x "$HOST_BIN" ]] || { echo "build/doorbell_host が無い — 先に cmake -S core -B build && cmake --build build"; exit 2; }
if ! nc -uz 127.0.0.1 5060 2>/dev/null; then
  echo "注意: dev Asterisk (127.0.0.1:5060/udp) の確認ができない — deploy/dev/asterisk を起動していること"
fi
if command -v lsof >/dev/null && lsof -nP -iUDP:47190 | grep -q .; then
  echo "中止: udp 47190 を他プロセスが使用中 — 門口機 A の直接待受が立てられない"; exit 2
fi

# 開発 mesh (psk 0x5a 既定) に合流しないよう専用 PSK
PSK=$(printf '7e%.0s' {1..32})

say "A (門口機 8001) 起動"
"$HOST_BIN" --data "$WORK/a" --name door-a --role door_station --door d_front \
  --listen 127.0.0.1:47272 --http $HTTP_A --psk "$PSK" \
  --sip-user 8001 --sip-pass devpass8001 --sip-null > "$LOG_A" 2>&1 &
PID_A=$!
sleep 1

# 管理 API で SIP + 呼出ルールを設定 (初回ログインでパスワードが立つ)
CK="$WORK/cookie.txt"
curl -sf -c "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/login" \
  -d '{"password":"devtest"}' >/dev/null || { ng "admin ログイン"; exit 1; }
cfg() { curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/config" \
        -d "{\"key\":\"$1\",\"value\":$2}" >/dev/null || ng "config $1"; }
cfg sip.server '"\"127.0.0.1\""'
cfg sip.port '"5060"'
cfg trigger_rules.mon '"{\"enabled\":true,\"when\":{\"type\":\"button\",\"doors\":[\"d_front\"]},\"actions\":[{\"type\":\"sip_call\",\"target_extension\":\"600\"}]}"'

wait_log "$LOG_A" 'reg: registered' 10 "A: Asterisk 登録"

say "A: press → 600 へ発呼 (主呼)"
curl -sf -b "$CK" -X POST "http://127.0.0.1:$HTTP_A/api/press" -d '{}' >/dev/null
wait_log "$LOG_A" '主呼 #.*音声双方向接続' 10 "A: 主呼 600 と双方向接続 (in_call)"

say "B (TV) 起動 — Asterisk 非経由で A へ直接モニタ呼"
"$HOST_BIN" --data "$WORK/b" --name tv-b --role indoor_panel \
  --listen 127.0.0.1:47273 --http 0 --psk "$PSK" --sip-null \
  --monitor-call sip:127.0.0.1:47190 --monitor-delay-ms 2000 > "$LOG_B" 2>&1 &
PID_B=$!

wait_log "$LOG_B" '発呼 sip:127.0.0.1:47190 (mode=monitor)' 10 "B: 直呼発信 (X-Doorbell-Mode: monitor)"
wait_log "$LOG_A" 'モニタ呼受理'                     10 "A: モニタ呼受理 (主呼進行中の追加着信)"
wait_log "$LOG_A" 'マイク→モニタ 一方向接続'          10 "A: conf 接続 マイク→モニタ (一方向)"
wait_log "$LOG_B" '"state":"in_call"'                10 "B: モニタ呼確立 (in_call)"

say "監聴 3 秒 → B 終了"
sleep 3
kill "$PID_B" 2>/dev/null; wait "$PID_B" 2>/dev/null; PID_B=""
wait_log "$LOG_A" 'モニタ呼 #.*終了' 10 "A: モニタ呼のみ終了"

# 主呼が生きていること (A の /api/status)
ST=$(curl -sf -b "$CK" "http://127.0.0.1:$HTTP_A/api/status")
if printf '%s' "$ST" | grep -q '"call":[[:space:]]*"in_call"'; then
  ok "A: 主呼 (600) は継続中"
else
  ng "A: 主呼が落ちている: $(printf '%s' "$ST" | head -c 300)"
fi

say "結果: PASS=$PASS FAIL=$FAIL  (ログ: $WORK)"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
