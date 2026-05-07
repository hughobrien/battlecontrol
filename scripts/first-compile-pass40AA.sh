#!/usr/bin/env bash
# TIM-118 measurement: pass 40AA (WRITEPCX.CPP:181 LP64 ptrdiff cast).
#
# Direct successor to TIM-117/pass-40Z. With Extract_String + FILE.H
# forward-decls landed (commit 8b4a502), the next first-error in
# WRITEPCX.CPP is the explicitly out-of-scope LP64 site at line 181:
#
#   Write_File ( file_handle, pool , ( int ) file_ptr - ( int ) pool ) ;
#
# Both pointers are `unsigned char *`; subtracting them yields ptrdiff_t.
# Under -fpermissive gcc treats the `(int) ptr` precision-loss diagnostic
# as a hard error. Replaced with:
#
#   Write_File ( file_handle, pool , static_cast<unsigned long>(file_ptr - pool) ) ;
#
# Matches Write_File's `unsigned long bytes` signature in WIN32LIB/FILE.H.
#
# Pre baseline (pass-40Z tip, commit 8b4a502):
#   289 OK / 12 FAIL / 301 Total.
#
# Realistic ceiling: 290 OK / 11 FAIL (+1) -- WRITEPCX.CPP graduates.
# Realistic floor:   289 OK / 12 FAIL (+0) -- a fresh in-file cascade
#   (different shape/line) surfaces in WRITEPCX.CPP. Per cascade
#   stop-and-handback rule, comment with the new first-error and hand
#   back to CEO; do not chain a fourth surgical fix on this TU.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AA.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AA.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AA.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass invocations end-to-end via flock.
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
    echo "# TIM-118 first compile attempt -- pass 40AA (WRITEPCX.CPP:181 LP64 ptrdiff cast)"
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
