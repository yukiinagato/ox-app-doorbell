# Embed Core and the JNI bridge in the single libdoorbell.so product library.
cmake_minimum_required(VERSION 3.22)
project(doorbell_android C CXX)

set(DB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
# Product APKs require SIP audio. Fail fast instead of silently building a stub whose
# monitor and answer controls appear functional but can never carry audio.
set(DB_ANDROID_PJSIP_TIER "api21" CACHE STRING "api19 or api21 PJSIP artifact tier")
if(NOT DB_ANDROID_PJSIP_TIER MATCHES "^api(19|21)$")
  message(FATAL_ERROR "Invalid DB_ANDROID_PJSIP_TIER=${DB_ANDROID_PJSIP_TIER}")
endif()
# Debug-only emulator lane (Gradle -PdoorbellLegacyAbi): link the SIP stub because no PJSIP
# artifact exists for this tier and ABI. Never valid outside a Debug build.
option(DB_ANDROID_SIP_STUB "Link the SIP stub for a debug-only visual build" OFF)
if(DB_ANDROID_SIP_STUB)
  if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug")
    message(FATAL_ERROR "DB_ANDROID_SIP_STUB is allowed only in Debug builds")
  endif()
  set(DB_WITH_PJSIP OFF CACHE BOOL "" FORCE)
  set(DB_REQUIRE_PJSIP OFF CACHE BOOL "" FORCE)
else()
  set(PJSIP_ANDROID_ROOT
      "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core/third_party/pjsip/android/${DB_ANDROID_PJSIP_TIER}/${ANDROID_ABI}")
  file(GLOB PJSIP_ANDROID_CORE_LIB "${PJSIP_ANDROID_ROOT}/lib/libpj-*.a")
  if(NOT EXISTS "${PJSIP_ANDROID_ROOT}/include/pjsua-lib/pjsua.h" OR
     NOT PJSIP_ANDROID_CORE_LIB)
    message(FATAL_ERROR
      "Android PJSIP (${ANDROID_ABI}) is incomplete; run tools/build_pjsip_android.sh first")
  endif()
  set(PJSIP_METADATA "${PJSIP_ANDROID_ROOT}/doorbell-build.properties")
  if(NOT EXISTS "${PJSIP_METADATA}")
    message(FATAL_ERROR "Android PJSIP metadata missing: ${PJSIP_METADATA}")
  endif()
  file(READ "${PJSIP_METADATA}" PJSIP_BUILD_PROPERTIES)
  if(DB_ANDROID_PJSIP_TIER STREQUAL "api19")
    set(PJSIP_EXPECTED_PLATFORM "android-19")
    set(PJSIP_EXPECTED_NDK "25.")
  else()
    set(PJSIP_EXPECTED_PLATFORM "android-21")
    set(PJSIP_EXPECTED_NDK "27.")
  endif()
  foreach(PJSIP_EXPECTED_LINE
      "abi=${ANDROID_ABI}"
      "app_platform=${PJSIP_EXPECTED_PLATFORM}"
      "ndk_revision=${PJSIP_EXPECTED_NDK}")
    string(FIND "${PJSIP_BUILD_PROPERTIES}" "${PJSIP_EXPECTED_LINE}" PJSIP_LINE_AT)
    if(PJSIP_LINE_AT EQUAL -1)
      message(FATAL_ERROR
        "PJSIP metadata mismatch (${PJSIP_EXPECTED_LINE}) in ${PJSIP_METADATA}")
    endif()
  endforeach()
  set(DB_PJSIP_ROOT "${PJSIP_ANDROID_ROOT}" CACHE PATH "" FORCE)
  set(DB_WITH_PJSIP ON CACHE BOOL "" FORCE)
  set(DB_REQUIRE_PJSIP ON CACHE BOOL "" FORCE)
endif()

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core ${CMAKE_BINARY_DIR}/core)

# Add JNI to the existing Core shared-library target.
target_sources(doorbell PRIVATE jni_bridge.cpp)
if(DB_ANDROID_SIP_STUB)
  target_compile_definitions(doorbell PRIVATE DB_ANDROID_SIP_STUB=1)
else()
  target_compile_definitions(doorbell PRIVATE
    DB_ANDROID_REAL_PJSIP=1
    DB_ANDROID_PJSIP_TIER_NAME="${DB_ANDROID_PJSIP_TIER}")
endif()
target_link_libraries(doorbell PRIVATE log)
