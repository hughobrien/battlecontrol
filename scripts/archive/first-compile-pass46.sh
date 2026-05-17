#!/usr/bin/env bash
# TIM-86 measurement: pass 46.
#
# Source-level fixes for two trivial first-error sites disjoint from
# the TIM-85 Win32 shim cluster:
#
#   - REDALERT/INIT.CPP @ 2354/2369 — strrev is a Watcom CRT extension
#     not present in glibc. TU-local `static inline strrev` (returning
#     char *) added near the top of INIT.CPP, guarded by `#ifndef
#     _WIN32` so Watcom Win32 keeps using its CRT decl. Single TU
#     covers both call sites; no other TU references strrev.
#
#   - REDALERT/LOADDLG.CPP @ 483 — unlink is declared in <io.h> on
#     Watcom/Win32 but our linux/win32-stubs/io.h is an empty
#     placeholder. Add `#include <unistd.h>` for non-Win32 builds. The
#     include must precede `function.h` because WIN32LIB/wwstd.h
#     auto-defines _WIN32 (see WIN32LIB/wwstd.h:43), which would
#     otherwise nullify the guard.
#
# Pre baseline (post TIM-85 / pass 40F on master 4749694, with TIM-79
# IDirectDrawPalette WIP held in worktree DDRAW.H per pass-45's note):
#   275 OK / 26 Fail / 301 Total.
#
# Realistic ceiling: 277 OK / 24 Fail (+2) — both TUs advance to OK.
# Realistic floor:   275 OK / 26 Fail (+0) — both advance to a deeper
#   non-strrev/unlink first-error. Smoke confirmed both TUs land in
#   the floor case:
#     INIT.CPP   strrev@2354 -> ShowCursor@3422
#     LOADDLG    unlink@483  -> _splitpath@760
#   Neither deeper error is in TIM-86 scope.
#
# Net OK movement is therefore +0. PRIMARY value of this pass is
# histogram drain: strrev and unlink disappear from the first-error
# attribution, unblocking downstream passes targeting deeper failures.
#
# Risk vector: both edits are TU-local. strrev inline is plain
# C-string reversal with no side effects; unlink shim adds the POSIX
# header on Linux only. No flag changes, no shared-shim edits. Watch
# the regression diff for any unexpected OK->FAIL flips elsewhere.
#
# Pass progression (OK count) — recent tail:
#   pass 40F (TIM-85, Win32 type/API stub bundle): 275
#   pass 45  (TIM-84)                              : 274
#   pass 43  (TIM-82, CountDownTimerClass)        : 274
#   pass 46  (TIM-86, this run)                    : ???
#
# Same harness as passes 7-45 — same flags, same shim regen, same
# stubs.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass46.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass46.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass46.attribution.txt"

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
    echo "# TIM-86 first compile attempt -- pass 46 (strrev + unlink source-level fix)"
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
