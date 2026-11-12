#!/bin/sh
# Drives the Windows UI smoke suite on a LAN test PC from this Mac, with no manual step on
# the PC. The PC must have been prepared once with win/scripts/setup_test_host.ps1.
#
#   win/scripts/run_remote_tests.sh <host> [user] [--run <id> | --zip <bundle.zip>]
#                                   [--roles "indoor_panel door_station"] [--out <dir>]
#                                   [--port <ssh port>]
#
#   --run <id>   GitHub Actions run whose "doorbell-win-test-bundle" artifact to test.
#                Default: the newest successful build run of the current branch.
#   --zip <file> A local zip of the bundle (the directory holding app\DoorbellApp.exe).
#   --port <n>   SSH port of the test PC when setup_test_host.ps1 was run with -Port.
#                Default 22, or $DOORBELL_WIN_TEST_PORT.
#
# The app under test is an isolated instance: a throwaway data directory, an unpaired
# boot.json with no seed peers, ports away from the defaults, and two firewall rules that
# block cluster discovery (UDP 47171) for that copy of DoorbellApp.exe. The rules are added
# at the start of every run and removed at the end, also when the run fails.
set -eu

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ $# -ge 1 ] || usage
HOST="$1"; shift
USER_NAME="${USER:-}"
case "${1:-}" in ""|--*) ;; *) USER_NAME="$1"; shift ;; esac
RUN_ID=""; ZIP=""; ROLES="indoor_panel door_station"; OUT=""
PORT="${DOORBELL_WIN_TEST_PORT:-22}"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN_ID="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    --roles) ROLES="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
KEY="$HOME/.ssh/doorbell_win_test_ed25519"
[ -f "$KEY" ] || { echo "missing SSH key $KEY" >&2; exit 2; }
ARTIFACT="doorbell-win-test-bundle"
REMOTE_ROOT='C:\DoorbellTest'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REMOTE_RUN="$REMOTE_ROOT\\runs\\$STAMP"
REMOTE_RUN_SCP="C:/DoorbellTest/runs/$STAMP"
[ -n "$OUT" ] || OUT="$ROOT/build-redesign-win/remote-tests/$STAMP"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/doorbell-win-remote.XXXXXX")"
TARGET="$USER_NAME@$HOST"
case "$PORT" in ''|*[!0-9]*) echo "invalid --port: $PORT" >&2; exit 2 ;; esac
COMMON_OPTS="-i $KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
# ssh and scp spell the port option differently (-p / -P).
SSH_OPTS="-p $PORT $COMMON_OPTS"
SCP_OPTS="-P $PORT $COMMON_OPTS"

# The remote default shell is Windows PowerShell (setup_test_host.ps1 sets it). The command is
# sent base64-encoded so no quoting has to survive two shells.
remote() {
  encoded="$(printf '%s' "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; \$ProgressPreference='SilentlyContinue'; \$ErrorActionPreference='Stop'; $1" |
    iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')"
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$TARGET" "powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded"
}

RULES_ADDED=0
cleanup() {
  status=$?
  if [ "$RULES_ADDED" = 1 ]; then
    # Always: the temporary discovery block must not outlive the run.
    remote "Get-Process DoorbellApp -ErrorAction SilentlyContinue | Where-Object { \$_.Path -like '$REMOTE_ROOT\\*' } | Stop-Process -Force -ErrorAction SilentlyContinue; foreach (\$n in 'DoorbellTest block discovery (in)','DoorbellTest block discovery (out)') { Get-NetFirewallRule -DisplayName \$n -ErrorAction SilentlyContinue | Remove-NetFirewallRule }; 'temporary firewall rules removed'" ||
      echo "WARNING: could not remove the temporary firewall rules on $HOST; run setup_test_host.ps1 -Uninstall or remove 'DoorbellTest block discovery (in/out)' by hand" >&2
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- 1. the bundle ---------------------------------------------------------------------------
if [ -z "$ZIP" ]; then
  command -v gh >/dev/null || { echo "gh is required to download the CI artifact (or pass --zip)" >&2; exit 2; }
  if [ -z "$RUN_ID" ]; then
    BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
    RUN_ID="$(cd "$ROOT" && gh run list --workflow build --branch "$BRANCH" --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
    [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] || { echo "no successful build run on $BRANCH; pass --run or --zip" >&2; exit 2; }
  fi
  echo "== downloading $ARTIFACT from run $RUN_ID"
  (cd "$ROOT" && gh run download "$RUN_ID" -n "$ARTIFACT" -D "$WORK/bundle")
  [ -n "$(find "$WORK/bundle" -name DoorbellApp.exe -print -quit)" ] ||
    { echo "the artifact holds no DoorbellApp.exe" >&2; exit 1; }
  ZIP="$WORK/bundle.zip"
  (cd "$WORK/bundle" && zip -qr "$ZIP" .)
fi
[ -f "$ZIP" ] || { echo "bundle not found: $ZIP" >&2; exit 2; }

# ---- 2. copy ---------------------------------------------------------------------------------
echo "== preparing $HOST"
remote "if (-not (Test-Path '$REMOTE_ROOT\\run-job.ps1')) { throw 'This PC is not prepared: run setup_test_host.ps1 on it once.' }; New-Item -ItemType Directory -Force -Path '$REMOTE_RUN' | Out-Null; 'ok'"
# shellcheck disable=SC2086
scp $SCP_OPTS -q "$ZIP" "$TARGET:$REMOTE_RUN_SCP/bundle.zip"
# shellcheck disable=SC2086
scp $SCP_OPTS -q "$ROOT/win/scripts/ui_smoke.ps1" "$TARGET:$REMOTE_RUN_SCP/ui_smoke.ps1"

# ---- 3. unpack, block discovery, write the job ------------------------------------------------
ROLE_LIST="$(printf "'%s'," $ROLES | sed 's/,$//')"
# Set before the call: if it fails half way the rules may already exist and must be removed.
RULES_ADDED=1
remote "
Expand-Archive -LiteralPath '$REMOTE_RUN\\bundle.zip' -DestinationPath '$REMOTE_RUN\\bundle' -Force
\$exe = Get-ChildItem -LiteralPath '$REMOTE_RUN\\bundle' -Recurse -Filter DoorbellApp.exe | Select-Object -First 1
if (\$null -eq \$exe) { throw 'no DoorbellApp.exe in the bundle' }
if (Get-Process DoorbellApp -ErrorAction SilentlyContinue) { throw 'DoorbellApp is already running on this PC; close it first' }
foreach (\$n in 'DoorbellTest block discovery (in)','DoorbellTest block discovery (out)') { Get-NetFirewallRule -DisplayName \$n -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
New-NetFirewallRule -DisplayName 'DoorbellTest block discovery (in)' -Direction Inbound -Action Block -Protocol UDP -LocalPort 47171 -Program \$exe.FullName -Description 'Temporary: removed when the Doorbell UI test run ends.' | Out-Null
New-NetFirewallRule -DisplayName 'DoorbellTest block discovery (out)' -Direction Outbound -Action Block -Protocol UDP -RemotePort 47171 -Program \$exe.FullName -Description 'Temporary: removed when the Doorbell UI test run ends.' | Out-Null
\$job = @(
  \"\`\$code = 0\",
  \"foreach (\`\$role in @($ROLE_LIST)) {\",
  \"  & '$REMOTE_RUN\\ui_smoke.ps1' -AppExe '\$(\$exe.FullName)' -OutDir '$REMOTE_RUN\\out' -Role \`\$role\",
  \"  if (\`\$LASTEXITCODE -ne 0) { \`\$code = 1 }\",
  \"}\",
  \"exit \`\$code\"
)
Set-Content -LiteralPath '$REMOTE_ROOT\\jobs\\job.ps1' -Value \$job -Encoding UTF8
Remove-Item -LiteralPath '$REMOTE_ROOT\\jobs\\job.exit','$REMOTE_ROOT\\jobs\\job.log' -ErrorAction SilentlyContinue
'bundle unpacked, discovery blocked for ' + \$exe.FullName
"

# The suite needs a desktop that is being drawn. A Remote Desktop session that was
# disconnected keeps running but renders nothing, so every screenshot would be black.
# quser prints the state as "Disc"; \u5207\u65AD is the same word on a Japanese system.
SESSION="$(remote "\$u='$USER_NAME'; \$line = @(& quser.exe 2>\$null | Select-String -SimpleMatch \$u | Select-Object -First 1); if (\$line.Count -eq 0) { 'none' } elseif ([string]\$line[0] -match '\\sDisc\\s|\\s\\u5207\\u65AD\\s') { 'disconnected' } else { 'active' }" | tr -d '\r' | tail -1)"
case "$SESSION" in
  active) ;;
  disconnected) echo "ERROR: $USER_NAME's desktop session on $HOST is disconnected (Remote Desktop closed). Reconnect and keep the window open, then run again." >&2; exit 3 ;;
  *) echo "ERROR: $USER_NAME is not logged on at $HOST, so there is no desktop to run the app in. Log on (console or Remote Desktop) and run again." >&2; exit 3 ;;
esac

# ---- 4. run in the desktop session and wait ---------------------------------------------------
echo "== running the UI smoke suite in the desktop session ($ROLES)"
remote "
Start-ScheduledTask -TaskName 'DoorbellTest-RunJob'
\$deadline = (Get-Date).AddMinutes(25)
while (-not (Test-Path '$REMOTE_ROOT\\jobs\\job.exit')) {
  if ((Get-Date) -gt \$deadline) { throw 'the UI job did not finish within 25 minutes (is the test user logged on and the screen unlocked?)' }
  Start-Sleep -Seconds 3
}
if (Test-Path '$REMOTE_ROOT\\jobs\\job.log') { Get-Content '$REMOTE_ROOT\\jobs\\job.log' }
Copy-Item '$REMOTE_ROOT\\jobs\\job.log' '$REMOTE_RUN\\out\\job.log' -ErrorAction SilentlyContinue
'job exit code ' + (Get-Content '$REMOTE_ROOT\\jobs\\job.exit')
" || echo "the remote job did not complete cleanly" >&2

# ---- 5. results ------------------------------------------------------------------------------
mkdir -p "$OUT"
# shellcheck disable=SC2086
scp $SCP_OPTS -q -r "$TARGET:$REMOTE_RUN_SCP/out/." "$OUT/" || echo "no results could be copied back" >&2
rm -rf "$OUT"/data-*          # the throwaway data directories are not results
echo "== results in $OUT"
FAILED=0
for role in $ROLES; do
  result="$OUT/result-$role.json"
  if [ ! -f "$result" ]; then echo "$role: no result file"; FAILED=1; continue; fi
  python3 - "$result" <<'PY' || FAILED=1
import json, sys
with open(sys.argv[1], encoding="utf-8-sig") as handle:
    result = json.load(handle)
print("%s: %d checks, %d failed, %d screenshots" % (
    result["role"], result["total"], result["failed"], len(result["screenshots"])))
for check in result["checks"]:
    if not check["ok"]:
        print("  FAIL %s %s" % (check["name"], check.get("detail", "")))
sys.exit(0 if result["passed"] else 1)
PY
done
exit "$FAILED"
