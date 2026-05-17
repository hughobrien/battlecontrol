#!/usr/bin/env bash
# TIM-82 measurement: pass 43.
#
# CountDownTimerClass source-level fix in REDALERT/FUNCTION.H:
# Linux carve-out for the legacy `#ifndef WIN32 / #define TIMER_H`
# preemptive guard (introduced for the original Watcom non-WIN32 build
# to skip WIN32LIB/TIMER.H). Our Linux build doesn't define WIN32
# either, so the same guard fires and suppresses TIMER.H's body --
# leaving CountDownTimerClass / TimerClass / WinTimerClass undeclared
# for every FUNCTION.H consumer. Adding `&& !defined(__linux__)`
# disables the suppression on Linux while preserving the original
# Watcom-DOS path.
#
# Pre-survey on master 36a4022 confirmed:
#   REDALERT/CONQUER.CPP:4277 -> CountDownTimerClass not declared
#   REDALERT/INIT.CPP:1141    -> CountDownTimerClass not declared
# (compiler suggests `did you mean 'CountDownTimer'?` -- the global
#  instance, but the class itself is missing.)
#
# Pre baseline (post TIM-79 + TIM-80): 272 OK / 29 Fail / 301 Total.
# (Note: TIM-79 IDirectDrawPalette stub is held in worktree as
#  uncommitted DDRAW.H WIP per parallel-pass coordination; the
#  baseline assumes that WIP is applied. This pass measurement holds
#  TIM-79 WIP applied for both pre and post counts.)
#
# Realistic ceiling: 274 OK / 27 Fail (+2) -- both TUs advance to OK.
# Realistic floor:   272 OK / 29 Fail (+0) -- both advance to a deeper
#   non-CountDownTimerClass first-error (smoke confirmed both TUs
#   advance to deeper errors: CONQUER -> GetVolumeInformation,
#   INIT -> TEXT_OPTIONS).
#
# Risk vector: removing the TIMER_H suppression lets TIMER.H run, and
# TIMER.H itself does `#ifndef WIN32 / #define WIN32` mid-include. That
# would cascade into FUNCTION.H's later `#ifdef WIN32` blocks (assert
# override, Win32-only extern declarations, int386 macros). Watch the
# regression diff for any FUNCTION.H consumers that flip OK->FAIL.
#
# Same harness as passes 7-42 -- same flags, same shim regen, same
# stubs. Difference relative to pass 42: one-line guard tweak in
# REDALERT/FUNCTION.H (TIM-82 carve-out).
#
# Pass progression (OK count) -- recent tail:
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, this run)           : ???
#
# Measurement script -- the actual fix lives in REDALERT/FUNCTION.H.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass43.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass43.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass43.attribution.txt"

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
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.).
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
    echo "# TIM-82 first compile attempt -- pass 43 (CountDownTimerClass source-level fix)"
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
