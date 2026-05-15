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

RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE}}"
DATA_DIR="${2:-/opt/redalert/game}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra}"
DISPLAY_NUM="${WINE_DISPLAY:-:97}"  # Use :97 to avoid collision with wine-ra.sh (:98)
WINE_WM="${WINE_WM:-openbox}"       # Lightweight WM so Wine gets a managed window for input

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

# Stage from DATA_DIR first
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done

# If a secondary REMASTERED_CD1 is set or autodiscovered, overlay its files for
# any that are missing in DATA_DIR (e.g. HIRES1.MIX / LORES1.MIX which the OG
# install at /opt/redalert/game lacks but the remastered CD1 ships).
REMASTERED_CD1="${REMASTERED_CD1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
if [[ -d "$REMASTERED_CD1" ]]; then
    for f in "$REMASTERED_CD1"/*.MIX; do
        [[ -e "$f" ]] || continue
        local_name="$(basename "$f")"
        [[ -e "$RA_STAGE/$local_name" ]] || ln -sf "$f" "$RA_STAGE/$local_name"
    done
fi

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
# 800x600 so the Wine Desktop window (640x480 + openbox title bar) fits.
Xvfb "$DISPLAY_NUM" -screen 0 800x600x24 -ac &
XVFB_PID=$!
cleanup_all() {
    kill -9 "$XVFB_PID" 2>/dev/null || true
    rm -rf "$RA_STAGE"
}
trap "cleanup_all" EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# ─── Window Manager ───────────────────────────────────────────────────────────
# A lightweight WM is required so Wine's DirectInput layer attaches to a
# managed window, which in turn allows X11 input events (from xdotool) to
# reach the game's Win32 message queue.

echo "=== Starting $WINE_WM WM ==="
if command -v "$WINE_WM" >/dev/null 2>&1; then
    DISPLAY="$DISPLAY_NUM" "$WINE_WM" &
    WM_PID=$!
    cleanup_all() {
        kill -9 "$WM_PID" 2>/dev/null || true
        kill -9 "$XVFB_PID" 2>/dev/null || true
        rm -rf "$RA_STAGE"
    }
    trap "cleanup_all" EXIT
    sleep 2
    echo "  WM pid=$WM_PID"
else
    echo "  WARN: $WINE_WM not found — input may not reach the game"
    WM_PID=""
fi

# Screenshot helper — uses ffmpeg x11grab because ImageMagick's import on Xvfb
# captures a 1-bit empty PNG (~176 bytes) when no window manager is present.
take_shot() {
    local name="$1"
    local out="$SCREENSHOT_DIR/$name"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
            -i "$DISPLAY_NUM" -frames:v 1 -y "$out" 2>/dev/null \
            && echo "  Screenshot: $out"
    elif command -v import >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" import -window root "$out" 2>/dev/null && echo "  Screenshot: $out (import)"
    else
        echo "  WARN: no screenshot tool (ffmpeg/import) found"
    fi
}

# Find the Wine Desktop window ID (retries for up to $1 seconds).
find_wine_win() {
    local deadline=$(( SECONDS + ${1:-30} ))
    while (( SECONDS < deadline )); do
        local wid
        wid=$(DISPLAY="$DISPLAY_NUM" xdotool search --name "Wine Desktop" 2>/dev/null | tail -1)
        if [[ -n "$wid" ]]; then
            echo "$wid"
            return 0
        fi
        sleep 1
    done
    return 1
}

# Get the (x, y) origin of the Wine Desktop window's client area on screen.
# openbox adds a ~20px title bar; we measure it directly.
wine_win_origin() {
    local wid="$1"
    local geom
    geom=$(DISPLAY="$DISPLAY_NUM" xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || { echo "0 20"; return; }
    local wx wy
    wx=$(echo "$geom" | grep '^X=' | cut -d= -f2)
    wy=$(echo "$geom" | grep '^Y=' | cut -d= -f2)
    echo "${wx:-0} ${wy:-20}"
}

WINE_WIN_ID=""
WIN_OX=0
WIN_OY=20  # fallback: 20px title bar

# xdotool click at game-coordinates (x,y) — offset by the window's screen origin.
xdo_click() {
    local gx="$1" gy="$2"
    local sx=$(( WIN_OX + gx ))
    local sy=$(( WIN_OY + gy ))
    echo "  click game=($gx,$gy) screen=($sx,$sy)"
    DISPLAY="$DISPLAY_NUM" xdotool mousemove "$sx" "$sy" click 1 2>/dev/null || true
    sleep 0.5
}

xdo_key() {
    local key="$1"
    if [[ -n "$WINE_WIN_ID" ]]; then
        DISPLAY="$DISPLAY_NUM" xdotool key --window "$WINE_WIN_ID" "$key" 2>/dev/null || true
    else
        DISPLAY="$DISPLAY_NUM" xdotool key "$key" 2>/dev/null || true
    fi
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

# ─── Step 1: Find Wine Desktop window and resolve click origin ───────────────

echo "  Waiting for Wine Desktop window (up to 30s)..."
WINE_WIN_ID=$(find_wine_win 30) || { echo "FAIL: Wine Desktop window never appeared"; exit 1; }
echo "  Wine Desktop wid=$WINE_WIN_ID"
read WIN_OX WIN_OY < <(wine_win_origin "$WINE_WIN_ID")
echo "  Window origin: ($WIN_OX, $WIN_OY)"
DISPLAY="$DISPLAY_NUM" xdotool windowfocus --sync "$WINE_WIN_ID" 2>/dev/null || true

# ─── Step 1a: Handle CD-ROM dialog if it appears ─────────────────────────────
# The game may show "Please insert a Red Alert CD" if it cannot find required
# data on CD drive D:. Dismiss with Return (OK button). This can appear before
# the DirectSound warning.

echo "  Waiting for game to settle (~5s)..."
sleep 5
take_shot "wine-gameplay-t5.png"

# Dismiss any pending dialog (CD check or first message) with Return.
xdo_key "Return"
sleep 1
xdo_key "Return"
sleep 1

# ─── Step 2: Dismiss DirectSound dialog ──────────────────────────────────────

echo "  Waiting for DirectSound dialog (~5s more)..."
sleep 5
echo "  Dismissing DirectSound warning..."
xdo_key "Return"
sleep 1
xdo_key "Return"
sleep 1

# ─── Step 3: Wait for main menu ──────────────────────────────────────────────

echo "  Waiting for main menu (~5s)..."
sleep 5
take_shot "wine-gameplay-menu.png"

# ─── Step 4: Click New Campaign ──────────────────────────────────────────────
# Main menu button coordinates are relative to the 640×480 game client area.
# "New Campaign" button center: approx game-x=322, game-y=183.

echo "  Clicking New Campaign at game (322, 183)..."
xdo_click 322 183
sleep 2
take_shot "wine-gameplay-after-newgame.png"

# ─── Step 5: Difficulty dialog → Easy/OK ─────────────────────────────────────

echo "  Accepting difficulty dialog at game (470, 244)..."
xdo_click 470 244
sleep 1

# ─── Step 6: Faction dialog → Allied ─────────────────────────────────────────

echo "  Selecting Allied faction at game (258, 268)..."
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
