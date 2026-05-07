#!/usr/bin/env bash
# TIM-98 measurement: pass 40N.
#
# WINSTUB.CPP first-error drain at :812 -- ExitProcess kernel32 stub
# in linux/win32-stubs/windows.h. Real Win32 SDK signature:
#     void WINAPI ExitProcess(UINT uExitCode)
# declared in <processthreadsapi.h> / <winbase.h>; documented as
# `__declspec(noreturn)` on Windows. WINSTUB.CPP has two live call
# sites:
#     :256  -- Message_Loop Process-Quit branch (case 0 path)
#     :812  -- Memory_Error_Handler tail
# Both are unguarded engine code on the Linux build path. The shim is
# inert (does NOT actually exit) because:
#   1. -fsyntax-only smoke compile is a parser walk, no runtime exit.
#   2. The eventual SDL2 port routes shutdown through ReadyToQuit /
#      atexit; we will not surface kernel32 process termination at
#      the seam.
# Sibling-shape to TIM-92 GetModuleFileName -- same kernel32
# process-control cluster, same extern "C" placement (between the
# kernel32 GetModuleFileName surface and the closing brace of the
# kernel32-extern-C block).
#
# Pre baseline (post TIM-97, commit 21b7fcc):
#   278 OK / 23 Fail / 301 Total.
# Post-TIM-97 attribution confirmed WINSTUB.CPP first-error matches
# the issue claim:
#   REDALERT/WINSTUB.CPP:812:9 -> 'ExitProcess' was not declared
# A standalone smoke compile of WINSTUB.CPP after the stub addition
# completed silently (no diagnostics) -- the entire TU now parses,
# so the realistic ceiling of +1 OK is in play.
#
# Realistic ceiling: 279 OK / 22 Fail (+1) -- WINSTUB.CPP fully clears
#   (smoke-confirmed pre-pass).
# Realistic floor: 278 OK / 23 Fail (+0) -- a deeper TU regresses on
#   the alias surface (no plausible mechanism, but the floor is the
#   issue's stated possible outcome).
#
# Histogram diff target (WINSTUB only):
#   pre  -> WINSTUB.CPP:812:9 -> 'ExitProcess' was not declared
#   post -> WINSTUB.CPP        (no diagnostic; OK)
#
# Pass timeline so far:
#   pass 39  (TIM-74)                     : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, CountDownTimerClass): 274 (with TIM-79 WIP)
#   pass 45  (TIM-84, ENGLISH= pin)       : 274
#   pass 40F (TIM-85, Win32 stub bundle)  : 275
#   pass 40G (TIM-87, Win32 shape bundle) : 276
#   pass 40H (TIM-88, RAWFILE lseek)      : 277
#   pass 40I (TIM-89, WINSTUB mmio)       : 277
#   pass 40J (TIM-90, BMP8 wingdi structs): 278 (floor; histogram drain)
#   pass 40J' (TIM-91, _splitpath shim)   : 278
#   pass 40K (TIM-94, kernel32 cluster)   : 277
#   pass 40K' (TIM-92, GetModuleFileName) : 277
#   pass 40L (TIM-96, BMP8 GDI dispatch)  : 277 (floor; histogram drain)
#   pass 40L' (TIM-95, PostMessage drain) : 278
#   pass 40M (TIM-97, TEXT_* alias)       : 278 (floor; histogram drain)
#   pass 40N (TIM-98, this run)           : ?
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40N.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40N.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40N.attribution.txt"

mkdir -p "$LOG_DIR"
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
    echo "# TIM-98 first compile attempt -- pass 40N (WINSTUB ExitProcess kernel32 stub)"
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
