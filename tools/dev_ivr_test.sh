#!/usr/bin/env bash
# Automated check of the Asterisk voice menu (deploy/asterisk/doorbell-menu.conf) without a door
# station. SIPp plays the door leg; scripted "phones" inside the development Asterisk answer and
# press keys. Verifies the DTMF code Asterisk hands back to the door leg for each choice.
#
# Requires Docker. Run on the host that runs deploy/dev/asterisk:
#   tools/gen_asterisk_prompts.sh --langs en   # optional; prompts make the menu audible
#   tools/dev_ivr_test.sh
# Exit code 0 means every scenario produced the expected result.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$ROOT/deploy/dev/asterisk"
CONTAINER=doorbell-dev-asterisk
cd "$DEV"

mkdir -p "$ROOT/deploy/asterisk/sounds/en" "$ROOT/deploy/asterisk/sounds/ja" \
         "$ROOT/deploy/asterisk/sounds/zh"
if [ ! -f "$ROOT/deploy/asterisk/sounds/en/menu.wav" ]; then
  echo "note: no generated prompts; the menu runs silently (tools/gen_asterisk_prompts.sh)"
fi

docker compose up -d asterisk >/dev/null
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" asterisk -rx "core show version" >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$CONTAINER" asterisk -rx "dialplan reload" >/dev/null

failures=0
run_case() {
  local ext="$1" scenario="$2" expect="$3" label="$4"
  local since
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! docker compose --profile ivr-test run --rm sipp -sf "/sipp/$scenario" -s "$ext" \
      -au 8001 -ap devpass8001 -m 1 -l 1 -timeout 60 -timeout_error -nostdin \
      asterisk:5060 >/tmp/doorbell-ivr-sipp.log 2>&1; then
    echo "FAIL $label: SIPp scenario failed (see /tmp/doorbell-ivr-sipp.log)"
    failures=$((failures + 1))
    return
  fi
  sleep 1
  if docker logs --since "$since" "$CONTAINER" 2>&1 | grep -F -q "$expect"; then
    echo "PASS $label"
  else
    echo "FAIL $label: Asterisk log has no '$expect'"
    failures=$((failures + 1))
  fi
}

run_case 621 door_menu_unanswered.xml "doorbell-result door=8001 action=#21" "reply 1 -> #21"
run_case 622 door_menu_talk.xml "doorbell-menu talk" "talk -> bridged and answered"
run_case 623 door_menu_unanswered.xml "doorbell-result door=8001 action=#90" "decline -> #90"
run_case 624 door_menu_unanswered.xml "doorbell-result door=8001 action=#90" \
  "voicemail timeout -> #90"

if [ "$failures" -ne 0 ]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "all voice-menu scenarios passed"
