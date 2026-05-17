#!/usr/bin/env bash
# TIM-70 measurement: pass 37.
#
# Bundled 2-TU mechanical drain of the last sub-3-TU mechanical bucket
# pair surfaced by the post-TIM-69 (pass 36) histogram:
#
#   1) "GetKeyState was not declared" -- 2 TUs (KEY.CPP, KEYBOARD.CPP).
#      Trivially-additive shim: SHORT GetKeyState(int) inert stub added
#      to linux/win32-stubs/windows.h. VK_* constants live in the
#      engine's own KEY.H, not the shim. First-error advances past
#      line 217 / 194; both TUs cascade to the deeper Win32 message-
#      pump cluster (MSG / PeekMessage / GetMessage / TranslateMessage
#      / DispatchMessage / WM_* / LOWORD / HIWORD / GetAsyncKeyState /
#      ToAscii / PM_NOREMOVE) which is the family-grouped bucket
#      queued for the next pass.
#
#   2) "expected '(' before '{' token" -- 2 TUs (COORD.CPP, IRANDOM.CPP).
#      Predicted shape was Win32 declarator pattern; actual shape is
#      MSVC __asm { ... } inline assembly:
#        - COORD.CPP:418 calcx, COORD.CPP:436 calcy:
#          two leaf helpers used by Move_Point that signed-multiply a
#          16-bit param1 against a 16-bit distance and return bits 8-23
#          of the doubled product (calcy negates).
#        - IRANDOM.CPP:72 Random(): bit-shuffle LFSR over the 32-bit
#          RandNumb global.
#        - IRANDOM.CPP:93 Get_Random_Mask(maxval): bsr-based round-up-
#          to-power-of-two-minus-one mask.
#      Per the TIM-70 classification ladder this is (d) "something
#      stranger" and the procedure says flag and hand back -- inline
#      asm rewrites are NOT a trivially-additive shim entry and the
#      Random() bit-shuffle is faithful-translation work, not a
#      mechanical drain.
#
# Pre baseline (post TIM-69, commit c9b4f9d):
#   pass 36 (TIM-69) : 264 OK / 37 Fail / 301 Total.
#
# Realistic ceiling for THIS pass: 264 OK / 37 Fail / 301 Total
#   (GetKeyState shim drains the first-error bucket but the 2 TUs
#    fragment to the deeper message-pump cluster; inline-asm bucket is
#    handed back; net OK delta == 0).
#
# Same harness as passes 7-36 -- same flags, same shim regen, same
# stubs. Difference relative to pass 36: one shim addition in
# linux/win32-stubs/windows.h (GetKeyState).
#
# Pass progression (OK count) -- recent tail:
#   pass 30 (TIM-56)                      : 249
#   pass 31 (TIM-59 + TIM-61)             : 253
#   pass 31-rebaselined (post TIM-62/65)  : 254
#   pass 32 (TIM-63)                      : 254
#   pass 33 (TIM-66)                      : 254
#   pass 34 (TIM-67)                      : 259
#   pass 35 (TIM-68)                      : 260
#   pass 36 (TIM-69)                      : 264
#   pass 37 (TIM-70, this run)            : ???  (expected 264, +0 OK
#                                                 from GetKeyState
#                                                 fragmenting deeper)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass37.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass37.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass37.attribution.txt"

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
    echo "# TIM-70 first compile attempt -- pass 37 (GetKeyState shim)"
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
