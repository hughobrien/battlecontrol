#!/usr/bin/env bash
# TIM-117 measurement: pass 40Z (WRITEPCX.CPP Extract_String + FILE.H
# forward-decls in WRITEPCX.CPP/INLINE.H, L5 successor to TIM-116).
#
# Cascade context (post TIM-113 tip, 289 OK / 12 FAIL / 301 total):
#   - TIM-114 (L1, cancelled): forward-decl Extract_String in INLINE.H -- correct
#     fix for the inline-call site, but unmasked a FILE.H I/O cluster behind it
#     (Open_File/Close_File/Write_File at WRITEPCX.CPP:74,81,100,101,102,127,176).
#   - TIM-116 (L4, cancelled): tried `#include "file.h"` in WRITEPCX.CPP --
#     no-op because FUNCTION.H:197-198 unconditionally `#define FILE_H` /
#     `#define WWMEM_H`, suppressing FILE.H's body when wwlib32.h transits
#     FUNCTION.H upstream.
#
# This pass (L5): bypass the FUNCTION.H pre-define guard with surgical
# forward-decls in the consuming TU. Two edits, 4 added lines, 0 new
# `#include`s, no header-tree refactor.
#
# 1. REDALERT/INLINE.H above ~line 929:
#      extern char *Extract_String(void const *data, int string);
#    Mirrors WIN32LIB/DIPTHONG.H:18 (no extern "C", no __cdecl).
#
# 2. REDALERT/WIN32LIB/WRITEPCX.CPP after the include block (lines 35-37):
#      int  __cdecl Open_File (char const *file_name, int mode);
#      void __cdecl Close_File(int handle);
#      long __cdecl Write_File(int handle, void const *buf, unsigned long bytes);
#    Mirrors WIN32LIB/FILE.H:184-188 exactly. No extern "C": FILE.H's
#    actual extern "C" block at 244-251 wraps only Find_First/Find_Next,
#    not the file I/O prototypes.
#
# Pre baseline (pass-40X tip, commit f146bf6):
#   289 OK / 12 FAIL / 301 Total.
#
# Realistic ceiling: 290 OK / 11 FAIL (+1) -- WRITEPCX.CPP graduates.
# Realistic floor:   289 OK / 12 FAIL (+0) -- a fresh in-file cascade
#   (different shape/line) surfaces in WRITEPCX.CPP. Per TIM-117's
#   stop-and-hand-back rule (third attempt on this TU), comment with
#   the new first-error and hand back to CEO; do not chain a fourth
#   surgical fix.
#
# Histogram diff target:
#   pre  -> WRITEPCX.CPP:74:..: 'Open_File' was not declared in this scope
#   post -> WRITEPCX.CPP gone from FAIL list (ceiling), or
#           WRITEPCX.CPP:<new-line>: <new-shape> (floor).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40Z.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40Z.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40Z.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass-40Z invocations end-to-end via flock.
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
    echo "# TIM-117 first compile attempt -- pass 40Z (WRITEPCX.CPP Extract_String + FILE.H forward-decls)"
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
