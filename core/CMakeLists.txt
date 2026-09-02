cmake_minimum_required(VERSION 3.16)
project(doorbell_core C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 99)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# Tests and the host runner require POSIX. Disable them for Windows cross-builds.
option(DB_BUILD_TESTS "Build tests and the host development runner" ON)

# ---------- PJSIP (SIP calls) ----------
# Link the implementation (sipctl.cpp) only when enabled and a prebuilt exists:
#   - Host (macOS/Linux): third_party/pjsip/host   (tools/build_pjsip_host.sh)
#   - Android:             third_party/pjsip/android/<ABI> (tools/build_pjsip_android.sh)
#   - iOS:                 third_party/pjsip/ios/<platform> (tools/build_pjsip_ios.sh,
#                          where platform is iphoneos or iphonesimulator)
# Other targets use the unregistered stub (sipctl_stub.cpp).
option(DB_WITH_PJSIP "Enable PJSIP integration and link the sipctl implementation" ON)
option(DB_REQUIRE_PJSIP "Fail configuration when the real PJSIP backend is unavailable" OFF)
set(DB_PJSIP_OK OFF)
set(PJSIP_ROOT "")
set(PJ_LIBS "")
# Product shells may keep more than one Android API/NDK build in the same
# checkout.  An explicit root wins so an API 19 APK can never accidentally
# link the historical API 21 prebuilt.  Existing callers keep the old path.
if(DB_WITH_PJSIP AND DEFINED DB_PJSIP_ROOT AND NOT "${DB_PJSIP_ROOT}" STREQUAL "")
  set(PJSIP_ROOT "${DB_PJSIP_ROOT}")
elseif(DB_WITH_PJSIP AND ANDROID)
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/android/${ANDROID_ABI})
elseif(DB_WITH_PJSIP AND CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS)$")
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/ios/${DB_APPLE_PLATFORM})
elseif(DB_WITH_PJSIP AND NOT WIN32 AND NOT CMAKE_CROSSCOMPILING)
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/host)
endif()
if(PJSIP_ROOT AND EXISTS ${PJSIP_ROOT}/include/pjsua-lib/pjsua.h)
  # Determine the library-name target triple from libpj-*.a.
  if(WIN32)
    # pjproject's MSVC output is either one libpjproject*.lib archive or a set of
    # pj*/pjsip*/pjmedia*.lib archives. Windows does not use the Unix triple name.
    file(GLOB _pj_project_libs
      "${PJSIP_ROOT}/lib/libpjproject*.lib"
      "${PJSIP_ROOT}/lib/pjproject*.lib")
    if(_pj_project_libs)
      set(PJ_LIBS ${_pj_project_libs})
    else()
      file(GLOB PJ_LIBS
        "${PJSIP_ROOT}/lib/pj*.lib"
        "${PJSIP_ROOT}/lib/pjsip*.lib"
        "${PJSIP_ROOT}/lib/pjmedia*.lib"
        "${PJSIP_ROOT}/lib/pjnath*.lib"
        "${PJSIP_ROOT}/lib/srtp*.lib"
        "${PJSIP_ROOT}/lib/resample*.lib"
        "${PJSIP_ROOT}/lib/gsmcodec*.lib"
        "${PJSIP_ROOT}/lib/speex*.lib"
        "${PJSIP_ROOT}/lib/ilbccodec*.lib"
        "${PJSIP_ROOT}/lib/g7221codec*.lib"
        "${PJSIP_ROOT}/lib/webrtc*.lib")
    endif()
    if(PJ_LIBS)
      list(REMOVE_DUPLICATES PJ_LIBS)
      set(DB_PJSIP_OK ON)
      message(STATUS "PJSIP: ${PJSIP_ROOT} (${CMAKE_GENERATOR_PLATFORM}, MSVC archives)")
    endif()
  else()
    file(GLOB _pj_core ${PJSIP_ROOT}/lib/libpj-*.a)
    if(_pj_core)
      list(GET _pj_core 0 _pj_core0)
      get_filename_component(_pj_name ${_pj_core0} NAME)
      string(REGEX REPLACE "^libpj-(.*)\\.a$" "\\1" PJ_TRIPLE ${_pj_name})
      set(DB_PJSIP_OK ON)
      message(STATUS "PJSIP: ${PJSIP_ROOT} (${PJ_TRIPLE})")
    endif()
  endif()
endif()
if(NOT DB_PJSIP_OK)
  message(STATUS "PJSIP: disabled (using the sipctl stub)")
  if(DB_REQUIRE_PJSIP)
    message(FATAL_ERROR
      "A real PJSIP backend is required. Provide DB_PJSIP_ROOT for this platform or explicitly configure a development-only stub build with DB_REQUIRE_PJSIP=OFF.")
  endif()
endif()

# ---------- third_party (separate target to contain third-party warnings) ----------
add_library(db_third_party STATIC
  third_party/sqlite/sqlite3.c
  third_party/civetweb/civetweb.c
  third_party/cjson/cJSON.c
  third_party/monocypher/monocypher.c
  third_party/monocypher/monocypher-ed25519.c
  third_party/qrcodegen/qrcodegen.c
  # quirc (ISC): QR recognition for pairing. Encoding stays with qrcodegen.
  third_party/quirc/quirc.c
  third_party/quirc/identify.c
  third_party/quirc/decode.c
  third_party/quirc/version_db.c
  # Theme background averaging decodes one uploaded image; nothing else needs a decoder.
  third_party/stb/stb_image_impl.c
)
target_include_directories(db_third_party PUBLIC
  third_party/sqlite third_party/civetweb third_party/cjson third_party/monocypher
  third_party/qrcodegen third_party/quirc third_party/stb)
target_compile_definitions(db_third_party PUBLIC
  # Assets are embedded, so civetweb does not need TLS, CGI, or filesystem serving.
  # USE_IPV6 makes the HTTP service listen on both IPv4 and IPv6 with a "+port".
  NO_SSL NO_CGI NO_CACHING USE_IPV6
  # Keep the SQLite feature surface small.
  SQLITE_OMIT_LOAD_EXTENSION SQLITE_DQS=0 SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
  SQLITE_THREADSAFE=1
)
if(WIN32)
  # Target Windows 7 SP1+, reduce windows.h, and suppress min/max macros.
  # cJSON otherwise exports symbols on Windows; keep the DLL surface limited to db_*.
  target_compile_definitions(db_third_party PUBLIC
    _WIN32_WINNT=0x0601 WIN32_LEAN_AND_MEAN NOMINMAX CJSON_HIDE_SYMBOLS)
  # ws2_32 serves civetweb and mesh; iphlpapi serves civetweb; bcrypt serves randomBytes.
  target_link_libraries(db_third_party PUBLIC ws2_32 iphlpapi bcrypt)
elseif(ANDROID)
  # bionic includes pthread and the NDK has no libpthread; log supplies __android_log_print.
  target_link_libraries(db_third_party PUBLIC log ${CMAKE_DL_LIBS})
  # Pre-API-24 32-bit bionic does not declare fseeko/ftello. Embedded Web assets
  # never exceed 2 GB, so civetweb may safely use fseek/ftell instead.
  target_compile_definitions(db_third_party PRIVATE fseeko=fseek ftello=ftell)
else()
  target_link_libraries(db_third_party PUBLIC pthread ${CMAKE_DL_LIBS})
endif()

# ---------- embedded Web UI assets (generated at build time) ----------
find_package(Python3 COMPONENTS Interpreter REQUIRED)
file(GLOB_RECURSE WEBUI_FILES CONFIGURE_DEPENDS
  ${CMAKE_CURRENT_SOURCE_DIR}/../webui/admin/* ${CMAKE_CURRENT_SOURCE_DIR}/../webui/panel/*
  ${CMAKE_CURRENT_SOURCE_DIR}/../assets/audio/*)
set(WEBUI_GEN ${CMAKE_BINARY_DIR}/gen/webui_assets.cpp)
add_custom_command(OUTPUT ${WEBUI_GEN}
  COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/../tools/embed_webui.py ${WEBUI_GEN}
  DEPENDS ${WEBUI_FILES}
          ${CMAKE_CURRENT_SOURCE_DIR}/../tools/embed_webui.py
          ${CMAKE_CURRENT_SOURCE_DIR}/../tools/gen_i18n.py
          ${CMAKE_CURRENT_SOURCE_DIR}/../i18n/strings.yaml
  COMMENT "Embedding webui assets")

# ---------- doorbell_core ----------
file(GLOB_RECURSE DB_CORE_SRC CONFIGURE_DEPENDS src/*.cpp)
if(NOT WIN32)
  # Windows-only Media Foundation camera capture and H.264 encoding.
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/media/camera_win.cpp)
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/media/encoder_win.cpp)
endif()
# Link exactly one sipctl backend: the implementation or the stub.
if(DB_PJSIP_OK)
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/sipctl/sipctl_stub.cpp)
else()
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/sipctl/sipctl.cpp)
endif()
add_library(doorbell_core STATIC ${DB_CORE_SRC} ${WEBUI_GEN})
target_include_directories(doorbell_core PUBLIC include src)
target_link_libraries(doorbell_core PUBLIC db_third_party)
# Inject the build ID only into the C API so changes rebuild one translation unit.
if(DEFINED DB_BUILD_ID_ARG)
  set_property(SOURCE src/capi/doorbell_capi.cpp APPEND
    PROPERTY COMPILE_DEFINITIONS DB_BUILD_ID="${DB_BUILD_ID_ARG}")
endif()
if(DB_PJSIP_OK)
  target_compile_definitions(doorbell_core PRIVATE DB_HAVE_PJSIP
    PJ_AUTOCONF=1 PJ_IS_BIG_ENDIAN=0 PJ_IS_LITTLE_ENDIAN=1)  # Matches libpjproject.pc Cflags.
  target_include_directories(doorbell_core PRIVATE ${PJSIP_ROOT}/include)
  # Preserve libpjproject.pc Libs/Libs.private order without requiring pkg-config.
  set(PJ_LIB_NAMES pjsua2 pjsua pjsip-ua pjsip-simple pjsip pjmedia-codec pjmedia-videodev
      pjmedia-audiodev pjmedia pjnath pjlib-util pj
      srtp resample gsmcodec speex ilbccodec g7221codec webrtc)
  if(NOT WIN32)
    set(PJ_LIBS "")
    foreach(_n ${PJ_LIB_NAMES})
      set(_p ${PJSIP_ROOT}/lib/lib${_n}-${PJ_TRIPLE}.a)
      if(EXISTS ${_p})
        list(APPEND PJ_LIBS ${_p})
      endif()
    endforeach()
  endif()
  target_link_libraries(doorbell_core PUBLIC ${PJ_LIBS})
  if(WIN32)
    target_link_libraries(doorbell_core PUBLIC winmm dsound dxguid secur32 crypt32)
  elseif(CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS)$")
    # coreaudio_dev discovers VoiceProcessingIO and its AEC at runtime. Record
    # framework requirements here and mirror them in Xcode OTHER_LDFLAGS.
    target_link_libraries(doorbell_core PUBLIC
      "-framework CoreAudio" "-framework AudioToolbox" "-framework AVFoundation"
      "-framework CFNetwork" "-framework Foundation")
  elseif(APPLE)
    target_link_libraries(doorbell_core PUBLIC
      "-framework CoreAudio" "-framework CoreServices" "-framework AudioUnit"
      "-framework AudioToolbox" "-framework Foundation" "-framework AppKit")
  elseif(ANDROID)
    # The Android audio backend is OpenSL ES; see build_pjsip_android.sh config_site.
    target_link_libraries(doorbell_core PUBLIC OpenSLES)
  endif()
endif()
if(WIN32)
  # camera_win: Media Foundation SourceReader + COM
  # encoder_win: MFTEnumEx/encoder MFT (mfplat) + ICodecAPI (strmiids) + VARIANT (oleaut32)
  target_link_libraries(doorbell_core PUBLIC mfplat mf mfreadwrite mfuuid ole32
    oleaut32 strmiids)
endif()
if(NOT MSVC)
  target_compile_options(doorbell_core PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# ---------- shared library (C ABI for platform shells) ----------
# WPF loads doorbell.dll through P/Invoke. Non-Windows hosts also build a dylib/so
# to verify the export surface. DOORBELL_DLL exports only db_* symbols.
if(NOT CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS)$")
  # Swift iOS/tvOS shells link doorbell_core statically and do not need a shared library.
  add_library(doorbell SHARED src/capi/doorbell_capi.cpp)
  target_link_libraries(doorbell PRIVATE doorbell_core)
  target_compile_definitions(doorbell PRIVATE DOORBELL_DLL)
  if(WIN32)
    set_target_properties(doorbell PROPERTIES PREFIX "")  # libdoorbell.dll -> doorbell.dll
  endif()
endif()

# ---------- host development runner ----------
if(DB_BUILD_TESTS AND NOT WIN32)
  add_executable(doorbell_host host/main.cpp)
  target_link_libraries(doorbell_host PRIVATE doorbell_core)
endif()

# ---------- tests ----------
if(DB_BUILD_TESTS)
  enable_testing()
  file(GLOB DB_TEST_SRC CONFIGURE_DEPENDS tests/*.cpp)
  if(DB_TEST_SRC)
    add_executable(doorbell_tests ${DB_TEST_SRC})
    target_include_directories(doorbell_tests PRIVATE third_party/doctest)
    target_link_libraries(doorbell_tests PRIVATE doorbell_core)
    add_test(NAME core COMMAND doorbell_tests)
  endif()
endif()
