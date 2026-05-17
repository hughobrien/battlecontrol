#!/usr/bin/env bash
# TIM-4 measurement: pass 2.
# Pass 1 (scripts/first-compile.sh) showed that 86% of files die on the
# very first #include due to filesystem case-sensitivity (lowercase
# include vs uppercase header file on disk). To get a useful category
# map of what's *behind* the include layer, this pass adds a lowercase
# symlink farm (build/include-shim/) ahead of the real REDALERT/ paths.
# No source files are modified.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass2.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass2.summary.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"

CXX="${CXX:-g++}"

CXXFLAGS=(
    -std=c++17
    -fsyntax-only
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    # Lowercase symlink farm first, then the real (uppercase) dirs as
    # fallback for headers we didn't lowercase or that include via
    # exact-case paths.
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
)

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0

{
    echo "# TIM-4 first compile attempt -- pass 2 (with lowercase header shim)"
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
    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$LOG_FILE"

    if "$CXX" "${CXXFLAGS[@]}" "$src" >>"$LOG_FILE" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$SUMMARY_FILE"
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$SUMMARY_FILE"
    fi
done

{
    echo
    echo "----- totals -----"
    echo "ok:    $ok"
    echo "fail:  $fail"
    echo "total: $total"
} | tee -a "$SUMMARY_FILE" >> "$LOG_FILE"

echo "Log:     $LOG_FILE"
echo "Summary: $SUMMARY_FILE"
echo "ok=$ok fail=$fail total=$total"
