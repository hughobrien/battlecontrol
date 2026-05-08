#!/usr/bin/env bash
# TIM-149 pass-45B: file-IO substrate bodies + windows.h kernel32 rewire.
#
# Baseline: pass-45A tip (commit 202bbf2) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-45A ===
#
# (1) NEW linux/win32-stubs/posix_fileio.cpp:
#       * Real POSIX-backed bodies (open/read/write/lseek/fstat/close)
#         for the six RA_PosixFile_* entry points declared in
#         posix_fileio.h.
#       * Win32 SDK names CreateFileA / CloseHandle / ReadFile /
#         WriteFile / SetFilePointer / GetFileSize defined as thin
#         forwarders to the substrate -- these are the symbols that
#         engine call sites bind to via windows.h.
#       * HANDLE encoding: heap-allocated PosixFileDesc { int fd; }
#         pointer cast to HANDLE. INVALID_HANDLE_VALUE sentinel
#         preserved.
#       * !_MSC_VER guarded; MSVC builds are byte-identical.
#       * NOT in REDALERT/*.cpp glob; lives in linux/win32-stubs/. The
#         compile-floor measurement does NOT pick it up automatically
#         (intentional: the floor measures upstream-engine TUs, not the
#         SDL/POSIX substrate). The substrate .cpp will be added to the
#         link source set by the link-side workstream (TIM-144) and the
#         CMakeLists.txt that builds redalert.elf.
#
# (2) MODIFIED linux/win32-stubs/windows.h:
#       * Replaced inert variadic-template stubs for CreateFile /
#         CreateFileA / CloseHandle (lines 993-995) with concrete
#         `extern "C"` declarations bound to the substrate.
#       * Replaced inert ReadFile variadic-template stub (line 1081) with
#         concrete `extern "C"` declaration.
#       * Added new declarations for WriteFile / SetFilePointer /
#         GetFileSize (previously not shimmed -- their call sites were
#         all in `#ifdef WIN32` branches of TUs that do NOT transit
#         wwlib32.h, so the floor never parsed them).
#       * Added FILE_BEGIN / FILE_CURRENT / FILE_END /
#         INVALID_SET_FILE_POINTER / INVALID_FILE_SIZE constants.
#       * Forward-declared SECURITY_ATTRIBUTES so CreateFileA's
#         signature can mention LPSECURITY_ATTRIBUTES before the full
#         struct definition further down.
#       * Kept `#define CreateFile CreateFileA` as the canonical SDK
#         macro alias (engine never calls CreateFileW).
#       * GlobalAlloc / GlobalLock / GlobalUnlock variadic-template
#         stubs UNCHANGED -- BMP8 DIB allocation is not on the runtime
#         hot path; future BMP8-specific pass when needed.
#
# (3) Engine TU call sites bound to the new declarations:
#       * BMP8.CPP:52      ::CreateFile (parsed: BMP8.CPP transits
#                          msvc-compat.h -> windows.h, no wwlib32 needed)
#       * BMP8.CPP:65/68/  ::ReadFile (4 sites, same story)
#         90/116
#       * CONQUER.CPP:4319 CreateFile (parsed via FUNCTION.H ->
#                          wwlib32.h -> #define WIN32 1)
#       * CONQUER.CPP:4323 CloseHandle (same)
#
#     Call sites NOT parsed in the floor (in #ifdef WIN32 branches of
#     TUs that do not transit wwlib32.h): RAWFILE.CPP (CreateFile x4,
#     WriteFile, SetFilePointer, GetFileSize), WINSTUB.CPP
#     (everything #if (0)-gated), WOL_LOGN.CPP / WOLAPIOB.CPP
#     (WOLAPI_INTEGRATION not defined).
#
# === Why this is the right next step ===
#
# Per the runtime-path-survey doc on TIM-149 (and the CEO greenlight on
# pass-45A), file IO is the foundation everything else stands on. Pass-45A
# locked the public ABI; pass-45B lights it up. After this pass:
#   * STARTUP.CPP::main can open REDALERT.INI (RawFileClass::Open at
#     line 461 will see a real fd, not INVALID_HANDLE_VALUE).
#   * Init_Bootstrap_Mixfiles can load REDALERT.MIX / LOCAL.MIX /
#     LORES.MIX. The hard-asserts on the cache step (INIT.CPP:3158 /
#     3169) become real "assets-present" checks instead of always-fail.
#   * BMP8.CPP, CONQUER.CPP CD-detect, and the various save-file paths
#     all work end-to-end at the file-IO layer.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
#
# Spot-check on BMP8.CPP and CONQUER.CPP (the two TUs that parse the
# new declarations under -fsyntax-only). Their existing call sites bind
# to concrete C signatures with the same arg counts as before; the
# variadic templates accepted any args, so the only risk is a
# type-conversion mismatch the templates were silently masking. Modern
# Win32 SDK signatures honor implicit pointer-to-pointer-typedef
# conversions (LPSECURITY_ATTRIBUTES <- NULL, HANDLE <- NULL) and
# integer-narrowing under -w (no warnings).
#
# Realistic ceiling: 301/0/301. The change set:
#   - 1 new TU (substrate .cpp, NOT in floor source set)
#   - 1 header edited (windows.h)
#   - 1 forward-decl block added to satisfy parameter typing
#
# Anything else means an unrelated cascade -- revert + handback per the
# rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45B.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45B.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45B.attribution.txt"

mkdir -p "$LOG_DIR"

SHIM_LOCK="$LOG_DIR/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -std=c++17
    -fsyntax-only
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    -include "$STUB_DIR/msvc-compat.h"
)

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0

{
    echo "# TIM-149 first compile attempt -- pass 45B (file-IO substrate bodies + windows.h kernel32 rewire)"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files (REDALERT/ + WIN32LIB/)"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$LOG_FILE"

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    tu_log="$(mktemp)"

    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$LOG_FILE"

    if "$CXX" "${CXXFLAGS[@]}" "$src" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$SUMMARY_FILE"
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$SUMMARY_FILE"
        primary=$(grep -m1 -E ': (fatal error|error):' "$tu_log" || true)
        if [[ -n "$primary" ]]; then
            echo "$rel -> $primary" >> "$ATTRIB_FILE"
        else
            echo "$rel -> (no diagnostic captured)" >> "$ATTRIB_FILE"
        fi
    fi

    cat "$tu_log" >> "$LOG_FILE"
    rm -f "$tu_log"
done

include_misses=$(grep -cE "fatal error: .*: No such file or directory" \
    "$LOG_FILE" || true)

{
    echo
    echo "----- totals -----"
    echo "ok:                  $ok"
    echo "fail:                $fail"
    echo "total:               $total"
    echo "include-not-found:   $include_misses"
} | tee -a "$SUMMARY_FILE" >> "$LOG_FILE"

echo "Log:        $LOG_FILE"
echo "Summary:    $SUMMARY_FILE"
echo "Attribution: $ATTRIB_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
