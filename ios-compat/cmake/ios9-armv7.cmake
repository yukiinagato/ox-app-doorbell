# iOS 9.0 armv7 Core toolchain for the Objective-C compatibility shell.
# The licensed iPhoneOS 9.x SDK is supplied outside the repository. Current
# C++17 headers/runtime are statically linked because the historical compiler
# cannot compile the current Core, while PJSIP and the app use the commissioned
# Xcode 7 device toolchain.

get_filename_component(_DB_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(_DB_SDK "$ENV{DB_IOS9_SDK_ROOT}")
set(_DB_TC "${_DB_ROOT}/tools/toolchain/ios5-armv7")
set(_DB_CORE_CLANG "$ENV{DB_IOS9_CORE_CLANG}")
set(_DB_CORE_CLANGXX "$ENV{DB_IOS9_CORE_CLANGXX}")

if(NOT EXISTS "${_DB_SDK}/SDKSettings.plist")
  message(FATAL_ERROR "DB_IOS9_SDK_ROOT is not a commissioned iPhoneOS 9.x SDK")
endif()
if(NOT EXISTS "${_DB_TC}/include/c++/v1/version")
  message(FATAL_ERROR "The verified armv7 static libc++ toolchain is missing")
endif()
if(NOT EXISTS "${_DB_CORE_CLANG}" OR NOT EXISTS "${_DB_CORE_CLANGXX}")
  message(FATAL_ERROR "DB_IOS9_CORE_CLANG and DB_IOS9_CORE_CLANGXX are required")
endif()

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER "${_DB_CORE_CLANG}")
set(CMAKE_CXX_COMPILER "${_DB_CORE_CLANGXX}")
set(CMAKE_OSX_ARCHITECTURES "armv7" CACHE STRING "" FORCE)
set(CMAKE_OSX_SYSROOT "${_DB_SDK}" CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "9.0" CACHE STRING "" FORCE)
set(CMAKE_C_COMPILER_TARGET "armv7-apple-ios9.0")
set(CMAKE_CXX_COMPILER_TARGET "armv7-apple-ios9.0")
set(CMAKE_CROSSCOMPILING ON)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(CMAKE_CXX_FLAGS_INIT "-nostdinc++ -isystem ${_DB_TC}/include/c++/v1")
set(DB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DB_WITH_PJSIP ON CACHE BOOL "" FORCE)
set(DB_REQUIRE_PJSIP ON CACHE BOOL "" FORCE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
