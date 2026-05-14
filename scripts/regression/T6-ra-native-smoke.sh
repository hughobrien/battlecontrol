#!/usr/bin/env bash
# T6 — RA native short-run smoke (TIM-623).
#
# Runs the RA native ELF for 30 s under Xvfb :99 with RA_AUTOSTART=1, then
# asserts the log shows ≥ 100 frames and zero SIGSEGV / Aborted / CRASH.
# A lighter version of `first-run-pass-94.sh` (which uses 120 s and demands
# a full win cycle). Catches game-loop regressions (TIM-231 class) and
# early in-game crash regressions (TIM-218 / TIM-222 class).
#
# Prerequisites:
#   build/first-run-pass-94/redalert.elf — RA native binary
#   build/run-172/                        — RA assets staged (LOCAL.MIX, …)
#
# Budget: 45 s. Hard timeout: 60 s.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELF="$REPO_ROOT/build/first-run-pass-94/redalert.elf"
RUN_DIR="$REPO_ROOT/build/run-172"
OUT_DIR="$REPO_ROOT/e2e/screenshots"
LOG="$OUT_DIR/t6-ra-native-smoke.log"
mkdir -p "$OUT_DIR"

if [ ! -x "$ELF" ]; then
    echo "T6 SKIP: $ELF not built (run \`bash scripts/first-run-pass-94.sh\`)"
    exit 77
fi
if [ ! -d "$RUN_DIR" ]; then
    echo "T6 SKIP: $RUN_DIR not staged"
    exit 77
fi

pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1
trap "kill -9 $XVFB_PID 2>/dev/null || true" EXIT

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 30 "$ELF") > "$LOG" 2>&1
RC=$?
echo "T6 run rc=$RC (124=timeout=alive, 0=clean exit)"

CRASHES=$(grep -c -E "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" || true)
MAX_FRAME=$(grep -aE "frame=[0-9]+" "$LOG" | sed -E 's/.*frame=([0-9]+).*/\1/' | sort -n | tail -1)
MAX_FRAME=${MAX_FRAME:-0}

echo "T6 max_frame=$MAX_FRAME crashes=$CRASHES log=$LOG"

if [ "$CRASHES" -gt 0 ]; then
    echo "T6 FAIL: $CRASHES crash signals detected"
    grep -aE "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" | head -3
    exit 1
fi

if [ "$MAX_FRAME" -lt 100 ]; then
    echo "T6 FAIL: only reached frame=$MAX_FRAME (need ≥ 100)"
    tail -10 "$LOG"
    exit 1
fi

echo "T6 PASS"
exit 0
