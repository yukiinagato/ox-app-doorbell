#!/usr/bin/env bash
# macOS ホスト用 pjsip 静的ライブラリのビルド (開発・テスト用)。
# 産物: core/third_party/pjsip/host/{lib,include}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core/third_party/pjsip/src"
PREFIX="$ROOT/core/third_party/pjsip/host"
[[ -d "$SRC/pjlib" ]] || { echo "先に tools/fetch_pjsip.sh を実行"; exit 1; }

cd "$SRC"
if [[ ! -f build.mak ]]; then
  ./configure --prefix="$PREFIX" --disable-video --disable-opencore-amr \
    --disable-silk --disable-sdl --disable-ffmpeg --disable-v4l2 --disable-openh264 \
    --disable-vpx --disable-darwin-ssl --disable-ssl \
    CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" >/dev/null
fi
make dep >/dev/null 2>&1 || true
# pjsip の Makefile は完全な並列安全ではない (g722 等でディレクトリ生成競合) —
# 並列で走らせてから串行で補完する
make -j8 >/dev/null 2>&1 || true
make >/dev/null
make install >/dev/null
echo "ok: $PREFIX"
ls "$PREFIX/lib" | head -5
