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

add_executable(hello_linux linux/hello.cpp)
