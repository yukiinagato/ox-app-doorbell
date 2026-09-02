cmake_minimum_required(VERSION 3.16)
project(doorbell_windows_abi_probe CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT DEFINED DB_CORE_BUILD_DIR)
  message(FATAL_ERROR "DB_CORE_BUILD_DIR must point at the matching MSVC core build")
endif()

add_library(doorbell_import SHARED IMPORTED GLOBAL)
set_target_properties(doorbell_import PROPERTIES
  IMPORTED_IMPLIB_RELEASE "${DB_CORE_BUILD_DIR}/Release/doorbell.lib"
  IMPORTED_LOCATION_RELEASE "${DB_CORE_BUILD_DIR}/Release/doorbell.dll")

add_executable(doorbell-abi-probe main.cpp)
target_include_directories(doorbell-abi-probe PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../core/include")
target_link_libraries(doorbell-abi-probe PRIVATE doorbell_import)
if(MSVC)
  target_compile_options(doorbell-abi-probe PRIVATE /W4 /WX /Brepro)
  target_link_options(doorbell-abi-probe PRIVATE /Brepro)
endif()
add_custom_command(TARGET doorbell-abi-probe POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          "${DB_CORE_BUILD_DIR}/$<CONFIG>/doorbell.dll"
          "$<TARGET_FILE_DIR:doorbell-abi-probe>/doorbell.dll")
