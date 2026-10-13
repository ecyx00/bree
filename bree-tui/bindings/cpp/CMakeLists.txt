cmake_minimum_required(VERSION 3.20)

project(bree_tui_sdk VERSION 1.0.0 LANGUAGES CXX)

include(CMakePackageConfigHelpers)
include(GNUInstallDirs)

option(BREE_BUILD_TESTS "Build the bree-tui C++ SDK tests" ${PROJECT_IS_TOP_LEVEL})

find_package(Threads REQUIRED)

add_library(bree_tui_sdk
    src/base64.cpp
    src/json.cpp
    src/resource.cpp
    src/resource_models.cpp
    src/raw/attachment.cpp
    src/raw/client_core.cpp
    src/raw/generated/protocol.cpp
    src/unix_transport.cpp
)
add_library(bree::sdk ALIAS bree_tui_sdk)

target_compile_features(bree_tui_sdk PUBLIC cxx_std_20)
target_link_libraries(bree_tui_sdk PUBLIC Threads::Threads)
target_include_directories(bree_tui_sdk
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)
set_target_properties(bree_tui_sdk PROPERTIES
    CXX_EXTENSIONS OFF
    EXPORT_NAME sdk
    POSITION_INDEPENDENT_CODE ON
    VERSION ${PROJECT_VERSION}
    SOVERSION ${PROJECT_VERSION_MAJOR}
)

if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
    target_compile_options(bree_tui_sdk PRIVATE -Wall -Wextra -Wpedantic -Wconversion)
endif()

install(TARGETS bree_tui_sdk
    EXPORT bree-tui-sdk-targets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
    INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(EXPORT bree-tui-sdk-targets
    FILE bree-tui-sdk-targets.cmake
    NAMESPACE bree::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/bree-tui-sdk
)

configure_package_config_file(
    cmake/bree-tui-sdk-config.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/bree-tui-sdk-config.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/bree-tui-sdk
)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/bree-tui-sdk-config-version.cmake
    VERSION ${PROJECT_VERSION}
    COMPATIBILITY SameMajorVersion
)
install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/bree-tui-sdk-config.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/bree-tui-sdk-config-version.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/bree-tui-sdk
)

if(BREE_BUILD_TESTS)
    enable_testing()
    target_compile_definitions(bree_tui_sdk PRIVATE BREE_CPP_TESTING=1)
    add_executable(bree_cpp_tests
        tests/test_main.cpp
        tests/test_attachment.cpp
        tests/test_base64.cpp
        tests/test_client.cpp
        tests/test_generated.cpp
        tests/test_json.cpp
        tests/test_macro_collision.cpp
        tests/test_resource.cpp
        tests/test_unix_transport.cpp
    )
    target_link_libraries(bree_cpp_tests PRIVATE bree::sdk Threads::Threads)
    target_compile_features(bree_cpp_tests PRIVATE cxx_std_20)
    target_compile_definitions(bree_cpp_tests PRIVATE BREE_CPP_TESTING=1)
    target_include_directories(bree_cpp_tests PRIVATE src)
    if(CMAKE_CXX_COMPILER_ID MATCHES "AppleClang|Clang|GNU")
        target_compile_options(bree_cpp_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    endif()
    add_test(NAME bree-cpp-unit COMMAND bree_cpp_tests)

    add_test(
        NAME bree-cpp-package-consumer
        COMMAND ${CMAKE_COMMAND}
            -DSDK_BINARY_DIR=${CMAKE_CURRENT_BINARY_DIR}
            -DSDK_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
            -DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/package-consumer
            -DCONFIGURATION=$<CONFIG>
            -P ${CMAKE_CURRENT_SOURCE_DIR}/tests/package_consumer.cmake
    )
endif()
