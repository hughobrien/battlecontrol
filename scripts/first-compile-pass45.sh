#!/usr/bin/env bash
# TIM-84 measurement: pass 45.
#
# Engine text-constant cluster source-level fix in REDALERT/INIT.CPP
# and REDALERT/STARTUP.CPP. The four target symbols (TEXT_OPTIONS,
# TEXT_INVALID, TEXT_NO_MOUSE, TEXT_NO_RAM) are NOT enum entries --
# they are #defines in REDALERT/LANGUAGE.H gated on `#ifdef ENGLISH`.
# The original Westwood makefile injected the language define globally;
# our per-TU compile harness does not. Same root cause and same fix
# pattern as TIM-68 in CONQUER.CPP: pin `#define ENGLISH 1` at the top
# of each affected TU before `#include "function.h"` so the LANGUAGE.H
# macros expand.
#
# Pre-survey on master b8f7873 (post-TIM-82) confirmed:
#   REDALERT/INIT.CPP:1848    -> TEXT_OPTIONS not declared
#   REDALERT/STARTUP.CPP:226  -> TEXT_NO_RAM not declared
# (TEXT_INVALID @ INIT.CPP:2237 and TEXT_NO_MOUSE @ INIT.CPP:3408 are
#  cascading first-errors within INIT.CPP, masked by TEXT_OPTIONS
#  failing first; the ENGLISH define drains all three sites at once.)
#
# Pre baseline (post TIM-82, with TIM-79 WIP applied):
#   274 OK / 27 Fail / 301 Total.
# (Note: TIM-79 IDirectDrawPalette stub is held in worktree as
#  uncommitted DDRAW.H WIP per parallel-pass coordination; the
#  baseline assumes that WIP is applied. This pass measurement holds
#  TIM-79 WIP applied for both pre and post counts.)
#
# Realistic ceiling: 278 OK / 23 Fail (+4) -- both TUs advance to OK.
# Realistic floor:   274 OK / 27 Fail (+0) -- both advance to a deeper
#   non-TEXT_* first-error (smoke confirmed both TUs advance to deeper
#   errors: INIT -> strrev @ 2354, STARTUP -> GetModuleFileName @ 280;
#   neither deeper error is in scope for this pass).
#
# Net OK movement is expected to be +0 (floor case) since neither TU
# clears to OK. The PRIMARY value of this pass is histogram drain:
# the four TEXT_* sites disappear from the first-error histogram,
# unblocking downstream passes that target the deeper errors.
#
# Risk vector: ENGLISH define is TU-local (#ifndef-guarded), so blast
# radius is limited to INIT.CPP and STARTUP.CPP. LANGUAGE.H expansion
# only adds string literals as macros -- no struct layout, no global
# state, no link-time changes. Watch the regression diff for any
# unexpected OK->FAIL flips elsewhere.
#
# Same harness as passes 7-43 -- same flags, same shim regen, same
# stubs. Difference relative to pass 43: 7-line ENGLISH-pinning block
# at the top of REDALERT/INIT.CPP and REDALERT/STARTUP.CPP.
#
# Pass progression (OK count) -- recent tail:
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, CountDownTimerClass): 274
#   pass 45  (TIM-84, this run)           : ???
#
# Measurement script -- the actual fix lives in REDALERT/INIT.CPP and
# REDALERT/STARTUP.CPP.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45.attribution.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

CXX="${CXX:-g++}"

# Regenerate the case-folding shim every run so this script is
# self-contained and reproducible.
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
    # Order matters: case-folding shim first so re-cased headers win
    # over the on-disk uppercase originals; then the real source dirs
    # (catches anything we missed); then the stubs LAST so they only
    # fire for genuinely absent headers (windows.h, objbase.h, ...).
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    # Force-include the MSVC-extension shim (calling-convention macros,
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.).
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
    echo "# TIM-84 first compile attempt -- pass 45 (engine text-constant cluster source-level fix)"
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
