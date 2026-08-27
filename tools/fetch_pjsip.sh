#!/usr/bin/env bash
# pjproject を固定版で取得して core/third_party/pjsip/src に展開する。
# ソースは git に入れない (~40MB) — SHA256 ピン (core/third_party/pjsip.sha256) で再現性を担保。
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
  grep -q "$ACTUAL" "$SHA_FILE" || { echo "SHA256 不一致! expected: $(cat "$SHA_FILE") actual: $ACTUAL"; exit 1; }
else
  echo "$ACTUAL  pjproject-$VER.tar.gz" > "$SHA_FILE"
  echo "SHA256 を初回固定した: $ACTUAL"
fi

if [[ ! -d "$DEST/src/pjlib" ]]; then
  mkdir -p "$DEST/src"
  tar xzf "$TARBALL" -C "$DEST/src" --strip-components=1
fi

# config_site.h (音声のみビルド。ビデオは Phase 6 で別変体)
cat > "$DEST/src/pjlib/include/pj/config_site.h" <<'EOF'
/* doorbell 用 pjsip 設定 (tools/fetch_pjsip.sh が生成) */
#define PJMEDIA_HAS_VIDEO 0
#define PJSUA_MAX_CALLS 4
#define PJSUA_MAX_ACC 2
/* 門口機はスピーカーフォン — WebRTC AEC を使う (実行時に選択) */
EOF
echo "ok: $DEST/src"
