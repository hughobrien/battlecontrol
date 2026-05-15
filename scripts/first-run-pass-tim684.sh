#!/usr/bin/env bash
# TIM-684: Native Linux mouse click smoke test.
#
# Verifies that real mouse clicks register on main menu buttons in the
# native Linux build.  Requires xdotool and xvfb; game data at RUN_DIR.
#
# Root cause (fixed here): Main_Menu's event loop called Wait_Vert_Blank()
# (which drains SDL events into the _Kbd ring) only when display=true.
# After the first render, display=false and no further event pumping
# occurred, so SDL mouse events never reached GadgetClass::Input().
#
# Fix: add Wait_Vert_Blank() in the display=false else-branch of the
# Main_Menu loop so events are pumped every iteration.
#
# ACCEPTANCE CRITERIA:
#   1. Binary links and starts without crash
#   2. Main menu appears ([TIM-616] menu_cs= logged)
#   3. xdotool click at (322, 183) triggers New Campaign button
#   4. [MENU] input= log line confirms gadget received the click
#
# RA_SKIP_INTRO=1 skips ENGLISH.VQA and PROLOG.VQA so the menu appears
# in ~2s instead of ~200s.  This env var does NOT bypass the menu itself
# (unlike RA_AUTOSTART) — real mouse input is required to proceed.
#
# Run from repo root:
#   bash scripts/first-run-pass-tim684.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RA_BIN="$BUILD_DIR/ra"
RUN_DIR="$BUILD_DIR/run-490"  # game data directory (symlink or real)
PASS_DIR="$BUILD_DIR/first-run-pass-tim684"
LOG="$PASS_DIR/run.log"
DISPLAY_NUM=98

mkdir -p "$PASS_DIR"

echo "=== TIM-684: Native Linux mouse click smoke test ==="
echo "Binary: $RA_BIN"
echo "Data:   $RUN_DIR"

if [[ ! -f "$RA_BIN" ]]; then
    echo "FAIL: binary not found — run: cmake --preset linux-native && cmake --build build --target ra"
    exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
    echo "SKIP: $RUN_DIR not found — game data missing"
    exit 0
fi

if ! command -v xdotool >/dev/null 2>&1; then
    echo "SKIP: xdotool not found — install with: apt-get install xdotool"
    exit 0
fi

# Clean up previous Xvfb on this display
pkill -f "Xvfb :$DISPLAY_NUM" 2>/dev/null || true
sleep 0.3

Xvfb :$DISPLAY_NUM -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 0.8

(cd "$RUN_DIR" && DISPLAY=:$DISPLAY_NUM SDL_AUDIODRIVER=dummy RA_SKIP_INTRO=1 \
    timeout 60 "$RA_BIN") > "$LOG" 2>&1 &
RA_PID=$!

echo "Waiting for main menu ([TIM-616] menu_cs=)..."
MENU_READY=0
for i in $(seq 1 30); do
    if grep -q "\[TIM-616\] menu_cs=" "$LOG" 2>/dev/null; then
        MENU_READY=1
        echo "Menu ready after ${i}s"
        break
    fi
    sleep 1
done

if [[ $MENU_READY -eq 0 ]]; then
    echo "FAIL: menu_cs= not seen after 30s"
    echo "--- Log tail ---"
    tail -20 "$LOG"
    kill $RA_PID 2>/dev/null; kill $XVFB_PID 2>/dev/null
    exit 1
fi

sleep 0.5

WINDOW_ID=$(DISPLAY=:$DISPLAY_NUM xdotool search --name "Red Alert" 2>/dev/null | head -1)
echo "Window ID: $WINDOW_ID"

if [[ -z "$WINDOW_ID" ]]; then
    echo "FAIL: could not find Red Alert window"
    kill $RA_PID 2>/dev/null; kill $XVFB_PID 2>/dev/null
    exit 1
fi

# Click the "New Campaign" button at (322, 183) — confirmed by TIM-649 button layout.
echo "Clicking New Campaign at (322, 183)..."
DISPLAY=:$DISPLAY_NUM xdotool mousemove --window "$WINDOW_ID" 322 183
sleep 0.2
DISPLAY=:$DISPLAY_NUM xdotool click --window "$WINDOW_ID" 1

# Wait for menu input to register
CLICKED=0
for i in $(seq 1 10); do
    sleep 1
    if grep -q "\[MENU\] input=" "$LOG" 2>/dev/null; then
        CLICKED=1
        echo "Click registered after ${i}s"
        break
    fi
done

kill $RA_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true
wait $RA_PID 2>/dev/null || true

echo ""
echo "--- TIM-684 click evidence ---"
grep "\[MENU\] input=" "$LOG" | head -5 || echo "(none)"

echo ""
echo "--- Crash check ---"
grep -E "SIGSEGV|Segmentation|Aborted" "$LOG" | head -5 || echo "(none)"

echo ""
echo "--- Analysis ---"
python3 - "$LOG" <<'PYEOF'
import sys, re

log = open(sys.argv[1], errors='replace').read()
lines = log.splitlines()

menu_ready = '[TIM-616] menu_cs=' in log
click_received = '[MENU] input=' in log
input_lines = [l for l in lines if '[MENU] input=' in l]
crash = bool(re.search(r'SIGSEGV|Segmentation|Aborted', log))

print(f"Criterion 1 (binary started + menu appeared): {'PASS' if menu_ready else 'FAIL'}")
print(f"Criterion 2 (xdotool click registered):        {'PASS' if click_received else 'FAIL'}")
print(f"Criterion 3 (no crash):                        {'PASS' if not crash else 'FAIL'}")
if input_lines:
    for l in input_lines[:3]:
        print(f"  {l.strip()}")

all_pass = menu_ready and click_received and not crash
print()
if all_pass:
    print("=== ALL CRITERIA MET: TIM-684 PASS ===")
else:
    print("=== CRITERIA FAILED — see above ===")
PYEOF

if grep -q "TIM-684 PASS" "$PASS_DIR/../first-run-pass-tim684/run.log" 2>/dev/null || \
   python3 -c "
import sys, re
log = open('$LOG', errors='replace').read()
ok = '[TIM-616] menu_cs=' in log and '[MENU] input=' in log and not re.search(r'SIGSEGV|Aborted', log)
sys.exit(0 if ok else 1)
"; then
    echo "Exit: PASS"
    exit 0
else
    echo "Exit: FAIL"
    exit 1
fi
