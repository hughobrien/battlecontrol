#!/usr/bin/env bash
# TIM-76 measurement: pass 40B.
#
# Win32 GDI / window-misc shim drain in linux/win32-stubs/windows.h:
# the cluster surfaced post TIM-71 in INIT.CPP, MOUSEWW.CPP and
# TIMERINI.CPP. All entries are trivially-additive (inert inline
# returns, integer macro constants), matching the proven TIM-67
# audio-symbol shape and TIM-71 input-symbol shape.
#
# Functions added:
#   GetCursorPos(LPPOINT)       -> TRUE (zero-init *lpPoint)
#   GetLastError(void)          -> 0
#   SetForegroundWindow(HWND)   -> TRUE
#
# Macros / constants added:
#   S_OK     ((HRESULT)0L)
#   S_FALSE  ((HRESULT)1L)
#
# IDirectDraw::RestoreDisplayMode was listed in TIM-76 in-scope but
# the IDirectDraw shim class lives in REDALERT/WIN32LIB/DDRAW.H, not
# in linux/win32-stubs/. Editing it would touch a non-shim header
# location, which TIM-76 explicitly forbids ("Stop & hand back if
# header touches a non-`linux/win32-stubs/` location"). Deferred to a
# follow-up dispatch that intentionally widens the scope.
#
# Pre baseline (post TIM-71, commit 61259a9):
#   pass 38 (TIM-71) : 266 OK / 35 Fail / 301 Total.
#
# Realistic ceiling for THIS pass: 269 OK / 32 Fail / 301 Total
#   (MOUSEWW.CPP clears; INIT.CPP and TIMERINI.CPP advance past their
#    GDI/window-misc first-error and may cascade into deeper non-shim
#    buckets; DDRAW.CPP unchanged because RestoreDisplayMode deferred).
# Realistic floor: +1 OK (only MOUSEWW.CPP clears, INIT/TIMERINI cascade
#   into deeper non-GDI buckets without clearing).
#
# Same harness as passes 7-38 -- same flags, same shim regen, same
# stubs. Difference relative to pass 38: one bundled additive edit in
# linux/win32-stubs/windows.h (TIM-76 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 34 (TIM-67)                      : 259
#   pass 35 (TIM-68)                      : 260
#   pass 36 (TIM-69)                      : 264
#   pass 37 (TIM-70)                      : 264
#   pass 38 (TIM-71)                      : 266
#   pass 40B (TIM-76, this run)            : ???  (expected 267-269)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40B.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40B.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40B.attribution.txt"

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
    echo "# TIM-76 first compile attempt -- pass 40B (Win32 GDI/window-misc cluster shim)"
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
