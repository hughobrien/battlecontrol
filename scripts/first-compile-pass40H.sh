#!/usr/bin/env bash
# TIM-88 measurement: pass 40H.
#
# Single-target cache-warm continuation of TIM-87 (pass 40G). Adds one
# variadic-template inert stub to linux/win32-stubs/io.h:
#   - lseek (RAWFILE.CPP:1317, POSIX file-seek; Watcom CRT exposed it
#     via <io.h>, the include the engine reaches through). Same shape
#     as `filelength` (TIM-87) and the `_dos_*` family in dos.h
#     (TIM-85). Inert `0` return is safe at the call site
#     (RawFileClass::Raw_Seek treats `pos == -1` as the only fatal
#     seek-error sentinel).
#
# Pre baseline (post TIM-87, commit 4d800ea, with TIM-79 DDRAW.H WIP
# applied):
#   276 OK / 25 Fail / 301 Total.
#
# Realistic ceiling: 277 OK / 24 Fail (+1) -- RAWFILE.CPP advances to
#   OK or to a deeper non-listed first-error.
# Realistic floor:   276 OK / 25 Fail (+0) -- RAWFILE.CPP advances to
#   a deeper first-error that doesn't clear net (cluster drained).
#
# Smoke-confirmed pre-state: REDALERT/RAWFILE.CPP first-error is
#   `'lseek' was not declared in this scope` @1317:23.
# Smoke-confirmed post-state: RAWFILE.CPP exit 0 (clears under shim).
#
# Same harness as passes 7-40G -- same flags, same shim regen, same
# stubs. Difference relative to pass 40G: one additive line in
# linux/win32-stubs/io.h (TIM-88 cluster).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40H.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40H.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40H.attribution.txt"

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
    echo "# TIM-88 first compile attempt -- pass 40H (lseek shim in io.h)"
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
