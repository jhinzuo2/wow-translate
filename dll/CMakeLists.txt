cmake_minimum_required(VERSION 3.20)
project(WoWTranslate VERSION 0.1.0)

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Set output directory
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

# Create the WoWTranslate DLL
add_library(WoWTranslate SHARED
    src/dllmain.cpp
    src/lua_interface.cpp
    src/translator_core.cpp
    src/curl_bridge.cpp
    src/logging.cpp
    src/utils.cpp
    src/WoWTranslate.def
)

# Include directories
target_include_directories(WoWTranslate PRIVATE
    include
    third_party
)

# --- libcurl (static, OpenSSL backend) ---------------------------------------
# Required so TLS goes through OpenSSL rather than Windows' Schannel: Schannel's
# WOW64 build (this DLL is x86, targeting the 32-bit WoW client) produces a
# different TLS ClientHello fingerprint than native x64 Schannel, which is the
# likely reason WinHTTP/WinINet requests to Google were 429'd from this process
# specifically. See dll/include/curl_bridge.h for the full writeup.
#
# Build via vcpkg BEFORE running cmake, matching this project's x86 target:
#   vcpkg install curl[openssl]:x86-windows-static
# then configure with vcpkg's toolchain file, e.g.:
#   cmake .. -G "Visual Studio 17 2022" -A Win32 ^
#     -DCMAKE_TOOLCHAIN_FILE=C:/vcpkg/scripts/buildsystems/vcpkg.cmake ^
#     -DVCPKG_TARGET_TRIPLET=x86-windows-static
#
# find_package will fail loudly with a clear message if this wasn't done -
# this project intentionally does NOT fall back to a dynamic/system curl, since
# a system libcurl.dll may itself be built against Schannel, silently defeating
# the whole point of this bridge.
find_package(CURL REQUIRED)
if(NOT CURL_FOUND)
    message(FATAL_ERROR
        "libcurl not found. Install via vcpkg first:\n"
        "  vcpkg install curl[openssl]:x86-windows-static\n"
        "then re-run cmake with -DCMAKE_TOOLCHAIN_FILE pointing at vcpkg.cmake "
        "and -DVCPKG_TARGET_TRIPLET=x86-windows-static")
endif()

# Required for a statically-linked libcurl on Windows/MSVC, or the compiler
# assumes __declspec(dllimport) for curl's symbols and linking fails.
add_compile_definitions(CURL_STATICLIB)

# MinHook library setup - Force 32-bit for WoW compatibility
set(MINHOOK_LIB "${CMAKE_CURRENT_SOURCE_DIR}/third_party/MinHook.x86.lib")

# Link libraries - winhttp (custom-endpoint provider) and libcurl+OpenSSL
# (Google Free provider, replacing wininet - see curl_bridge.h). crypt32/bcrypt
# are needed transitively by OpenSSL's cert store access on Windows even in a
# static build; ws2_32 is curl's socket layer.
target_link_libraries(WoWTranslate PRIVATE
    kernel32
    user32
    shell32
    winhttp
    CURL::libcurl
    ws2_32
    crypt32
    bcrypt
)

# Add MinHook if available
if(EXISTS ${MINHOOK_LIB})
    target_link_libraries(WoWTranslate PRIVATE ${MINHOOK_LIB})
    message(STATUS "Using MinHook library: ${MINHOOK_LIB}")
    add_compile_definitions(MINHOOK_AVAILABLE)
else()
    message(WARNING "MinHook library not found: ${MINHOOK_LIB}")
    message(WARNING "Download from: https://github.com/TsudaKageyu/minhook/releases")
endif()

# Compiler-specific settings
if(MSVC)
    # Set static runtime library for release builds
    set_property(TARGET WoWTranslate PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    # Additional MSVC settings
    target_compile_options(WoWTranslate PRIVATE
        /W4
        /permissive-
    )

    # Enable larger object files for complex translation logic
    target_compile_options(WoWTranslate PRIVATE /bigobj)
endif()

# Debug configurations
set_target_properties(WoWTranslate PROPERTIES
    DEBUG_POSTFIX "_d"
)

# Install rules
install(TARGETS WoWTranslate
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION lib
)
