# Android 用: core をそのまま取り込み、JNI グルーを doorbell 共有ライブラリへ追加する。
# 生成物は libdoorbell.so 一つ (core 静的 + C ABI + JNI)。Kotlin は System.loadLibrary("doorbell")。
cmake_minimum_required(VERSION 3.22)
project(doorbell_android C CXX)

set(DB_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(DB_WITH_PJSIP OFF CACHE BOOL "" FORCE)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core ${CMAKE_BINARY_DIR}/core)

# core の SHARED ターゲット doorbell に JNI グルーを足す (別 .so を増やさない)
target_sources(doorbell PRIVATE jni_bridge.cpp)
target_link_libraries(doorbell PRIVATE log)
