cmake_minimum_required(VERSION 3.20)

project(bree_resource_conformance_cpp LANGUAGES CXX)

set(BREE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${CMAKE_CURRENT_LIST_DIR}/../../../cpp"
    "${CMAKE_CURRENT_BINARY_DIR}/bree-sdk"
)

add_executable(bree-resource-conformance-cpp main.cpp)
target_link_libraries(bree-resource-conformance-cpp PRIVATE bree::sdk)
target_compile_features(bree-resource-conformance-cpp PRIVATE cxx_std_20)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(
        bree-resource-conformance-cpp
        PRIVATE
            -Wall
            -Wextra
            -Wpedantic
    )
endif()
