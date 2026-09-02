#!/usr/bin/env bash
# Fetch the pinned pjproject source archive and verify its SHA-256 digest.
# The expanded source is intentionally not committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER=2.15.1
DEST="$ROOT/core/third_party/pjsip"
URL="https://github.com/pjsip/pjproject/archive/refs/tags/$VER.tar.gz"
SHA_FILE="$ROOT/core/third_party/pjsip.sha256"

mkdir -p "$DEST"
TARBALL="$DEST/pjproject-$VER.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
  echo "fetch pjproject $VER ..."
  curl -sfL "$URL" -o "$TARBALL"
fi
ACTUAL=$(shasum -a 256 "$TARBALL" | awk '{print $1}')
if [[ -f "$SHA_FILE" ]]; then
  grep -q "$ACTUAL" "$SHA_FILE" || { echo "SHA256 mismatch: expected $(cat "$SHA_FILE"), actual $ACTUAL"; exit 1; }
else
  echo "$ACTUAL  pjproject-$VER.tar.gz" > "$SHA_FILE"
  echo "pinned initial SHA256: $ACTUAL"
fi

if [[ ! -d "$DEST/src/pjlib" ]]; then
  mkdir -p "$DEST/src"
  tar xzf "$TARBALL" -C "$DEST/src" --strip-components=1
fi

# The SIP backend is audio-only; Core owns the independent video pipeline.
cat > "$DEST/src/pjlib/include/pj/config_site.h" <<'EOF'
/* Generated Doorbell PJSIP configuration. */
#define PJMEDIA_HAS_VIDEO 0
#define PJSUA_MAX_CALLS 4
#define PJSUA_MAX_ACC 2
/* Door stations select the WebRTC echo canceller at runtime. */
EOF
echo "ok: $DEST/src"
