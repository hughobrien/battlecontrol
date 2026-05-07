#!/usr/bin/env bash
# TIM-78 measurement: pass 40C.
#
# IDirectDrawSurface shim widening in REDALERT/WIN32LIB/DDRAW.H:
# adds variadic-template inert SetPalette/Restore siblings to the
# existing IDirectDrawSurface shim class added by TIM-15 under
# `#if defined(_NO_COM)`. Matches the proven TIM-76 IDirectDraw
# widening shape (long return, swallow-everything variadic args).
#
# Methods added:
#   IDirectDrawSurface::SetPalette  -> 0
#   IDirectDrawSurface::Restore     -> 0
#
# Pre-survey confirmed only those two IDirectDrawSurface methods
# were missing in DDRAW.CPP. The IDirectDrawPalette incomplete-type
# at DDRAW.CPP:752 is the expected pass-40D handoff (NOT in scope
# here).
#
# Pre baseline (post TIM-76, commit 4f856d3):
#   pass 40B (TIM-76) : 268 OK / 33 Fail / 301 Total.
#
# Realistic ceiling: +0 OK -- DDRAW.CPP cascades into IDirectDrawPalette
#   which is out of scope; cluster considered drained for the
#   IDirectDrawSurface method surface either way.
# Realistic floor: 268 OK / 33 Fail / 301 Total (cluster drained,
#   no regressions).
#
# Same harness as passes 7-40B -- same flags, same shim regen, same
# stubs. Difference relative to pass 40B: one bundled additive edit
# in REDALERT/WIN32LIB/DDRAW.H (TIM-78 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 36 (TIM-69)                      : 264
#   pass 37 (TIM-70)                      : 264
#   pass 38 (TIM-71)                      : 266
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78, this run)           : ???  (expected 268)
#
# Measurement script -- the actual fix lives in REDALERT/WIN32LIB/DDRAW.H.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40C.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40C.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40C.attribution.txt"

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
    # Force-include the MSVC-extension shim (calling-convention macros,
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.). See pass 35
    # script header for the cross-cutting MSVC-isms covered here.
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
    echo "# TIM-78 first compile attempt -- pass 40C (IDirectDrawSurface shim widening)"
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
