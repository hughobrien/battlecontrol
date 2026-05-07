cmake_minimum_required(VERSION 3.20)

project(cnc_redalert_linux
    LANGUAGES CXX
    DESCRIPTION "Linux port of Command & Conquer: Red Alert (CnC_Remastered_Collection)"
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(STATUS "Target ABI: LP64 (64-bit). DWORD/long width shim will be required for the RedAlert port.")
else()
    message(WARNING "Target ABI is 32-bit. Upstream sources assume LLP64; this is unusual on modern Linux.")
endif()

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(
        -Wall
        -Wno-unused-parameter
        -Wno-unused-variable
        -fno-strict-aliasing
    )
endif()

# ---------------------------------------------------------------------------
# TIM-5: case-folding include shim + Win32 stub headers
#
# `redalert_includes` is an INTERFACE target that any future RedAlert library
# can link to via target_link_libraries(... PRIVATE redalert_includes) to
# inherit the full include search path (shim → real source dirs → stubs).
# We don't add a RedAlert library yet (that's TIM-6+), but the include path
# is reproducible from CMake.
#
# Order of -I flags matters:
#   1. include-shim/redalert + win32lib  — case-folded relative symlinks
#   2. REDALERT/ + REDALERT/WIN32LIB     — original on-disk sources
#   3. linux/win32-stubs/                — declarations-only Win32 stubs,
#                                          last-resort so they only fire
#                                          for genuinely missing headers
# ---------------------------------------------------------------------------
set(RA_SHIM_DIR "${CMAKE_BINARY_DIR}/include-shim")
set(RA_SHIM_STAMP "${CMAKE_BINARY_DIR}/include-shim.stamp")

find_package(Python3 REQUIRED COMPONENTS Interpreter)

# Regenerate the shim whenever the generator or any source's include
# graph changes. The script is idempotent (it skips up-to-date links).
add_custom_command(
    OUTPUT "${RA_SHIM_STAMP}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_SOURCE_DIR}/scripts/generate-include-shim.py"
            --repo-root "${CMAKE_SOURCE_DIR}"
            --shim-root "${RA_SHIM_DIR}"
            --quiet
    COMMAND "${CMAKE_COMMAND}" -E touch "${RA_SHIM_STAMP}"
    DEPENDS "${CMAKE_SOURCE_DIR}/scripts/generate-include-shim.py"
    COMMENT "Generating RedAlert case-folding include shim"
    VERBATIM
)

add_custom_target(redalert_include_shim ALL
    DEPENDS "${RA_SHIM_STAMP}"
)

add_library(redalert_includes INTERFACE)
add_dependencies(redalert_includes redalert_include_shim)
target_include_directories(redalert_includes INTERFACE
    "${RA_SHIM_DIR}/redalert"
    "${RA_SHIM_DIR}/win32lib"
    "${CMAKE_SOURCE_DIR}/REDALERT"
    "${CMAKE_SOURCE_DIR}/REDALERT/WIN32LIB"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs"
)
# TIM-6: force-include the MSVC-extension shim (empty calling-convention
# macros, __int64 typedef, _lrotl) so upstream sources can stay untouched
# for cross-cutting MSVC-isms. MSVC builds are unaffected (the shim
# guards everything on `!defined(_MSC_VER)`).
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(redalert_includes INTERFACE
        "-include" "${CMAKE_SOURCE_DIR}/linux/win32-stubs/msvc-compat.h"
    )
endif()

add_executable(hello_linux linux/hello.cpp)
