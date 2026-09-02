# iOS/tvOS cross-build toolchain.
# Usage:
#   cmake -S core -B build-ios \
#     -DCMAKE_TOOLCHAIN_FILE=core/cmake/ios.cmake \
#     -DDB_APPLE_PLATFORM=iphoneos|iphonesimulator|appletvos|appletvsimulator \
#     -DDB_BUILD_TESTS=OFF
# The output is static libraries. ios/scripts/build_core.sh invokes this file and
# combines them with libtool. DB_APPLE_PLATFORM matches Xcode PLATFORM_NAME values.

if(NOT DEFINED DB_APPLE_PLATFORM)
  set(DB_APPLE_PLATFORM "iphoneos" CACHE STRING "iphoneos|iphonesimulator|appletvos|appletvsimulator")
endif()

if(DB_APPLE_PLATFORM MATCHES "^appletv")
  set(CMAKE_SYSTEM_NAME tvOS)
  # DoorbellTV targets tvOS 15.0 and later.
  if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "")
  endif()
else()
  set(CMAKE_SYSTEM_NAME iOS)
  # The modern compatibility floor is iOS 12.
  if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "")
  endif()
endif()

# Device and simulator SDK names can be passed directly as CMAKE_OSX_SYSROOT.
set(CMAKE_OSX_SYSROOT "${DB_APPLE_PLATFORM}" CACHE STRING "")

# arm64 is the default for devices and Apple Silicon simulators. Override
# CMAKE_OSX_ARCHITECTURES with x86_64 for an Intel Mac simulator build.
if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
endif()

# Produce only static libraries so try_compile never attempts to run a target binary.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
