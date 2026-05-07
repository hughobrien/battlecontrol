#!/usr/bin/env bash
# TIM-113 measurement: pass 40X (SAVELOAD.CPP SelectedObjectsType::COUNT
# -> ::Length, L1x4).
#
# TIM-20 originally renamed `static const int COUNT` to `Length` inside
# DynamicVectorArrayClass because the original shadowed the template
# parameter. SAVELOAD.CPP still referenced the old `::COUNT` at four
# loop-bound sites:
#
#   :1089  for (i = 0; i < SelectedObjectsType::COUNT; i++)
#   :1148  for (int i = 0; i < SelectedObjectsType::COUNT; i++)
#   :1318  for (i = 0; i < SelectedObjectsType::COUNT; i++)
#   :1416  for (int index = 0; index < SelectedObjectsType::COUNT; ...)
#
# Mechanical sed s/::COUNT/::Length/g applied across SAVELOAD.CPP. Loop
# bounds, loop bodies, and types are unchanged. `rg "SelectedObjectsType
# ::COUNT" REDALERT/` returns 0 hits post-fix (verified before commit).
#
# Pre baseline (pass-40W tip, commit 2c81fe7):
#   287 OK / 14 Fail / 301 Total.
#
# Realistic ceiling: 288 OK / 13 Fail (+1) -- SAVELOAD.CPP graduates.
# Realistic floor:   287 OK / 14 Fail (+0) -- a fresh in-file cascade
#   (different shape, different line) surfaces (stop-and-hand-back per
#   TIM-105/TIM-111).
#
# Histogram diff target:
#   pre  -> SAVELOAD.CPP:1089: 'COUNT' is not a member of
#           'SelectedObjectsType' {aka 'DynamicVectorArrayClass<...>'}
#   post -> SAVELOAD.CPP gone from FAIL list (ceiling), or
#           SAVELOAD.CPP:<new-line>: <new-shape> (floor).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40X.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40X.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40X.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass-40X invocations end-to-end via flock.
#
# generate-include-shim.py --clean unlinks every symlink under
# build/include-shim/{redalert,win32lib} and recreates them. If a
# second invocation runs --clean while a first invocation is still in
# its compile loop, the first invocation transiently sees missing
# include-shim outputs. Holding the lock for the whole script means
# concurrent or rapid back-to-back invocations queue end-to-end.
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
    echo "# TIM-113 first compile attempt -- pass 40X (SAVELOAD.CPP ::COUNT -> ::Length L1x4)"
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
