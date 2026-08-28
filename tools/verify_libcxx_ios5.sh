#!/usr/bin/env bash
# Verify the Phase A0 gate: compile a C++17 program against the freshly built
# armv7/iOS5.1 libc++ and link it statically. Cannot run it (no iPad) — the
# gate is: compiles + links + `lipo` says armv7 + `otool -L` shows no libc++
# dylib dependency (i.e. the C++ runtime is statically linked in).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK="$ROOT/tools/sdk/iPhoneOS7.1.sdk"
TC="$ROOT/tools/toolchain/ios5-armv7"
RT="$(xcrun clang -print-resource-dir)/lib/darwin/libclang_rt.ios.a" # armv7 builtins (emutls, aeabi, ...)
OUT="$ROOT/tools/toolchain/test_ios5_armv7"
SRC="$SCRIPT_DIR/test_cpp17.cpp"   # tracked; tools/toolchain/ is git-ignored

COMMON=(-arch armv7 -miphoneos-version-min=5.1 -isysroot "$SDK")

echo "== compile (nostdinc++, our headers) =="
xcrun clang++ "${COMMON[@]}" -std=c++17 -nostdinc++ \
  -I "$TC/include/c++/v1" -c "$SRC" -o "$ROOT/tools/toolchain/test.o"

echo "== link (static libc++ / libc++abi / libunwind + armv7 builtins) =="
# libc++abi/libunwind supply the C++ ABI + SjLj unwinder; libclang_rt.ios.a
# supplies armv7 compiler builtins. -lc++abi twice is unnecessary; order is
# c++ -> c++abi -> unwind -> builtins.
xcrun clang++ "${COMMON[@]}" -nostdlib++ \
  "$ROOT/tools/toolchain/test.o" \
  "$TC/lib/libc++.a" "$TC/lib/libc++abi.a" "$TC/lib/libunwind.a" \
  "$RT" \
  -o "$OUT"

echo
echo "===== RESULT ====="
echo "-- lipo -info --"
lipo -info "$OUT"
echo "-- otool -L (dynamic deps; must NOT list libc++/libc++abi) --"
otool -L "$OUT"
echo
echo "-- file --"
file "$OUT"
echo "GATE: compiled + linked OK -> see lipo/otool above"
