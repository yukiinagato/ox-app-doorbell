#!/usr/bin/env bash
# =============================================================================
# build_libcxx_ios5.sh
#
# Phase A0 gate: build a MODERN libc++ / libc++abi / libunwind (C++17-capable)
# for armv7 / iOS 5.1, so the C++17 `core` can statically link into an armv7
# Mach-O runnable on an iPad 1.
#
# Toolchain : Xcode 26.x host clang (Apple clang 21) as a cross compiler.
# Sysroot   : tools/sdk/iPhoneOS7.1.sdk (extracted Xcode 5.1 iOS SDK).
# LLVM      : 17.0.6 runtimes (libcxx / libcxxabi / libunwind only).
#             Why 17.0.6: full C++17/20; last of the 17.x line; predates the
#             libc++ churn (18+) that starts requiring C++23 to *build* and
#             adds hardening that pulls in newer libc symbols. 17.x is the
#             sweet spot that still builds cleanly against a 2012-era libSystem.
#
# Products (git-ignored):
#   tools/toolchain/ios5-armv7/lib/{libc++.a,libc++abi.a,libunwind.a}
#   tools/toolchain/ios5-armv7/include/c++/v1/*
#
# The whole thing is link-verified only (no iPad to run on): compile+link a
# C++17 program, then `lipo -info` (armv7) + `otool -L` (no libc++ dylib dep).
#
# Re-runnable. Downloads LLVM source into tools/llvm-src (git-ignored).
# =============================================================================
set -euo pipefail

# --- paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LLVM_VER="17.0.6"
SRC_ROOT="$ROOT/tools/llvm-src"
LLVM_SRC="$SRC_ROOT/llvm-project-$LLVM_VER.src"
SDK="$ROOT/tools/sdk/iPhoneOS7.1.sdk"
BUILD_DIR="$SRC_ROOT/build-ios5-armv7"
PREFIX="$ROOT/tools/toolchain/ios5-armv7"
SHIM="$ROOT/tools/ios5_shim"   # committed shim headers (missing System/*.h etc.)

IOS_MIN="5.1"
ARCH="armv7"

CC_BIN="$(xcrun -f clang)"
CXX_BIN="$(xcrun -f clang++)"

echo "== config =="
echo "  LLVM      : $LLVM_VER"
echo "  SDK       : $SDK"
echo "  arch/min  : $ARCH / iOS $IOS_MIN"
echo "  clang     : $CC_BIN"
echo "  prefix    : $PREFIX"

[ -d "$SDK" ] || { echo "FATAL: SDK not found at $SDK"; exit 1; }

# --- 1. fetch LLVM source (runtimes subset only) -----------------------------
mkdir -p "$SRC_ROOT"
TARBALL="$SRC_ROOT/llvm-project-$LLVM_VER.src.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "== downloading LLVM $LLVM_VER source (~130 MB) =="
  curl -L --fail -o "$TARBALL" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/llvm-project-$LLVM_VER.src.tar.xz"
fi
if [ ! -d "$LLVM_SRC/runtimes" ]; then
  echo "== extracting runtimes subset =="
  PFX="llvm-project-$LLVM_VER.src"
  tar -C "$SRC_ROOT" -xf "$TARBALL" \
    "$PFX/cmake" "$PFX/runtimes" "$PFX/libcxx" "$PFX/libcxxabi" \
    "$PFX/libunwind" "$PFX/third-party" "$PFX/llvm/cmake"
fi

# --- 1b. source patches for the ancient-SDK / armv7-SjLj configuration --------
# All patches are idempotent (keyed off a marker) and target the extracted LLVM
# source (and, for one, the extracted SDK). Each works around a place where
# LLVM 17 assumes a modern Apple SDK (iOS >= 10) that our iOS 5.1 target isn't.

# P1: libunwind.cpp. Its `#ifdef __APPLE__` dynamic-unwind-sections block uses
#     RWMutex + the namespace-scoped finder statics, but on the SjLj path
#     (armv7-apple-ios) RWMutex.hpp is never included and there's no
#     `using namespace libunwind;` (both live inside the non-SjLj block). Add
#     both just before the Apple block.
UW="$LLVM_SRC/libunwind/src/libunwind.cpp"
if ! grep -q 'DB_IOS5_RWMUTEX_FIX' "$UW"; then
  perl -0pi -e 's{(#endif // !defined\(__USING_SJLJ_EXCEPTIONS__\)\n)}{$1\n// DB_IOS5_RWMUTEX_FIX: on the SjLj path RWMutex.hpp and the `using namespace`\n// are skipped, but the Apple dynamic-unwind block below needs both\n// (armv7-apple-ios uses SjLj exceptions).\n#include "RWMutex.hpp"\nusing namespace libunwind;\n}' "$UW"
  echo "== P1 patched libunwind.cpp (RWMutex include + using namespace) =="
fi

# P2: the extracted iOS 7.1 SDK's <sys/_types/_mbstate_t.h> does `typedef
#     __darwin_mbstate_t mbstate_t;` without first pulling <machine/_types.h>
#     (2012-era header; modern SDKs self-include it). libc++'s <__mbstate_t.h>
#     includes it directly, so __darwin_mbstate_t is undefined. Add the include
#     Apple later added. NOTE: this mutates the extracted SDK, so downstream
#     `core` builds (which share this SDK) inherit the fix automatically.
MB="$SDK/usr/include/sys/_types/_mbstate_t.h"
if [ -f "$MB" ] && ! grep -q 'DB_IOS5_MBSTATE_FIX' "$MB"; then
  perl -0pi -e 's{(#define _MBSTATE_T\n)}{$1#include <machine/_types.h> /* DB_IOS5_MBSTATE_FIX: __darwin_mbstate_t */\n}' "$MB"
  echo "== P2 patched SDK _mbstate_t.h (self-include machine/_types.h) =="
fi

# P3/P4/P5: chrono.cpp + filesystem_clock.cpp assume every Apple target has
#     clock_gettime + CLOCK_* (true only iOS>=10). iOS 5.1 has neither (it does
#     have gettimeofday + mach_absolute_time). These are compiled INTO libc++.a,
#     so the fix is build-only — downstream just links the compiled functions.
#     _POSIX_TIMERS is -1 here, so dropping __APPLE__ from the enabling #if
#     leaves _LIBCPP_HAS_CLOCK_GETTIME undefined => system_clock/file_clock use
#     the gettimeofday fallback. steady_clock's Apple branch is separate and
#     hard-codes clock_gettime(CLOCK_MONOTONIC_RAW) => rewrite it to
#     mach_absolute_time (the pre-iOS10 libc++ implementation).
CH="$LLVM_SRC/libcxx/src/chrono.cpp"
FC="$LLVM_SRC/libcxx/src/filesystem/filesystem_clock.cpp"
for f in "$CH" "$FC"; do
  if [ -f "$f" ] && ! grep -q 'DB_IOS5_CLOCK_FIX' "$f"; then
    perl -0pi -e 's{#if defined\(__APPLE__\) \|\| defined \(__gnu_hurd__\) \|\| \(defined\(_POSIX_TIMERS\) && _POSIX_TIMERS > 0\)}{/* DB_IOS5_CLOCK_FIX: __APPLE__ removed; iOS 5.1 lacks clock_gettime */\n#if defined (__gnu_hurd__) || (defined(_POSIX_TIMERS) && _POSIX_TIMERS > 0)}' "$f"
    echo "== P3/P5 patched $(basename "$f") (drop __APPLE__ clock_gettime) =="
  fi
done
if ! grep -q 'DB_IOS5_STEADY_FIX' "$CH"; then
  perl -0pi -e 's{    struct timespec tp;\n    if \(0 != clock_gettime\(CLOCK_MONOTONIC_RAW, &tp\)\)\n        __throw_system_error\(errno, "clock_gettime\(CLOCK_MONOTONIC_RAW\) failed"\);\n    return steady_clock::time_point\(seconds\(tp\.tv_sec\) \+ nanoseconds\(tp\.tv_nsec\)\);}{    // DB_IOS5_STEADY_FIX: CLOCK_MONOTONIC_RAW absent pre-iOS10; use mach.\n    static mach_timebase_info_data_t __base;\n    if (__base.denom == 0)\n        (void)mach_timebase_info(&__base);\n    const uint64_t __t = mach_absolute_time();\n    const uint64_t __ns = __t / __base.denom * __base.numer\n                        + __t % __base.denom * __base.numer / __base.denom;\n    return steady_clock::time_point(nanoseconds(__ns));}' "$CH"
  echo "== P4 patched chrono.cpp (steady_clock -> mach_absolute_time) =="
fi

# --- 2. configure the runtimes build -----------------------------------------
# CMAKE_SYSTEM_NAME=iOS => CMAKE_CROSSCOMPILING=TRUE => try_compile only, no
# try_run (we cannot run armv7 on the arm64 host). Feature checks that fail to
# compile (e.g. thread_local, unsupported on this target) just leave their
# HAVE_* off; libc++abi then falls back to pthread-key exception storage.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Shared cross flags.
#  -I$SHIM              : supplies <System/pthread_machdep.h> (SjLj TSD), absent
#                         from the extracted 7.1 SDK.
#  -D_LIBCPP_HAS_NO_C11_ALIGNED_ALLOC : iOS 5.1 libc has no C11 aligned_alloc();
#                         make libc++ fall back to posix_memalign(). MUST also be
#                         baked into the installed __config_site (done post-install)
#                         so downstream `core` builds instantiate the same path.
XFLAGS="-arch $ARCH -miphoneos-version-min=$IOS_MIN -isysroot $SDK -I$SHIM -D_LIBCPP_HAS_NO_C11_ALIGNED_ALLOC"

cmake -G Ninja -S "$LLVM_SRC/runtimes" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_COMPILER="$CC_BIN" \
  -DCMAKE_CXX_COMPILER="$CXX_BIN" \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN" \
  -DCMAKE_C_FLAGS="$XFLAGS" \
  -DCMAKE_CXX_FLAGS="$XFLAGS" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
  \
  -DLIBCXX_ENABLE_SHARED=OFF \
  -DLIBCXX_ENABLE_STATIC=ON \
  -DLIBCXX_CXX_ABI=libcxxabi \
  -DLIBCXX_ENABLE_FILESYSTEM=OFF \
  -DLIBCXX_HAS_MUSL_LIBC=OFF \
  -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
  -DLIBCXX_INCLUDE_TESTS=OFF \
  -DLIBCXX_INCLUDE_DOCS=OFF \
  -DLIBCXX_ENABLE_EXCEPTIONS=ON \
  -DLIBCXX_ENABLE_RTTI=ON \
  -DLIBCXX_USE_COMPILER_RT=ON \
  -DLIBCXX_ENABLE_STATIC_ABI_LIBRARY=OFF \
  \
  -DLIBCXXABI_ENABLE_SHARED=OFF \
  -DLIBCXXABI_ENABLE_STATIC=ON \
  -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
  -DLIBCXXABI_ENABLE_STATIC_UNWINDER=ON \
  -DLIBCXXABI_USE_COMPILER_RT=ON \
  -DLIBCXXABI_INCLUDE_TESTS=OFF \
  -DLIBCXXABI_ENABLE_EXCEPTIONS=ON \
  \
  -DLIBUNWIND_ENABLE_SHARED=OFF \
  -DLIBUNWIND_ENABLE_STATIC=ON \
  -DLIBUNWIND_USE_COMPILER_RT=ON \
  -DLIBUNWIND_INCLUDE_TESTS=OFF \
  -DLIBUNWIND_INCLUDE_DOCS=OFF

# --- 3. build + install ------------------------------------------------------
echo "== building (ninja) =="
ninja -C "$BUILD_DIR"
echo "== installing to $PREFIX =="
ninja -C "$BUILD_DIR" install

# --- 3b. bake target quirks into the installed __config_site -----------------
# Downstream `core` compiles against these headers with a stock modern clang and
# no special -D flags, so the "no C11 aligned_alloc" decision must live in the
# headers themselves, not only in this build's flags. __config_site is included
# by <__config> before anything else, so a define here is authoritative.
CS="$PREFIX/include/c++/v1/__config_site"
if [ -f "$CS" ] && ! grep -q 'DB_IOS5_QUIRKS' "$CS"; then
  # insert our defines just after the include-guard #define line
  perl -0pi -e 's{(#define _LIBCPP_CONFIG_SITE\n)}{$1\n// DB_IOS5_QUIRKS: iOS 5.1 libc lacks C11 aligned_alloc(); fall back to\n// posix_memalign() in <__memory/aligned_alloc.h>.\n#ifndef _LIBCPP_HAS_NO_C11_ALIGNED_ALLOC\n#define _LIBCPP_HAS_NO_C11_ALIGNED_ALLOC\n#endif\n}' "$CS"
  echo "== baked iOS5 quirks into __config_site =="
fi

echo "== done. products: =="
ls -la "$PREFIX/lib/"*.a
echo "Now run:  tools/verify_libcxx_ios5.sh"
