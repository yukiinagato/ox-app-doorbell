#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT=""

usage() {
  echo "usage: $0 --output PATH"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      OUTPUT="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ -n "$OUTPUT" ]] || { usage >&2; exit 2; }
CC="${CC:-$(command -v clang || command -v cc)}"
mkdir -p "$(dirname "$OUTPUT")"
"$CC" ${CPPFLAGS:-} ${CFLAGS:--std=c99 -Wall -Wextra -Werror -O2} \
  "$SCRIPT_DIR/doorbell_keepalive.c" ${LDFLAGS:-} -o "$OUTPUT.tmp"
mv "$OUTPUT.tmp" "$OUTPUT"
echo "$OUTPUT"
