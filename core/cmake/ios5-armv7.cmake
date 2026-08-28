# iOS 5.1 / armv7 クロスビルド toolchain (Phase B — 旧 iPad 第1/2世代 監視端向け)。
#
# Phase A0 で自前ビルドした「現代 libc++ (LLVM 17.0.6) の armv7/iOS5.1 版」
# (tools/toolchain/ios5-armv7) と iOS 7.1 SDK sysroot (tools/sdk/iPhoneOS7.1.sdk) を使い、
# core を C++17 でクロスコンパイルする。実機は無いのでゲートは「コンパイル+アーカイブ成功」。
#
# 使い方:
#   cmake -S core -B build-ios5 -DCMAKE_TOOLCHAIN_FILE=core/cmake/ios5-armv7.cmake
#   cmake --build build-ios5 --target doorbell_core
# 産物は静的 lib (libdoorbell_core.a + libdb_third_party.a) — ios-legacy/scripts/
# build_core_ios5.sh がこれを libtool で 1 本 (libdoorbell_all.a) に束ねて armv7 を確認する。
#
# 注意:
#   * このファイルは Phase A0 の verify_libcxx_ios5.sh のフラグと同一のものを CMake 化したもの。
#   * PJSIP と テストは常に OFF (armv7/iOS5.1 では thread_local が clang に拒否される — 唯一の
#     使用箇所 sipctl.cpp は DB_WITH_PJSIP=OFF で除外される。テストは実機実行不能)。

# --- 絶対パス (toolchain file は core/cmake/ に置かれる → リポジトリ root は 2 つ上) ---
get_filename_component(_DB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_DB_SDK "${_DB_ROOT}/tools/sdk/iPhoneOS7.1.sdk")
set(_DB_TC  "${_DB_ROOT}/tools/toolchain/ios5-armv7")

if(NOT EXISTS "${_DB_SDK}/SDKSettings.plist")
  message(FATAL_ERROR "iOS7.1 SDK が見つからない: ${_DB_SDK} (tools/sdk は gitignore — 各自展開)")
endif()
if(NOT EXISTS "${_DB_TC}/include/c++/v1/version")
  message(FATAL_ERROR "ios5-armv7 libc++ が見つからない: ${_DB_TC} (Phase A0 の成果物)")
endif()

# --- Apple クロス構成 ---
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_OSX_ARCHITECTURES "armv7" CACHE STRING "")
set(CMAKE_OSX_SYSROOT "${_DB_SDK}" CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "5.1" CACHE STRING "")
set(CMAKE_CROSSCOMPILING ON)

# Xcode 21 の clang は armv7 を既定で拒否しがち — 明示ターゲットを固定する
set(CMAKE_C_COMPILER_TARGET   "armv7-apple-ios5.1")
set(CMAKE_CXX_COMPILER_TARGET "armv7-apple-ios5.1")

# 静的 lib しか作らない — try_compile が実行不能バイナリのリンクで失敗しないように
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# --- C++17: 既定 libc++ ヘッダを外し Phase A0 の armv7/iOS5.1 ヘッダを使う ---
# (-std=c++17 は CMAKE_CXX_STANDARD=17 が付ける。ここでは include 経路のみ差し替え)
set(CMAKE_CXX_FLAGS_INIT "-nostdinc++ -isystem ${_DB_TC}/include/c++/v1")

# --- リンカ: 静的 libc++/libc++abi/libunwind + armv7 builtins ---
# core は静的 lib のみ生成する (iOS 殻は Swift/ObjC 側で最終リンク) ため通常は未使用だが、
# 何かがリンクされた場合 (将来の実験含む) に C++ ランタイムと builtins を静的に供給する。
# libclang_rt.ios.a は Xcode の clang resource-dir にある armv7 builtins。
execute_process(
  COMMAND xcrun clang -print-resource-dir
  OUTPUT_VARIABLE _DB_RESDIR OUTPUT_STRIP_TRAILING_WHITESPACE)
set(_DB_RT "${_DB_RESDIR}/lib/darwin/libclang_rt.ios.a")
set(CMAKE_CXX_STANDARD_LIBRARIES
  "-nostdlib++ ${_DB_TC}/lib/libc++.a ${_DB_TC}/lib/libc++abi.a ${_DB_TC}/lib/libunwind.a ${_DB_RT}"
  CACHE STRING "" FORCE)

# --- ビルド構成の強制 (このファイルを使う=旧 iPad ターゲット=SIP/テスト無し) ---
set(DB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DB_WITH_PJSIP  OFF CACHE BOOL "" FORCE)

# クロス検索はターゲット SDK 内のみ (host の /usr を拾わない)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
