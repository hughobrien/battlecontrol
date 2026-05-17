#!/usr/bin/env bash
# T12 — TD native M2 smoke test (TIM-861).
#
# Runs the TD native ELF for 120 s under Xvfb :99 with TD_AUTOSTART=1 and
# TD_SCENE=2 (GDI Mission 2), then asserts the log shows ≥ 200 frames and
# zero SIGSEGV / Aborted / CRASH.  Catches M2-specific game-loop regressions.
#
# Prerequisites:
#   build/td — TD native binary (built via cmake --build build --target td)
#   build/run-td/ — TD assets staged
#
# Budget: 120 s. Hard timeout: 150 s.

set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ELF="$REPO_ROOT/build/td"
RUN_DIR="$REPO_ROOT/build/run-td"
OUT_DIR="$REPO_ROOT/e2e/screenshots"
LOG="$OUT_DIR/t12-td-native-m2-smoke.log"
mkdir -p "$OUT_DIR"

if [ ! -x "$ELF" ]; then
	echo "T12 SKIP: $ELF not built (run cmake --build build --target td)"
	exit 77
fi
if [ ! -d "$RUN_DIR" ]; then
	echo "T12 SKIP: $RUN_DIR not staged (run scripts/setup-run-td.sh)"
	exit 77
fi

pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1
trap 'kill -9 "$XVFB_PID" 2>/dev/null || true' EXIT

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy \
	TD_AUTOSTART=1 TD_SCENE=2 \
	timeout 120 "$ELF") >"$LOG" 2>&1
RC=$?
echo "T12 run rc=$RC (124=timeout=alive, 0=clean exit)"

CRASHES=$(grep -c -E "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" || true)
MAX_FRAME=$(grep -aE "frame=[0-9]+" "$LOG" | sed -E 's/.*frame=([0-9]+).*/\1/' | sort -n | tail -1)
MAX_FRAME=${MAX_FRAME:-0}

echo "T12 max_frame=$MAX_FRAME crashes=$CRASHES log=$LOG"

if [ "$CRASHES" -gt 0 ]; then
	echo "T12 FAIL: $CRASHES crash signals detected"
	grep -aE "SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted" "$LOG" | head -3
	exit 1
fi

if [ "$MAX_FRAME" -lt 200 ]; then
	echo "T12 FAIL: only reached frame=$MAX_FRAME (need ≥ 200)"
	tail -20 "$LOG"
	exit 1
fi

echo "T12 PASS (M2 mission ran $MAX_FRAME frames)"
exit 0
