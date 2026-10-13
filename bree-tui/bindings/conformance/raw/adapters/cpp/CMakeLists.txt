cmake_minimum_required(VERSION 3.20)
project(bree_conformance_cpp LANGUAGES CXX)

set(BREE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory("../../../../cpp" bree-sdk)
find_package(Threads REQUIRED)

add_executable(bree-conformance-cpp main.cpp)
target_compile_features(bree-conformance-cpp PRIVATE cxx_std_20)
target_link_libraries(bree-conformance-cpp PRIVATE bree::sdk Threads::Threads)
