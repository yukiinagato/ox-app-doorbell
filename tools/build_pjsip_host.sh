#!/usr/bin/env bash
# Build static PJSIP libraries for macOS development and tests.
# Output: core/third_party/pjsip/host/{lib,include}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/core/third_party/pjsip/src"
PREFIX="$ROOT/core/third_party/pjsip/host"
[[ -d "$SRC/pjlib" ]] || { echo "Run tools/fetch_pjsip.sh first."; exit 1; }

cd "$SRC"
if [[ ! -f build.mak ]]; then
  ./configure --prefix="$PREFIX" --disable-video --disable-opencore-amr \
    --disable-silk --disable-sdl --disable-ffmpeg --disable-v4l2 --disable-openh264 \
    --disable-vpx --disable-darwin-ssl --disable-ssl \
    CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" >/dev/null
fi
make dep >/dev/null 2>&1 || true
# PJSIP's Makefiles are not fully parallel-safe because targets such as g722 race while creating
# directories. Run the parallel build first, then complete it serially.
make -j8 >/dev/null 2>&1 || true
make >/dev/null
make install >/dev/null
echo "ok: $PREFIX"
ls "$PREFIX/lib" | head -5
