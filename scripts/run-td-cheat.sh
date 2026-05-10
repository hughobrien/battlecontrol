#!/usr/bin/env bash
# TIM-360: TD debug-cheat smoke test.
#
# Runs TiberiaDawn under Xvfb with TD_AUTOSTART=1 TD_CHEAT=1 and verifies:
#   frame 30  → +10000 credits
#   frame 35  → Debug_Cheat=true, 3 nuke pieces (tech-level 98)
#   frame 40  → Debug_Unshroud=true (map revealed)
#   frame 200 → Flag_To_Win fired (debrief sequence)
#
# Prerequisites:
#   - build/cmake-td/td binary (run cmake + ninja td first)
#   - build/run-td/ data dir (run scripts/setup-run-td.sh first)
#   - Xvfb, xdpyinfo
#
# Run from repo root:
#   bash scripts/run-td-cheat.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/cmake-td"
RUN_DIR="$REPO_ROOT/build/run-td"
TD_BIN="$BUILD_DIR/td"
DISPLAY_NUM="${TD_DISPLAY:-:99}"
TIMEOUT_SECS=90
LOG="$RUN_DIR/td-cheat-run.log"

# ---- prerequisites ----
if [ ! -x "$TD_BIN" ]; then
    echo "ERROR: $TD_BIN not found. Build with:" >&2
    echo "  mkdir -p build/cmake-td && cd build/cmake-td && cmake ../.. -G Ninja && ninja td" >&2
    exit 1
fi

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: $RUN_DIR not found. Run scripts/setup-run-td.sh first." >&2
    exit 1
fi

# ---- Xvfb ----
DISP_NUM="${DISPLAY_NUM#:}"
if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
    echo "Starting Xvfb $DISPLAY_NUM ..."
    Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 &
    XVFB_PID=$!
    sleep 1
    if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
        echo "ERROR: Xvfb $DISPLAY_NUM did not start." >&2
        exit 1
    fi
else
    echo "Xvfb $DISPLAY_NUM already running."
    XVFB_PID=""
fi

# ---- run ----
echo "Running TD cheat smoke test (timeout ${TIMEOUT_SECS}s) ..."
cd "$RUN_DIR"
TD_AUTOSTART=1 TD_CHEAT=1 DISPLAY="$DISPLAY_NUM" \
    timeout -k 5 "$TIMEOUT_SECS" "$TD_BIN" >"$LOG" 2>&1 || true

if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" 2>/dev/null || true
fi

echo "--- run log (last 40 lines) ---"
tail -40 "$LOG"
echo "--- end log ---"
echo ""

# ---- verify ----
PASS=1

check() {
    local label="$1"; local pattern="$2"
    if grep -q "$pattern" "$LOG"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (pattern: '$pattern' not found)"
        PASS=0
    fi
}

check "smoke milestone (≥10 frames)"       "\[TD\] Main_Loop frame 10"
check "credits grant (frame 30)"           "\[TD-CHEAT\] frame 30: +10000 credits"
check "tech-level 98 (frame 35)"           "\[TD-CHEAT\] frame 35: Debug_Cheat=true"
check "map revealed (frame 40)"            "\[TD-CHEAT\] frame 40: Debug_Unshroud=true"
check "win sequence fired (frame 200)"     "\[TD-CHEAT\] frame 200: Flag_To_Win fired"

echo ""
if [ "$PASS" -eq 1 ]; then
    echo "RESULT: PASS — all cheat milestones reached."
    exit 0
else
    echo "RESULT: FAIL — one or more milestones missing (see log: $LOG)"
    exit 1
fi
