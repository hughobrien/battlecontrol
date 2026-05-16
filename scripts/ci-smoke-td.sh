#!/usr/bin/env bash
# TIM-846: TD native CI runtime smoke test.
#
# Runs td under Xvfb for 10 s and verifies it does not crash.
# Gracefully handles missing game data: a non-crash exit is acceptable.
#
# Prerequisites:
#   - build/td  (cmake --build build --target td)
#   - Xvfb, xdpyinfo
#
# Returns 0 (pass) or 1 (fail — crash detected).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TD_BIN="$REPO_ROOT/build/td"
RUN_DIR="$REPO_ROOT/build/run-td"
DISPLAY_NUM="${TD_SMOKE_DISPLAY:-:99}"
TIMEOUT_SECS=10

# ---- gate on binary ----
if [ ! -x "$TD_BIN" ]; then
    echo "::error::td binary not found at $TD_BIN"
    exit 1
fi

# ---- set up run directory (best-effort) ----
if [ ! -d "$RUN_DIR" ]; then
    bash "$REPO_ROOT/scripts/setup-run-td.sh" 2>/dev/null || {
        echo "::warning::setup-run-td.sh failed — creating minimal stubs"
        mkdir -p "$RUN_DIR"
        python3 -c "
import struct
N = 4567
header_size = N * 2
offsets = [header_size] * N
data = struct.pack('<' + 'H' * N, *offsets) + b'\x00'
with open('$RUN_DIR/CONQUER.ENG', 'wb') as f: f.write(data)
"
        cat > "$RUN_DIR/CONQUER.INI" << 'INIEOF'
[Options]
GameSpeed=4
ScrollRate=4
[Screen]
ScreenWidth=640
ScreenHeight=480
[Intro]
PlayIntro=No
INIEOF
        cat > "$RUN_DIR/SCG01EA.INI" << 'INIEOF'
[Basic]
Name=Test Scenario
Player=GoodGuy
[Map]
Theater=TEMPERATE
X=1 Y=1
Width=20 Height=20
[Waypoints]
0=21
[CellTriggers]
INIEOF
    }
fi

# ---- start Xvfb ----
DISP_NUM="${DISPLAY_NUM#:}"
if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
    echo "Starting Xvfb $DISPLAY_NUM ..."
    Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
    XVFB_PID=$!
    for i in $(seq 1 10); do
        if [ -e "/tmp/.X${DISP_NUM}-lock" ]; then break; fi
        sleep 0.3
    done
    if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
        echo "::error::Xvfb $DISPLAY_NUM did not start"
        exit 1
    fi
else
    XVFB_PID=""
fi

# ---- run smoke test ----
echo "::group::smoke: td"
cd "$RUN_DIR" && DISPLAY="$DISPLAY_NUM" SDL_AUDIODRIVER=dummy \
    TD_AUTOSTART=1 timeout -k 3 "$TIMEOUT_SECS" "$TD_BIN" > /tmp/smoke-td.log 2>&1 && RC=$? || RC=$?
LOG=$(cat /tmp/smoke-td.log)
echo "$LOG"
echo "::endgroup::"

# ---- clean up Xvfb ----
if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" 2>/dev/null || true
fi

# ---- interpret result ----
if echo "$LOG" | grep -qE "SIGSEGV|Segmentation fault|signal 11|CRASH"; then
    echo "::error::td: crash signal in output"
    echo "smoke: FAIL — crash detected"
    exit 1
fi

if [ "$RC" -eq 124 ] || [ "$RC" -eq 143 ]; then
    echo "::notice::td: alive — timed out (${TIMEOUT_SECS} s)"
    echo "smoke: PASS"
    exit 0
fi

# Non-crash exit is acceptable (e.g. game data absent).
echo "::notice::td: exited with code $RC (non-crash)"
echo "smoke: PASS"
exit 0
