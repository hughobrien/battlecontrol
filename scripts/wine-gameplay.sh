#!/usr/bin/env bash
# TIM-705 — Wine OG Red Alert Allied L1 gameplay screenshot capture.
#
# Launches RA95.EXE under Xvfb, navigates to Allied Mission 1 via xdotool,
# and captures timed screenshots at t=0, t=5, t=30, t=60, t=120 seconds
# in-game.
#
# ─── Prerequisites ───────────────────────────────────────────────────────────
# Same as wine-ra.sh: wine32, RA95.EXE at /opt/redalert/RA95.EXE, MAIN.MIX
# in DATA_DIR, xdotool, ImageMagick (import or scrot).
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-gameplay.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to RA95.EXE     (default: /opt/redalert/RA95.EXE)
#    DATA_DIR        CD1 data directory   (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
#    SCREENSHOT_DIR  output dir           (default: e2e/screenshots)
#
# ─── Outputs ─────────────────────────────────────────────────────────────────
# wine-allied-l1-t0.png   — immediately after mission load (~mission start)
# wine-allied-l1-t5.png   — t+5s
# wine-allied-l1-t30.png  — t+30s
# wine-allied-l1-t60.png  — t+60s
# wine-allied-l1-t120.png — t+120s
#
# ─── Wine menu navigation ────────────────────────────────────────────────────
# The OG game's 640×480 menu layout matches the port (same resolution).
# Navigation path from main menu → Allied L1:
#   1. Dismiss DirectSound dialog (Enter)
#   2. Wait ~5s for main menu
#   3. Click "New Campaign" button — approximately (322, 183) in 640×480 coords
#      Mapped to screen: depends on Xvfb window placement.
#      With Xvfb 640×480, game is full screen → coordinates are literal.
#   4. Difficulty dialog: click OK/Easy at approx (470, 244)
#   5. Faction dialog: click Allied at approx (258, 268)
#   6. Wait for briefing VQA to finish (~15s for ALLIES.VQA)
#   7. Mission start — capture t=0 screenshot
#   8. Wait 5s → t=5 screenshot
#   9. Wait 25s → t=30 screenshot
#  10. Wait 30s → t=60 screenshot
#  11. Wait 60s → t=120 screenshot
#
# ─── Known behavior ──────────────────────────────────────────────────────────
# • DirectSound dialog appears ~6s after launch — dismiss with Enter
# • Menu animations take ~3s after dialog dismiss
# • Briefing VQA (ALLIES1.VQA) runs for ~8-12s
# • Mission load adds ~5s
# • Xvfb 640×480 means the game occupies the full Xvfb display
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/RA95.EXE}}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra}"
DISPLAY_NUM="${WINE_DISPLAY:-:97}"  # Use :97 to avoid collision with wine-ra.sh (:98)

mkdir -p "$SCREENSHOT_DIR"

# ─── Preflight ───────────────────────────────────────────────────────────────

echo "=== Wine gameplay preflight ==="
if ! command -v wine >/dev/null 2>&1; then
    echo "FAIL: wine not found"; exit 1
fi
if [[ ! -f "$RA_EXE_PATH" ]]; then
    echo "SKIP: RA95.EXE not found at $RA_EXE_PATH"
    echo "  Run: bash scripts/wine-ra-setup.sh"
    exit 2
fi
if [[ ! -d "$DATA_DIR" ]]; then
    echo "FAIL: data directory not found: $DATA_DIR"; exit 1
fi
if ! command -v xdotool >/dev/null 2>&1; then
    echo "FAIL: xdotool not found — install with: sudo apt-get install xdotool"; exit 1
fi

WINE_VER=$(wine --version 2>/dev/null || echo "unknown")
echo "  wine: $WINE_VER"
echo "  exe:  $RA_EXE_PATH"
echo "  data: $DATA_DIR"
echo "  out:  $SCREENSHOT_DIR"
echo "  display: $DISPLAY_NUM"
echo ""

# ─── Stage ───────────────────────────────────────────────────────────────────

RA_STAGE="$(mktemp -d)"
trap "rm -rf $RA_STAGE" EXIT
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$RA_STAGE/RA95.EXE"
THIPX_DIR="$(dirname "$RA_EXE_PATH")"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$THIPX_DIR/$dll" ]] && cp "$THIPX_DIR/$dll" "$RA_STAGE/$dll"
done

if [[ ! -d "$WINE_PREFIX" ]]; then
    echo "Creating 32-bit Wine prefix..."
    WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 WINEDEBUG=-all wineboot --init 2>/dev/null
fi

# ─── Xvfb ────────────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
XVFB_PID=$!
cleanup_all() {
    kill -9 "$XVFB_PID" 2>/dev/null || true
    rm -rf "$RA_STAGE"
}
trap "cleanup_all" EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# Screenshot helper
take_shot() {
    local name="$1"
    local out="$SCREENSHOT_DIR/$name"
    if command -v import >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" import -window root "$out" 2>/dev/null && echo "  Screenshot: $out"
    elif command -v scrot >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" scrot "$out" 2>/dev/null && echo "  Screenshot: $out"
    else
        echo "  WARN: no screenshot tool (import/scrot) found"
    fi
}

# xdotool click at (x,y) relative to screen
xdo_click() {
    local x="$1" y="$2"
    DISPLAY="$DISPLAY_NUM" xdotool mousemove "$x" "$y" click 1 2>/dev/null || true
    sleep 0.5
}

xdo_key() {
    DISPLAY="$DISPLAY_NUM" xdotool key "$1" 2>/dev/null || true
    sleep 0.3
}

# ─── Launch RA ───────────────────────────────────────────────────────────────

echo "=== Launching RA95.EXE ==="
LOG="$(mktemp /tmp/wine-gameplay-XXXXXX.log)"
(
    cd "$RA_STAGE"
    DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 \
    WINEDEBUG=-all AUDIODEV=null \
    timeout 180 wine RA95.EXE
) > "$LOG" 2>&1 &
RA_PID=$!
trap "kill $RA_PID 2>/dev/null || true; cleanup_all" EXIT

# ─── Step 1: Dismiss DirectSound dialog ──────────────────────────────────────

echo "  Waiting for DirectSound dialog (~7s)..."
sleep 7
echo "  Dismissing DirectSound warning..."
xdo_key "Return"
sleep 1
xdo_key "Return"
sleep 1

# ─── Step 2: Wait for main menu ──────────────────────────────────────────────

echo "  Waiting for main menu (~5s)..."
sleep 5
take_shot "wine-gameplay-menu.png"

# ─── Step 3: Click New Campaign ──────────────────────────────────────────────

echo "  Clicking New Campaign at (322, 183)..."
xdo_click 322 183
sleep 2

# ─── Step 4: Difficulty dialog → Easy/OK ─────────────────────────────────────

echo "  Accepting difficulty dialog at (470, 244)..."
xdo_click 470 244
sleep 1

# ─── Step 5: Faction dialog → Allied ─────────────────────────────────────────

echo "  Selecting Allied faction at (258, 268)..."
xdo_click 258 268
sleep 1

# ─── Step 6: Wait for briefing VQA + mission load ────────────────────────────

echo "  Waiting for briefing VQA and mission load (~30s)..."
sleep 30

# ─── Step 7: t=0 screenshot ──────────────────────────────────────────────────

MISSION_START_TIME="$SECONDS"
take_shot "wine-allied-l1-t0.png"
echo "  Mission started at t=${SECONDS}s"

# ─── Step 8: t=5s ────────────────────────────────────────────────────────────

sleep 5
take_shot "wine-allied-l1-t5.png"

# ─── Step 9: t=30s ───────────────────────────────────────────────────────────

sleep 25
take_shot "wine-allied-l1-t30.png"

# ─── Step 10: t=60s ──────────────────────────────────────────────────────────

sleep 30
take_shot "wine-allied-l1-t60.png"

# ─── Step 11: t=120s ─────────────────────────────────────────────────────────

sleep 60
take_shot "wine-allied-l1-t120.png"

kill "$RA_PID" 2>/dev/null || true

# ─── Results ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Results ==="
PASS=0
TOTAL=0
for name in wine-gameplay-menu wine-allied-l1-t0 wine-allied-l1-t5 wine-allied-l1-t30 wine-allied-l1-t60 wine-allied-l1-t120; do
    shot="$SCREENSHOT_DIR/${name}.png"
    TOTAL=$((TOTAL+1))
    if [[ -f "$shot" ]]; then
        sz=$(stat -c%s "$shot")
        if [[ $sz -gt 5000 ]]; then
            echo "  OK   ${name}.png ($sz bytes)"
            PASS=$((PASS+1))
        else
            echo "  WARN ${name}.png is small ($sz bytes) — may be blank"
        fi
    else
        echo "  MISS ${name}.png — not captured"
    fi
done

echo ""
echo "Captured $PASS/$TOTAL screenshots in $SCREENSHOT_DIR"

if [[ $PASS -ge 4 ]]; then
    echo "RESULT: PASS ($PASS/$TOTAL screenshots captured)"
    exit 0
else
    echo "RESULT: FAIL (only $PASS/$TOTAL screenshots captured)"
    exit 1
fi
