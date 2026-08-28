# iOS / tvOS クロスビルド toolchain (Phase 4)。
# 使い方:
#   cmake -S core -B build-ios \
#     -DCMAKE_TOOLCHAIN_FILE=core/cmake/ios.cmake \
#     -DDB_APPLE_PLATFORM=iphoneos|iphonesimulator|appletvos|appletvsimulator \
#     -DDB_BUILD_TESTS=OFF
# 産物は静的 lib (libdoorbell_core.a + libdb_third_party.a) — Xcode 側の
# run-script (ios/scripts/build_core.sh) がこれを呼んで libtool で 1 本に束ねる。
# DB_APPLE_PLATFORM は Xcode の $(PLATFORM_NAME) と同じ語彙にしてある。

if(NOT DEFINED DB_APPLE_PLATFORM)
  set(DB_APPLE_PLATFORM "iphoneos" CACHE STRING "iphoneos|iphonesimulator|appletvos|appletvsimulator")
endif()

if(DB_APPLE_PLATFORM MATCHES "^appletv")
  set(CMAKE_SYSTEM_NAME tvOS)
  # tvOS 監視端 (DoorbellTV) は 15.0+ — 計画書 §3
  if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "")
  endif()
else()
  set(CMAKE_SYSTEM_NAME iOS)
  # 旧機下限 iOS 12 (docs/overview.md 端末別対応表)
  if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "")
  endif()
endif()

# 実機/シミュレータの SDK 名はそのまま CMAKE_OSX_SYSROOT に渡せる
set(CMAKE_OSX_SYSROOT "${DB_APPLE_PLATFORM}" CACHE STRING "")

# 対象は arm64 のみ (Apple Silicon Mac のシミュレータも arm64。x86_64 Mac で
# シミュレータビルドが要る時は -DCMAKE_OSX_ARCHITECTURES=x86_64 で上書き)
if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
endif()

# 静的 lib しか作らない (try_compile が実行不能バイナリで失敗しないように)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
