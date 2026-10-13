cmake_minimum_required(VERSION 3.20)

project(bree_cpp_terminal_frontend LANGUAGES CXX)

option(BREE_FRONTEND_BUILD_TESTS "Build deterministic fake-transport tests" ON)
set(
    BREE_CPP_SDK_DIR
    "${CMAKE_CURRENT_LIST_DIR}/../../cpp"
    CACHE PATH
    "Path to a local bree-tui C++ SDK checkout; leave empty to use find_package")

if(BREE_CPP_SDK_DIR)
    get_filename_component(BREE_CPP_SDK_DIR "${BREE_CPP_SDK_DIR}" ABSOLUTE)
    if(NOT EXISTS "${BREE_CPP_SDK_DIR}/CMakeLists.txt")
        message(FATAL_ERROR "BREE_CPP_SDK_DIR does not contain the bree C++ SDK")
    endif()
    set(BREE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
    add_subdirectory(
        "${BREE_CPP_SDK_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}/bree-sdk"
        EXCLUDE_FROM_ALL)
else()
    find_package(bree-tui-sdk 1.0 CONFIG REQUIRED)
endif()

add_library(bree_terminal_frontend_core src/frontend.cpp)
target_link_libraries(bree_terminal_frontend_core PUBLIC bree::sdk)
target_include_directories(
    bree_terminal_frontend_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_compile_features(bree_terminal_frontend_core PUBLIC cxx_std_20)

add_executable(bree-cpp-terminal-frontend src/main.cpp)
target_link_libraries(bree-cpp-terminal-frontend PRIVATE bree_terminal_frontend_core)
target_compile_features(bree-cpp-terminal-frontend PRIVATE cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(
        bree_terminal_frontend_core PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(
        bree-cpp-terminal-frontend PRIVATE -Wall -Wextra -Wpedantic -Werror)
endif()

if(BREE_FRONTEND_BUILD_TESTS)
    enable_testing()
    add_executable(bree-cpp-terminal-frontend-tests tests/frontend_test.cpp)
    target_link_libraries(
        bree-cpp-terminal-frontend-tests PRIVATE bree_terminal_frontend_core)
    target_compile_features(bree-cpp-terminal-frontend-tests PRIVATE cxx_std_20)
    if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(
            bree-cpp-terminal-frontend-tests
            PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(
        NAME bree-cpp-terminal-frontend
        COMMAND bree-cpp-terminal-frontend-tests)
endif()
