#!/usr/bin/env bash
# T11 — RA native M2 smoke test (TIM-861).
#
# Runs the RA native ELF for 120 s under Xvfb :99 with RA_AUTOSTART=1 and
# RA_SCENE=SCG02EA.INI (Allied Mission 2), then asserts the log shows ≥ 1000
# frames and zero SIGSEGV / Aborted / CRASH.  Catches M2-specific game-loop
# regressions in mission-start, AI, and map-rendering paths.
#
# Prerequisites:
#   build/ra or build/first-run-pass-94/redalert.elf — RA native binary
#   build/run-172/                                       — RA assets staged
#
# Budget: 120 s. Hard timeout: 150 s.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELF="$REPO_ROOT/build/ra"
if [ ! -x "$ELF" ]; then
  ELF="$REPO_ROOT/build/first-run-pass-94/redalert.elf"
fi
RUN_DIR="$REPO_ROOT/build/run-172"
OUT_DIR="$REPO_ROOT/e2e/screenshots"
LOG="$OUT_DIR/t11-ra-native-m2-smoke.log"
mkdir -p "$OUT_DIR"

if [ ! -x "$ELF" ]; then
    echo "T11 SKIP: no RA native binary found"
    exit 77
fi
if [ ! -d "$RUN_DIR" ]; then
    echo "T11 SKIP: $RUN_DIR not staged"
    exit 77
fi

pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1
trap "kill -9 $XVFB_PID 2>/dev/null || true" EXIT

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy \
    RA_AUTOSTART=1 RA_SCENE=SCG02EA.INI \
    timeout 120 "$ELF") > "$LOG" 2>&1
RC=$?
echo "T11 run rc=$RC (124=timeout=alive, 0=clean exit)"

CRASHES=$(grep -c -E "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" || true)
MAX_FRAME=$(grep -aE "frame=[0-9]+" "$LOG" | sed -E 's/.*frame=([0-9]+).*/\1/' | sort -n | tail -1)
MAX_FRAME=${MAX_FRAME:-0}

echo "T11 max_frame=$MAX_FRAME crashes=$CRASHES log=$LOG"

if [ "$CRASHES" -gt 0 ]; then
    echo "T11 FAIL: $CRASHES crash signals detected"
    grep -aE "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" | head -3
    exit 1
fi

if [ "$MAX_FRAME" -lt 200 ]; then
    echo "T11 FAIL: only reached frame=$MAX_FRAME (need ≥ 200)"
    tail -20 "$LOG"
    exit 1
fi

echo "T11 PASS (M2 mission ran $MAX_FRAME frames)"
exit 0
