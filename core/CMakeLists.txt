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

# ---------- third_party (警告抑制のため別ターゲット) ----------
add_library(db_third_party STATIC
  third_party/sqlite/sqlite3.c
  third_party/civetweb/civetweb.c
  third_party/cjson/cJSON.c
  third_party/monocypher/monocypher.c
  third_party/monocypher/monocypher-ed25519.c
)
target_include_directories(db_third_party PUBLIC
  third_party/sqlite third_party/civetweb third_party/cjson third_party/monocypher)
target_compile_definitions(db_third_party PUBLIC
  # civetweb: TLS/CGI/ファイルシステム配信は使わない (資産は埋め込み)
  NO_SSL NO_CGI NO_CACHING
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
add_library(doorbell_core STATIC ${DB_CORE_SRC} ${WEBUI_GEN})
target_include_directories(doorbell_core PUBLIC include src)
target_link_libraries(doorbell_core PUBLIC db_third_party)
if(NOT MSVC)
  target_compile_options(doorbell_core PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# ---------- 共有ライブラリ (平台殻用 C ABI) ----------
# WPF は P/Invoke で doorbell.dll を読む。非 Windows でも .dylib/.so としてビルド可
# (ホストでのエクスポート面検証用)。DOORBELL_DLL で db_* に dllexport が付く。
# capi は doorbell_core (静的) にも素のまま入っているが、ここで dllexport 付きの
# 定義が先に立つためアーカイブ側は引かれない。
add_library(doorbell SHARED src/capi/doorbell_capi.cpp)
target_link_libraries(doorbell PRIVATE doorbell_core)
target_compile_definitions(doorbell PRIVATE DOORBELL_DLL)
if(WIN32)
  set_target_properties(doorbell PROPERTIES PREFIX "")  # libdoorbell.dll → doorbell.dll
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
