cmake_minimum_required(VERSION 3.20)
project(bree_tui_sdk_consumer LANGUAGES CXX)

find_package(bree-tui-sdk 1.0 CONFIG REQUIRED)

add_executable(consumer main.cpp)
target_link_libraries(consumer PRIVATE bree::sdk)
target_compile_features(consumer PRIVATE cxx_std_20)
