# iOS 5.1/armv7 cross-build toolchain for first- and second-generation iPads.
#
# Cross-compile Core as C++17 using the locally built LLVM 17.0.6 libc++ for
# armv7/iOS 5.1 and the licensed local iOS 7.1 SDK sysroot.
#
# Usage:
#   cmake -S core -B build-ios5 -DCMAKE_TOOLCHAIN_FILE=core/cmake/ios5-armv7.cmake
#   cmake --build build-ios5 --target doorbell_core
# ios-compat/scripts/build_core_ios5.sh combines the static outputs into
# libdoorbell_all.a and verifies the armv7 architecture.
#
# PJSIP and tests stay disabled because clang rejects thread_local for this
# armv7/iOS 5.1 target, and target binaries cannot run on the build host.

# Resolve absolute paths from core/cmake to the repository root.
get_filename_component(_DB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_DB_SDK "${_DB_ROOT}/tools/sdk/iPhoneOS7.1.sdk")
set(_DB_TC  "${_DB_ROOT}/tools/toolchain/ios5-armv7")

if(NOT EXISTS "${_DB_SDK}/SDKSettings.plist")
  message(FATAL_ERROR "iOS 7.1 SDK not found at ${_DB_SDK}; install the ignored licensed SDK locally")
endif()
if(NOT EXISTS "${_DB_TC}/include/c++/v1/version")
  message(FATAL_ERROR "iOS 5 armv7 libc++ toolchain not found at ${_DB_TC}")
endif()

# Apple cross-build configuration.
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_OSX_ARCHITECTURES "armv7" CACHE STRING "")
set(CMAKE_OSX_SYSROOT "${_DB_SDK}" CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "5.1" CACHE STRING "")
set(CMAKE_CROSSCOMPILING ON)

# Pin the explicit target because current clang versions no longer default to armv7.
set(CMAKE_C_COMPILER_TARGET   "armv7-apple-ios5.1")
set(CMAKE_CXX_COMPILER_TARGET "armv7-apple-ios5.1")

# Produce static libraries so try_compile never links an unexecutable target binary.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Replace the default libc++ headers with the armv7/iOS 5.1 compatibility headers.
set(CMAKE_CXX_FLAGS_INIT "-nostdinc++ -isystem ${_DB_TC}/include/c++/v1")

# Provide static libc++, libc++abi, libunwind, and armv7 compiler builtins for
# any target that links during configuration experiments.
execute_process(
  COMMAND xcrun clang -print-resource-dir
  OUTPUT_VARIABLE _DB_RESDIR OUTPUT_STRIP_TRAILING_WHITESPACE)
set(_DB_RT "${_DB_RESDIR}/lib/darwin/libclang_rt.ios.a")
set(CMAKE_CXX_STANDARD_LIBRARIES
  "-nostdlib++ ${_DB_TC}/lib/libc++.a ${_DB_TC}/lib/libc++abi.a ${_DB_TC}/lib/libunwind.a ${_DB_RT}"
  CACHE STRING "" FORCE)

# The legacy iPad target does not build PJSIP or host tests.
set(DB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DB_WITH_PJSIP  OFF CACHE BOOL "" FORCE)

# Restrict cross-build dependency searches to the target SDK.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BEFORE)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
