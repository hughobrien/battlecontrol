#!/usr/bin/env bash
# TIM-25 measurement: pass 10.
#
# Re-baseline after TIM-24 (Bucket 4 tier-3 -- GSCREEN.H gadget.h
# promotion + SHA.H <new>). TIM-23's per-TU primary-error attribution
# pinned 179/213 failures on display.h:271 (incomplete GadgetClass for
# inheritance). TIM-24 promotes gadget.h's forward decl to a full
# include in GSCREEN.H so subclasses see the full layout, and adds
# <new> to SHA.H for placement-new. With those landed the cascade
# should finally clear and OK count should jump off 88 toward the
# TIM-13 projection (~190+).
#
# Pass 10 also has to surface honest counts for the platform-seam
# buckets (1, 5, 6a-6e) that were rate-limited under -fmax-errors=20
# by Bucket 4 co-blockers for four passes running. Without honest
# primary-site counts we cannot size TIM-26+ scope.
#
# Same harness as passes 7-9 -- same flags, same shim regen, same stub
# include path. The only difference relative to pass 9 is upstream:
# tier-3 GSCREEN.H/SHA.H seams now compile against complete types.
#
# Pass progression (OK count):
#   pass 1 (no shim)                    : 37
#   pass 2 (lowercase symlinks)         : 44
#   pass 3 (shim + Win32 stubs)         : 73
#   pass 4 (TIM-8 + TIM-9)              : 81
#   pass 5 (TIM-11 + TIM-12)            : 81
#   pass 6 (TIM-14 + TIM-15)            : 88
#   pass 7 (TIM-17 + TIM-18)            : 88
#   pass 8 (TIM-20)                     : 88
#   pass 9 (TIM-22)                     : 88
#   pass 10 (TIM-24, this run)          : ?
#
# Measurement only -- no source fixes in this ticket.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass10.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass10.summary.txt"

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
    # typename annotations, BIG_ENDIAN portability, STAGE/ABSTRACT
    # forward decls, MISC.H random() guard, Big-Six self-containment,
    # tier-2 self-containment, tier-3 GSCREEN.H/SHA.H promotion) are
    # still needed.
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
    echo "# TIM-25 first compile attempt -- pass 10 (post TIM-24)"
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

# Tally include-not-found errors so we can compare against pass 9's
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
