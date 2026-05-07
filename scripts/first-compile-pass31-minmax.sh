#!/usr/bin/env bash
# TIM-61 measurement: pass 31 min/max ADL pair (CCINI / SCENARIO).
#
# Mechanical replication of TIM-54 Fix C on the 2 TUs surfaced by
# fragmentation in TIM-57: CCINI.CPP and SCENARIO.CPP. TIM-57 drained
# the rvalue-binding cohort 249->251 (+2), but two of the cleared TUs
# next-shot to a min/max ADL diagnostic on the same TU (CCINI.CPP:252
# and SCENARIO.CPP:1484). TIM-54 Fix C already established the working
# precedent for this shape across 31 TUs; this is a 2-TU port of the
# same `#define min/max` shape.
#
# Pre baseline (post TIM-57 commit d485fff, post TIM-60 commit ffee30d):
#   251 OK / 50 Fail / 301 Total. Per-TU first errors confirmed:
#     REDALERT/CCINI.CPP    -> :252:15 'min' was not declared in this scope
#     REDALERT/SCENARIO.CPP -> :1484:26 'max' was not declared in this scope
#
# Target: 253 OK / 48 Fail / 301 Total (+2).
#
# Difference relative to pass-30-rvalue is REDALERT/ source-level only
# (2 TUs); shims and stubs are unchanged.
#   - TIM-61 fix: REDALERT/CCINI.CPP and REDALERT/SCENARIO.CPP each
#                 gain the TIM-54 Fix C `#define min/max` shim block
#                 immediately after `#include "function.h"`.
#
# Same harness as passes 7-30 -- same flags, same shim regen, same
# stubs.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass31-minmax.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass31-minmax.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass31-minmax.attribution.txt"

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
    echo "# TIM-61 first compile attempt -- pass 31 min/max ADL pair (CCINI/SCENARIO)"
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
