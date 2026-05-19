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

# TIM-640: LP64 static hazard audit.  Run with:
#   cmake --build <build-dir> --target lint-lp64       # informational report (never fails)
#   python3 scripts/lint-lp64.py --errors-only         # hard gate (exit 1 on errors)
add_custom_target(lint-lp64
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_SOURCE_DIR}/scripts/lint-lp64.py"
        "--dirs" "REDALERT" "TIBERIANDAWN"
        "--no-colour"
        "--no-fail"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Running LP64 static hazard audit (scripts/lint-lp64.py)"
    VERBATIM
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

# ---------------------------------------------------------------------------
# TIM-337: Tiberian Dawn (`td`) compile target
#
# Wires TIBERIANDAWN/ into the build so the compiler can start seeing errors.
# WIN32LIB sources are excluded (we use our linux/ stubs for implementations).
# DLLInterface files are excluded (DLL entry points, not needed for standalone).
#
# Include path order:
#   1. include-shim/tiberiandawn + td-win32lib — case-folded symlinks
#   2. TIBERIANDAWN/ + TIBERIANDAWN/WIN32LIB   — on-disk headers
#   3. linux/win32-stubs/                       — Win32 stub headers
# ---------------------------------------------------------------------------
file(GLOB TD_SOURCES_UPPER "${CMAKE_SOURCE_DIR}/TIBERIANDAWN/*.CPP")
file(GLOB TD_SOURCES_LOWER "${CMAKE_SOURCE_DIR}/TIBERIANDAWN/*.cpp")
set(TD_ALL_SOURCES ${TD_SOURCES_UPPER} ${TD_SOURCES_LOWER})

# Exclude DLLInterface entry points and WIN32LIB (handled by linux/ stubs).
list(FILTER TD_ALL_SOURCES EXCLUDE REGEX ".*/DLLInterface[^/]*\\.([Cc][Pp][Pp])$")

# TIM-341: comprehensive link stubs for all WIN32LIB and DLL-host symbols.
# TIM-343: add posix_fileio.cpp so CreateFileA/CloseHandle resolve for TD.
# TIM-682: add vqa_player.cpp so Play_Movie_GlyphX plays TD intro movies.
set(TD_STUB_SOURCES
    "${CMAKE_SOURCE_DIR}/linux/td-win32-stubs.cpp"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs/kernel32-stub.cpp"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs/sdl_window.cpp"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs/posix_fileio.cpp"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs/vqa_player.cpp"
    # stop-execution-stub.cpp excluded: STARTUP.CPP defines DLL_Startup;
    # Stop_Execution is in td-win32-stubs.cpp.
)

add_executable(td ${TD_ALL_SOURCES} ${TD_STUB_SOURCES})
add_dependencies(td redalert_include_shim)

target_compile_definitions(td PRIVATE
    LINUX=1
    UNIX=1
    POSIX=1
)

target_include_directories(td PRIVATE
    "${RA_SHIM_DIR}/tiberiandawn"
    "${RA_SHIM_DIR}/td-win32lib"
    "${CMAKE_SOURCE_DIR}/TIBERIANDAWN"
    "${CMAKE_SOURCE_DIR}/TIBERIANDAWN/WIN32LIB"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs"
)

# TIM-343: Force WIN32=1 for all TD TUs so RawFileClass/HANDLE_TYPE gets a
# consistent void* layout everywhere. FUNCTION.H has the WIN32 define
# commented out, so without this flag each TU independently sees either
# int Handle (4B) or HANDLE Handle (8B) depending on include order, causing
# ODR struct-layout mismatch and SIGSEGV. Same flag approach used in RA via
# wwstd.h #define WIN32 1 (see memory note project_redalert_wwstd_predefines_win32).
target_compile_definitions(td PRIVATE WIN32=1)

# TIM-400: mirror RA's EMSCRIPTEN block — WASM build gets pthreads + SDL2 port;
# native build gets SDL2 host library.
if(EMSCRIPTEN)
    target_compile_options(td PRIVATE
        "-include" "${CMAKE_SOURCE_DIR}/linux/win32-stubs/msvc-compat.h"
        -fpermissive
        -Wno-register
        -w
        -pthread
        -sUSE_SDL=2
        -sUSE_PTHREADS=1
        -Os     # TIM-904: optimize for size at compile time.
        -sDISABLE_EXCEPTION_CATCHING=1
    )
    set_target_properties(td PROPERTIES SUFFIX ".html")
    target_link_options(td PRIVATE
        # TIM-593: match ra's -O2 link opt — keeps SDL2 audio function table entries
        # intact on all Binaryen versions (see ra block comment above).
        # TIM-904: -Oz for maximum code-size savings at link time.
        -Oz
        -sUSE_SDL=2
        -sALLOW_MEMORY_GROWTH=1
        -sUSE_PTHREADS=1
        -sPTHREAD_POOL_SIZE=4
        -sPROXY_TO_PTHREAD=1
        "-sEXPORTED_RUNTIME_METHODS=[\"FS\",\"callMain\"]"
        # TIM-858: include IDBFS so preloader.js can mount FS.filesystems.IDBFS.
        # Without this flag, IDBFS is absent from td.js and the preloader throws a
        # TypeError on FS.mount, silently aborting the Promise chain before callMain.
        -sFORCE_FILESYSTEM=1
        # TIM-904: no C++ try/catch in the codebase; strip EH support for size.
        -sDISABLE_EXCEPTION_CATCHING=1
        "--shell-file" "${CMAKE_SOURCE_DIR}/wasm/td-shell.html"
    )
    add_custom_command(TARGET td POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
            "${CMAKE_SOURCE_DIR}/wasm/preloader.js"
            "${CMAKE_BINARY_DIR}/preloader.js"
        COMMENT "Copying preloader.js to ${CMAKE_BINARY_DIR}"
    )
else()
    target_compile_options(td PRIVATE
        "-include" "${CMAKE_SOURCE_DIR}/linux/win32-stubs/msvc-compat.h"
        -fmax-errors=20
        -fpermissive   # TIM-339: allows extra qualifications + two-phase lookup as warnings
        -Wno-register
        -w             # suppress warnings (errors already suppressed by fpermissive)
    )
    # TIM-341: SDL2 required by sdl_window.cpp (MainWindow, SDL_Window_Show, ...).
    find_package(SDL2 REQUIRED)
    target_link_libraries(td PRIVATE SDL2::SDL2)
endif()

# ---------------------------------------------------------------------------
# TIM-376: ra executable — Red Alert main binary (native Linux + WASM)
#
# Source composition — cmake is the single build description:
#   REDALERT/*.CPP  + REDALERT/WIN32LIB/*.CPP  (upstream game sources)
#   linux/win32-stubs/*.cpp                     (portable platform layer)
#
# Excluded (same as flake.nix):
#   DTABLE.CPP  — large data-initialiser that takes too long at -O0
#   ITABLE.CPP  — same
#   LZWOTRAW.CPP — raw-mode LZW; replaced by portable path
#   STUB.CPP    — defines a second main(), conflicts with STARTUP.CPP
#
# Under Emscripten (EMSCRIPTEN=1):
#   SDL2 is provided by -sUSE_SDL=2 (Emscripten port, no host library needed)
#   pthreads enabled via -sUSE_PTHREADS=1 + compile-time -pthread
#   Output: ra.js + ra.wasm
#
# Invoke WASM build as:
#   emcmake cmake --preset wasm && cmake --build build-wasm --target ra
# ---------------------------------------------------------------------------
file(GLOB RA_SOURCES_UPPER "${CMAKE_SOURCE_DIR}/REDALERT/*.CPP")
file(GLOB RA_SOURCES_LOWER "${CMAKE_SOURCE_DIR}/REDALERT/*.cpp")
set(RA_ALL_SOURCES ${RA_SOURCES_UPPER} ${RA_SOURCES_LOWER})
list(FILTER RA_ALL_SOURCES EXCLUDE REGEX ".*/DTABLE\\.CPP$")
list(FILTER RA_ALL_SOURCES EXCLUDE REGEX ".*/ITABLE\\.CPP$")
list(FILTER RA_ALL_SOURCES EXCLUDE REGEX ".*/LZWOTRAW\\.CPP$")
list(FILTER RA_ALL_SOURCES EXCLUDE REGEX ".*/STUB\\.CPP$")

file(GLOB RA_WIN32LIB_SOURCES_UPPER "${CMAKE_SOURCE_DIR}/REDALERT/WIN32LIB/*.CPP")
file(GLOB RA_WIN32LIB_SOURCES_LOWER "${CMAKE_SOURCE_DIR}/REDALERT/WIN32LIB/*.cpp")
set(RA_WIN32LIB_SOURCES ${RA_WIN32LIB_SOURCES_UPPER} ${RA_WIN32LIB_SOURCES_LOWER})

file(GLOB RA_STUB_SOURCES "${CMAKE_SOURCE_DIR}/linux/win32-stubs/*.cpp")

add_executable(ra
    ${RA_ALL_SOURCES}
    ${RA_WIN32LIB_SOURCES}
    ${RA_STUB_SOURCES}
)
add_dependencies(ra redalert_include_shim)

target_compile_definitions(ra PRIVATE
    LINUX=1
    UNIX=1
    POSIX=1
)

target_include_directories(ra PRIVATE
    "${RA_SHIM_DIR}/redalert"
    "${RA_SHIM_DIR}/win32lib"
    "${CMAKE_SOURCE_DIR}/REDALERT"
    "${CMAKE_SOURCE_DIR}/REDALERT/WIN32LIB"
    "${CMAKE_SOURCE_DIR}/linux/win32-stubs"
)

if(EMSCRIPTEN)
    # msvc-compat.h already contains the WASM-specific compat block
    # (register pragma + random rename) for Emscripten. See TIM-376 notes
    # inside that file. A second -include was avoided because CMake deduplicates
    # adjacent -include flags, collapsing them into one flag with two paths.
    #
    # TIM-377: -sUSE_SDL=2 and -sUSE_PTHREADS=1 must also be compile-time flags
    # so that Emscripten resolves the SDL2 port headers (<SDL2/SDL.h>) and the
    # pthread headers during compilation, not only at link time.
    target_compile_options(ra PRIVATE
        "-include" "${CMAKE_SOURCE_DIR}/linux/win32-stubs/msvc-compat.h"
        -fpermissive
        -Wno-register
        -w
        -pthread
        -sUSE_SDL=2
        -sUSE_PTHREADS=1
        -Os     # TIM-904: optimize for size at compile time (was -O3 for speed per TIM-489).
        -sDISABLE_EXCEPTION_CATCHING=1
    )
    # TIM-381: Output ra.html so --shell-file is honoured (Emscripten only
    # processes the shell template when the output suffix is .html).
    set_target_properties(ra PROPERTIES SUFFIX ".html")
    target_link_options(ra PRIVATE
        # TIM-593: -O2 instead of -O3 at link time.  Binaryen's -O3 whole-program
        # optimisation aggressively prunes function-table entries that look unused
        # from WASM's perspective.  SDL2's HandleAudioProcess is only ever called
        # from JavaScript via dynCall('vp', ptr, [dev]), not via WASM call_indirect,
        # so Binaryen at -O3 removes it from the table → ptr==0 → null-function trap.
        # Binaryen 129 (Nix) happens not to prune it at -O3; newer emsdk Binaryen does.
        # -O2 keeps the table entry intact on all Binaryen versions.
        # TIM-904: -Oz for maximum code-size savings at link time.
        # Still safe with EMULATE_FUNCTION_POINTER_CASTS protecting the fn table.
        -Oz
        -sUSE_SDL=2
        -sALLOW_MEMORY_GROWTH=1
        -sUSE_PTHREADS=1
        -sPTHREAD_POOL_SIZE=4
        # TIM-381: RA has a blocking main() game loop.  PROXY_TO_PTHREAD moves
        # it into a Web Worker so it can block without stalling the browser UI thread.
        -sPROXY_TO_PTHREAD=1
        "-sEXPORTED_RUNTIME_METHODS=[\"FS\",\"callMain\"]"
        # TIM-858: SDL2's HandleAudioProcess is called from JavaScript via
        # dynCall('vp', ptr, [dev]) — Binaryen at -O2 can still prune its
        # function-table entry on newer emsdk versions (~50% intermittency).
        # EMULATE_FUNCTION_POINTER_CASTS prevents all table pruning by routing
        # indirect calls through a JS dispatcher that maps indices to real
        # function references, eliminating the null-function trap.
        -sEMULATE_FUNCTION_POINTER_CASTS=1
        # TIM-399: include IDBFS so preloader.js can mount FS.filesystems.IDBFS.
        # Without this flag, IDBFS is absent from ra.js and the preloader throws a
        # TypeError on FS.mount, silently aborting the Promise chain before callMain.
        -sFORCE_FILESYSTEM=1
        # TIM-904: no C++ try/catch in the codebase; strip EH support for size.
        -sDISABLE_EXCEPTION_CATCHING=1
        "--shell-file" "${CMAKE_SOURCE_DIR}/wasm/shell.html"
    )
    # TIM-378: copy preloader.js alongside ra.html so <script src="preloader.js"> resolves.
    add_custom_command(TARGET ra POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
            "${CMAKE_SOURCE_DIR}/wasm/preloader.js"
            "${CMAKE_BINARY_DIR}/preloader.js"
        COMMENT "Copying preloader.js to ${CMAKE_BINARY_DIR}"
    )
else()
    target_compile_options(ra PRIVATE
        "-include" "${CMAKE_SOURCE_DIR}/linux/win32-stubs/msvc-compat.h"
        -fmax-errors=20
        -fpermissive
        -Wno-register
        -w
    )
    target_link_libraries(ra PRIVATE SDL2::SDL2)
endif()

# TIM-369: installer experience port (native only — no installer for WASM)
if(NOT EMSCRIPTEN)
    add_subdirectory(installer)
endif()
