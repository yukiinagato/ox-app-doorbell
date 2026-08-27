cmake_minimum_required(VERSION 3.16)
project(doorbell_core C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 99)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

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
  target_compile_definitions(db_third_party PUBLIC _WIN32_WINNT=0x0601) # Win7
else()
  target_link_libraries(db_third_party PUBLIC pthread ${CMAKE_DL_LIBS})
endif()

# ---------- doorbell_core ----------
file(GLOB_RECURSE DB_CORE_SRC CONFIGURE_DEPENDS src/*.cpp)
add_library(doorbell_core STATIC ${DB_CORE_SRC})
target_include_directories(doorbell_core PUBLIC include src)
target_link_libraries(doorbell_core PUBLIC db_third_party)
if(NOT MSVC)
  target_compile_options(doorbell_core PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

# ---------- tests ----------
enable_testing()
file(GLOB DB_TEST_SRC CONFIGURE_DEPENDS tests/*.cpp)
if(DB_TEST_SRC)
  add_executable(doorbell_tests ${DB_TEST_SRC})
  target_include_directories(doorbell_tests PRIVATE third_party/doctest)
  target_link_libraries(doorbell_tests PRIVATE doorbell_core)
  add_test(NAME core COMMAND doorbell_tests)
endif()
