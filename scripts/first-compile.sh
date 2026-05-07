#!/usr/bin/env bash
# TIM-4 measurement only: try syntax-checking every REDALERT .cpp on Linux
# and capture all errors. Does NOT attempt to fix anything. The point of
# this script is to produce build/first-compile.log so we can scope the
# real porting work (TIM-5+).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile.log"
SUMMARY_FILE="$LOG_DIR/first-compile.summary.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"

CXX="${CXX:-g++}"

# Flags: just syntax-check (no codegen, no link), C++17 to match the
# toolchain in TIM-3, include both REDALERT/ and REDALERT/WIN32LIB/.
# -fmax-errors caps per-file noise so one runaway file can't dominate.
CXXFLAGS=(
    -std=c++17
    -fsyntax-only
    -fmax-errors=20
    -fno-strict-aliasing
    -Wno-everything   # ignored by gcc; harmless if clang
    -w                # suppress warnings — we only care about errors here
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
)

shopt -s nullglob

# We measure both REDALERT/ and REDALERT/WIN32LIB/ since they're part of
# the same translation set. Use case-insensitive globbing because the
# upstream uses mixed-case .CPP/.cpp.
shopt -s nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0

{
    echo "# TIM-4 first compile attempt"
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
