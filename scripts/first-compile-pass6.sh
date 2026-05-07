#!/usr/bin/env bash
# TIM-16 measurement: pass 6.
#
# Re-baseline after TIM-14 (BIG_ENDIAN: replace
# `#ifdef BIG_ENDIAN` in DEFINES.H with the portable
# `__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__` GCC predefined check; the
# original macro is undefined on Linux, so the conditional was always
# taking the wrong branch and inverting bitfield layouts) and TIM-15
# (msvc-compat shim now provides `itoa` / `ltoa` wrappers and a
# minimal `IDirectDrawSurface` stub so GBUFFER.H stops failing on
# DirectDraw-typed members and the WIN32LIB shape pipeline stops
# tripping over MSVC CRT calls).
#
# Same harness as pass 5 -- same flags, same shim regen, same stub
# include path. The only differences relative to pass 5 are upstream:
# DEFINES.H bitfield order is now correct on x86_64 Linux, GBUFFER.H
# no longer cascades through ~190 TUs that include it transitively,
# and a small set of WIN32LIB shape sources stops choking on the MSVC
# CRT integer-to-string helpers.
#
# Pass progression (OK count):
#   pass 1 (no shim)                    : 37
#   pass 2 (lowercase symlinks)         : 44
#   pass 3 (shim + Win32 stubs)         : 73
#   pass 4 (TIM-8 + TIM-9)              : 81
#   pass 5 (TIM-11 + TIM-12)            : 81
#   pass 6 (TIM-14 + TIM-15, this run)  : ?
#
# Measurement only -- no source fixes in this ticket.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass6.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass6.summary.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"

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
    # TIM-6: force-include the MSVC-extension shim (calling-convention
    # macros, __int64 typedef, _lrotl). TIM-11 added _NO_COM to disable
    # DDRAW.H's COM block. TIM-15 added itoa/ltoa wrappers and the
    # IDirectDrawSurface forward declaration the GBUFFER.H members need.
    # Force-include keeps the upstream sources untouched for the
    # cross-cutting MSVC-isms; per-header patches (bool typedef,
    # typename annotations, BIG_ENDIAN portability) are still needed.
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
    echo "# TIM-16 first compile attempt -- pass 6 (post TIM-14 + TIM-15)"
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

# Tally include-not-found errors so we can compare against pass 5's
# baseline (3 misses, all known-dead siblings).
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

echo "Log:     $LOG_FILE"
echo "Summary: $SUMMARY_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
