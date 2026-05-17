#!/usr/bin/env bash
# TIM-30 measurement: pass 12.
#
# Re-baseline after TIM-28 (Bucket 4 tier-6+ -- SIDEBAR.H full
# self-containment audit; every type-name reference resolved by direct
# include in sidebar.h itself, no longer relying on FUNCTION.H ordering)
# and TIM-29 (msvc-compat.h far/near/pascal lowercase keyword shim).
# TIM-27's per-TU primary-error attribution pinned 179/209 (86%) of
# failures on SIDEBAR.H:342 'ShapeButtonClass does not name a type'.
# That ceiling should be gone now: the TIM-28 verification on
# AIRCRAFT.CPP showed the first error moving off SIDEBAR.H entirely
# to rawfile.h:269 INVALID_HANDLE_VALUE -- a different bucket.
#
# Pass 12 should finally show:
#   1. OK count jumps off the 88-92 plateau toward the TIM-13
#      projection of ~190+.
#   2. Platform-seam buckets (1, 5, 6a-6e) get honest primary-site
#      counts for the first time after seven rate-limited passes.
#   3. The new ceiling -- almost certainly RAWFILE.H Win32 seam --
#      gets sized for TIM-30+.
#
# If OK still doesn't lift, there is *another* header self-containment
# block we haven't named yet. The TIM-28 full-audit method (static
# enumeration of every type-name reference in the header) replaces
# tier-by-tier guessing -- apply the same method to whichever header
# turns out to block.
#
# Same harness as passes 7-11 -- same flags, same shim regen, same
# stub include path. The only differences relative to pass 11 are
# upstream: tier-6+ SIDEBAR.H full self-containment landed in TIM-28
# (b730b96) and far/near/pascal lowercase keyword shim landed in
# TIM-29 (69e3447).
#
# Pass progression (OK count):
#   pass 1 (no shim)                     : 37
#   pass 2 (lowercase symlinks)          : 44
#   pass 3 (shim + Win32 stubs)          : 73
#   pass 4 (TIM-8 + TIM-9)                : 81
#   pass 5 (TIM-11 + TIM-12)              : 81
#   pass 6 (TIM-14 + TIM-15)              : 88
#   pass 7 (TIM-17 + TIM-18)              : 88
#   pass 8 (TIM-20)                       : 88
#   pass 9 (TIM-22)                       : 88
#   pass 10 (TIM-24)                      : 92
#   pass 11 (TIM-26)                      : 92
#   pass 12 (TIM-28 + TIM-29, this run)   : ?
#
# Measurement only -- no source fixes in this ticket.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass12.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass12.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass12.attribution.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

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
    # TIM-29 added far/near/pascal lowercase keyword shim. Force-include
    # keeps the upstream sources untouched for the cross-cutting
    # MSVC-isms; per-header patches (bool typedef, typename annotations,
    # BIG_ENDIAN portability, STAGE/ABSTRACT forward decls, MISC.H
    # random() guard, Big-Six self-containment, tier-2 self-containment,
    # tier-3 GSCREEN.H/SHA.H promotion, tier-4 RADAR.H qualifier +
    # tier-5 SIDEBAR.H control.h + PALETTE.H extern fixup, tier-6+
    # SIDEBAR.H full self-containment) are still needed.
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
    echo "# TIM-30 first compile attempt -- pass 12 (post TIM-28 + TIM-29)"
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

    # Per-TU log captured to a temp so we can extract the *first*
    # diagnostic line for the per-TU primary-error attribution table.
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
        # First "error:" or "fatal error:" line is the primary site.
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

# Tally include-not-found errors so we can compare against pass 11's
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

echo "Log:        $LOG_FILE"
echo "Summary:    $SUMMARY_FILE"
echo "Attribution: $ATTRIB_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
