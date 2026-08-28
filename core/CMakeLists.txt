cmake_minimum_required(VERSION 3.16)
project(doorbell_core C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 99)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

# テスト/ホストランナーは POSIX 前提 — Windows クロス時は -DDB_BUILD_TESTS=OFF で外す
option(DB_BUILD_TESTS "テストとホスト開発ランナーをビルドする" ON)

# ---------- PJSIP (SIP 通話) ----------
# ON かつプリビルドが存在する時だけ実装 (sipctl.cpp) をリンクする:
#   - ホスト (macOS/Linux): third_party/pjsip/host   (tools/build_pjsip_host.sh)
#   - Android:             third_party/pjsip/android/<ABI> (tools/build_pjsip_android.sh)
#   - iOS:                 third_party/pjsip/ios/<platform> (tools/build_pjsip_ios.sh —
#                          platform は iphoneos / iphonesimulator)
# それ以外 (mingw クロス・tvOS・プリビルド無し) は常に未登録のスタブ (sipctl_stub.cpp)。
option(DB_WITH_PJSIP "PJSIP 統合 (sipctl 実装をリンクする)" ON)
set(DB_PJSIP_OK OFF)
set(PJSIP_ROOT "")
if(DB_WITH_PJSIP AND ANDROID)
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/android/${ANDROID_ABI})
elseif(DB_WITH_PJSIP AND CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/ios/${DB_APPLE_PLATFORM})
elseif(DB_WITH_PJSIP AND NOT WIN32 AND NOT CMAKE_CROSSCOMPILING)
  set(PJSIP_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/third_party/pjsip/host)
endif()
if(PJSIP_ROOT AND EXISTS ${PJSIP_ROOT}/include/pjsua-lib/pjsua.h)
  # ライブラリ名の三つ組接尾辞 (例 arm-apple-darwin25.5.0 / aarch64-unknown-linux-android)
  # を libpj-*.a から特定
  file(GLOB _pj_core ${PJSIP_ROOT}/lib/libpj-*.a)
  if(_pj_core)
    list(GET _pj_core 0 _pj_core0)
    get_filename_component(_pj_name ${_pj_core0} NAME)
    string(REGEX REPLACE "^libpj-(.*)\\.a$" "\\1" PJ_TRIPLE ${_pj_name})
    set(DB_PJSIP_OK ON)
    message(STATUS "PJSIP: ${PJSIP_ROOT} (${PJ_TRIPLE})")
  endif()
endif()
if(NOT DB_PJSIP_OK)
  message(STATUS "PJSIP: 無効 (sipctl はスタブ)")
endif()

# ---------- third_party (警告抑制のため別ターゲット) ----------
add_library(db_third_party STATIC
  third_party/sqlite/sqlite3.c
  third_party/civetweb/civetweb.c
  third_party/cjson/cJSON.c
  third_party/monocypher/monocypher.c
  third_party/monocypher/monocypher-ed25519.c
  third_party/qrcodegen/qrcodegen.c
)
target_include_directories(db_third_party PUBLIC
  third_party/sqlite third_party/civetweb third_party/cjson third_party/monocypher
  third_party/qrcodegen third_party/stb)
target_compile_definitions(db_third_party PUBLIC
  # civetweb: TLS/CGI/ファイルシステム配信は使わない (資産は埋め込み)。
  # USE_IPV6: HTTP 管理服务を IPv4/IPv6 双栈で待受 ("+port" で両対応・IPV6_V6ONLY 無し)
  NO_SSL NO_CGI NO_CACHING USE_IPV6
  # sqlite 縮小
  SQLITE_OMIT_LOAD_EXTENSION SQLITE_DQS=0 SQLITE_DEFAULT_WAL_SYNCHRONOUS=1
  SQLITE_THREADSAFE=1
)
if(WIN32)
  # Win7 SP1+ / windows.h 縮小 / min-max マクロ抑止 (公開: doorbell_core 以下にも効かせる)
  # CJSON_HIDE_SYMBOLS: cJSON は Windows では既定で dllexport する — DLL の外面は db_* のみに保つ
  target_compile_definitions(db_third_party PUBLIC
    _WIN32_WINNT=0x0601 WIN32_LEAN_AND_MEAN NOMINMAX CJSON_HIDE_SYMBOLS)
  # ws2_32: civetweb とメッシュ / iphlpapi: civetweb / bcrypt: randomBytes
  target_link_libraries(db_third_party PUBLIC ws2_32 iphlpapi bcrypt)
elseif(ANDROID)
  # bionic は pthread 内蔵で NDK に libpthread は存在しない。log は __android_log_print 用。
  target_link_libraries(db_third_party PUBLIC log ${CMAKE_DL_LIBS})
  # 32bit bionic は API 24 未満で fseeko/ftello が未宣言 (minSdk 21)。webui 資産は埋め込みで
  # 2GB 超のファイル配信は無いため fseek/ftell で代用する (civetweb 用)。
  target_compile_definitions(db_third_party PRIVATE fseeko=fseek ftello=ftell)
else()
  target_link_libraries(db_third_party PUBLIC pthread ${CMAKE_DL_LIBS})
endif()

# ---------- webui 埋め込み資産 (ビルド時生成) ----------
find_package(Python3 COMPONENTS Interpreter REQUIRED)
file(GLOB_RECURSE WEBUI_FILES CONFIGURE_DEPENDS
  ${CMAKE_CURRENT_SOURCE_DIR}/../webui/admin/* ${CMAKE_CURRENT_SOURCE_DIR}/../webui/panel/*)
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
  # Windows 専用: Media Foundation カメラ採集 + H.264 エンコード
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/media/camera_win.cpp)
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/media/encoder_win.cpp)
endif()
# sipctl: 実装かスタブのどちらか一方だけをリンク
if(DB_PJSIP_OK)
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/sipctl/sipctl_stub.cpp)
else()
  list(REMOVE_ITEM DB_CORE_SRC ${CMAKE_CURRENT_SOURCE_DIR}/src/sipctl/sipctl.cpp)
endif()
add_library(doorbell_core STATIC ${DB_CORE_SRC} ${WEBUI_GEN})
target_include_directories(doorbell_core PUBLIC include src)
target_link_libraries(doorbell_core PUBLIC db_third_party)
# ビルドID を capi にだけ注入 (変更時は doorbell_capi.cpp のみ再コンパイル)。
if(DEFINED DB_BUILD_ID_ARG)
  set_property(SOURCE src/capi/doorbell_capi.cpp APPEND
    PROPERTY COMPILE_DEFINITIONS DB_BUILD_ID="${DB_BUILD_ID_ARG}")
endif()
if(DB_PJSIP_OK)
  target_compile_definitions(doorbell_core PRIVATE DB_HAVE_PJSIP
    PJ_AUTOCONF=1 PJ_IS_BIG_ENDIAN=0 PJ_IS_LITTLE_ENDIAN=1)  # libpjproject.pc の Cflags と同じ
  target_include_directories(doorbell_core PRIVATE ${PJSIP_ROOT}/include)
  # libpjproject.pc の Libs / Libs.private と同順 (pkg-config 非依存で確実に)
  set(PJ_LIB_NAMES pjsua2 pjsua pjsip-ua pjsip-simple pjsip pjmedia-codec pjmedia-videodev
      pjmedia-audiodev pjmedia pjnath pjlib-util pj
      srtp resample gsmcodec speex ilbccodec g7221codec webrtc)
  set(PJ_LIBS "")
  foreach(_n ${PJ_LIB_NAMES})
    set(_p ${PJSIP_ROOT}/lib/lib${_n}-${PJ_TRIPLE}.a)
    if(EXISTS ${_p})
      list(APPEND PJ_LIBS ${_p})
    endif()
  endforeach()
  target_link_libraries(doorbell_core PUBLIC ${PJ_LIBS})
  if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # 音声バックエンドは CoreAudio (AudioUnit)。VoiceProcessingIO (AEC 内蔵) は
    # coreaudio_dev が実行時に検出して使う。静的 lib なのでここは使用要求の記録 —
    # 実リンクは Xcode 側 (OTHER_LDFLAGS) でも同じ枠組を張る。
    target_link_libraries(doorbell_core PUBLIC
      "-framework CoreAudio" "-framework AudioToolbox" "-framework AVFoundation"
      "-framework CFNetwork" "-framework Foundation")
  elseif(APPLE)
    target_link_libraries(doorbell_core PUBLIC
      "-framework CoreAudio" "-framework CoreServices" "-framework AudioUnit"
      "-framework AudioToolbox" "-framework Foundation" "-framework AppKit")
  elseif(ANDROID)
    # 音声バックエンドは OpenSL ES (tools/build_pjsip_android.sh の config_site 参照)
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

# ---------- 共有ライブラリ (平台殻用 C ABI) ----------
# WPF は P/Invoke で doorbell.dll を読む。非 Windows でも .dylib/.so としてビルド可
# (ホストでのエクスポート面検証用)。DOORBELL_DLL で db_* に dllexport が付く。
# capi は doorbell_core (静的) にも素のまま入っているが、ここで dllexport 付きの
# 定義が先に立つためアーカイブ側は引かれない。
if(NOT CMAKE_SYSTEM_NAME MATCHES "^(iOS|tvOS)$")
  # iOS/tvOS の殻 (Swift) は静的 doorbell_core を直リンクする — 共有 lib は作らない
  add_library(doorbell SHARED src/capi/doorbell_capi.cpp)
  target_link_libraries(doorbell PRIVATE doorbell_core)
  target_compile_definitions(doorbell PRIVATE DOORBELL_DLL)
  if(WIN32)
    set_target_properties(doorbell PROPERTIES PREFIX "")  # libdoorbell.dll → doorbell.dll
  endif()
endif()

# ---------- ホスト開発ランナー ----------
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
