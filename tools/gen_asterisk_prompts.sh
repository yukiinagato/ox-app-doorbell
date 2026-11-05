#!/usr/bin/env bash
# Renders the Asterisk voice-menu prompts (deploy/asterisk/doorbell-menu.conf) to audio.
#
# Texts come from i18n/strings.yaml (core.ivr.*). The reply menu reads the cluster's quick
# replies in display order; pass the configuration exported from Admin with --config, otherwise
# the first-run defaults are used. Audio is 8 kHz 16-bit mono WAV written by macOS `say`.
#
# Usage:
#   tools/gen_asterisk_prompts.sh [--config export.json] [--langs ja,en,zh]
#                                 [--out deploy/asterisk/sounds] [--dry-run]
# Output: <out>/<lang>/{menu,reply-menu,invalid,reply-sent,declined}.wav
# Copy each <out>/<lang> directory to /var/lib/asterisk/sounds/<lang>/doorbell/ on the PBX.
# The script also prints REPLY_COUNT and the sip.dtmf_actions mapping the door stations need;
# both must match the reply order read out here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=""
LANGS="ja,en,zh"
OUT="$ROOT/deploy/asterisk/sounds"
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --langs) LANGS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
python3 "$ROOT/tools/asterisk_prompts.py" --strings "$ROOT/i18n/strings.yaml" \
  --langs "$LANGS" ${CONFIG:+--config "$CONFIG"} --manifest "$MANIFEST"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$MANIFEST"
  exit 0
fi
if ! command -v say >/dev/null 2>&1; then
  echo "macOS 'say' is required to render audio (use --dry-run to see the texts)" >&2
  exit 1
fi

pick_voice() {
  local installed candidate
  installed="$(say -v '?' | awk '{print $1}')"
  for candidate in "$@"; do
    if printf '%s\n' "$installed" | grep -qx "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

while IFS=$'\t' read -r lang file text; do
  case "$lang" in
    ja) voice="$(pick_voice Kyoko Otoya)" || { echo "no Japanese voice installed" >&2; exit 1; } ;;
    en) voice="$(pick_voice Samantha Alex Daniel)" || { echo "no English voice installed" >&2; exit 1; } ;;
    zh) voice="$(pick_voice Tingting Ting-Ting Meijia)" || { echo "no Chinese voice installed" >&2; exit 1; } ;;
    *) echo "unsupported language: $lang" >&2; exit 1 ;;
  esac
  mkdir -p "$OUT/$lang"
  say -v "$voice" -o "$OUT/$lang/$file.wav" --file-format=WAVE --data-format=LEI16@8000 "$text"
  echo "wrote $OUT/$lang/$file.wav ($voice)"
done < <(grep -v '^#' "$MANIFEST")
grep '^#' "$MANIFEST" | sed 's/^# //'
