#!/usr/bin/env bash
# TIM-149 pass-45F: WinTimerClass Linux path — TickCount advances via timeGetTime().
#
# Baseline: pass-45E tip (commit 7e34f67) — floor 301/0/301.
# Pass-45F must keep that floor unchanged.
#
# === Diff vs pass-45E ===
#
# (1) MODIFIED REDALERT/WIN32LIB/TIMERINI.CPP:
#       * WinTimerClass constructor: under #ifndef _MSC_VER, bypass
#         timeSetEvent (stub returns 0 on Linux). Set TimerSystemOn=TRUE
#         directly; if not partial, set WindowsTimer=this and call
#         TickCount.Start(). The callback path (Timer_Callback/SysTicks++)
#         is unused on Linux.
#       * Get_System_Tick_Count(): under #ifndef _MSC_VER, return
#         (unsigned long long)timeGetTime() * Frequency / 1000ULL.
#         timeGetTime() is backed by clock_gettime(CLOCK_MONOTONIC) in
#         linux/win32-stubs/mmsystem.h and returns milliseconds; dividing
#         by 1000 and multiplying by Frequency (60) yields 60 ticks/sec.
#       * Get_User_Tick_Count(): same formula as Get_System_Tick_Count().
#
# === Why this is the right next step ===
#
# After pass-45E the binary runs indefinitely (main loop active), but all
# timer-derived values (TickCount, CountDown, ProcessTimer) are always 0.
# The game's frame-pacing loop at REDALERT/MAIN.CPP:5572
# ("while (x == TickCount)") never exits — each frame consumes 0 ticks
# relative to its prior read, so the spin doesn't pace at all.  Pass-45F
# wires TickCount to the monotonic wall clock so ticks advance at 60Hz and
# frame-pacing logic becomes functional.
#
# === Cascade-stop expectations ===
#
# Target: floor unchanged at 301/0/301. The only changed file is
# TIMERINI.CPP, which already compiles OK. The #ifndef _MSC_VER guards
# isolate Linux-path changes; both branches type-check correctly.
# Spot-check: TIMERINI.CPP must stay OK.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45F.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45F.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45F.attribution.txt"

mkdir -p "$LOG_DIR"

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
    echo "# TIM-149 first compile attempt -- pass 45F (WinTimerClass Linux path: TickCount via timeGetTime)"
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
