#!/usr/bin/env bash
# TIM-699 — Wine setup and OG Red Alert launcher for side-by-side comparison.
#
# Runs the original Windows REDALERT.EXE under Wine with a headless Xvfb
# display, captures a title-screen screenshot, and prints key diagnostic
# markers for automated comparison tests.
#
# ─── Prerequisites ───────────────────────────────────────────────────────────
# 1. Enable i386 architecture (required for the 32-bit OG binary):
#      sudo dpkg --add-architecture i386
#      sudo apt-get update
#      sudo apt-get install wine32:i386
#
# 2. Obtain REDALERT.EXE — the original 32-bit Windows binary.
#    EA released the original C&C games as free downloads in 2008.
#    The expected path is /opt/redalert/REDALERT.EXE.
#    Alternative: set RA_EXE_PATH env var.
#
#    If you do not have the binary, the script exits with a clear message
#    and exit code 2.  The Wine prefix setup still runs so later reruns
#    are faster.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-ra.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to REDALERT.EXE  (default: /opt/redalert/REDALERT.EXE)
#    DATA_DIR        CD1 data directory    (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
#    SCREENSHOT_DIR  output dir            (default: e2e/screenshots)
#
# ─── Outputs ─────────────────────────────────────────────────────────────────
#    $SCREENSHOT_DIR/wine-ra-title.png    — title screen screenshot
#    $SCREENSHOT_DIR/wine-ra-menu.png     — main menu screenshot (after 8s)
#
# ─── CI integration ──────────────────────────────────────────────────────────
#    This script is tagged WINE — Playwright tests that depend on it should
#    be guarded with:
#      test.skip(!process.env.WINE_RA_READY, 'Wine + REDALERT.EXE required');
#    Set WINE_RA_READY=1 in CI only when wine32 and the EXE are present.

set -euo pipefail

RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/REDALERT.EXE}}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra}"
DISPLAY_NUM="${WINE_DISPLAY:-:98}"

mkdir -p "$SCREENSHOT_DIR"

# ─── Preflight checks ────────────────────────────────────────────────────────

echo "=== Wine RA preflight ==="

if ! command -v wine >/dev/null 2>&1; then
    echo "FAIL: wine not found. Install with: sudo apt-get install wine"
    exit 1
fi
WINE_VER=$(wine --version 2>/dev/null || echo "unknown")
echo "  wine: $WINE_VER"

if ! wine --version 2>&1 | grep -q "wine-"; then
    echo "WARN: wine --version returned unexpected output"
fi

# wine32 check: try running a trivial 32-bit program
if wine hostname 2>&1 | grep -q "wine32 is missing"; then
    echo "FAIL: wine32 is missing."
    echo "  Fix: sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install wine32:i386"
    exit 1
fi

if [[ ! -f "$RA_EXE_PATH" ]]; then
    echo "SKIP: REDALERT.EXE not found at $RA_EXE_PATH"
    echo "  Set RA_EXE_PATH env var or pass path as first argument."
    echo "  The OG Red Alert EXE is available from the EA free 2008 release."
    echo "  Expected location: /opt/redalert/REDALERT.EXE"
    exit 2
fi

if [[ ! -d "$DATA_DIR" ]]; then
    echo "FAIL: data directory not found: $DATA_DIR"
    exit 1
fi

echo "  exe:  $RA_EXE_PATH"
echo "  data: $DATA_DIR"
echo ""

# ─── Wine prefix setup ───────────────────────────────────────────────────────

echo "=== Wine prefix setup ($WINE_PREFIX) ==="
if [[ ! -d "$WINE_PREFIX" ]]; then
    echo "  Creating 32-bit Wine prefix..."
    WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 wineboot --init 2>&1 | tail -5
else
    echo "  Prefix already exists, skipping init."
fi

# Copy game data into a staging directory inside the Wine prefix so the game
# can find its MIX files relative to its own path.
RA_STAGE="$WINE_PREFIX/drive_c/redalert"
mkdir -p "$RA_STAGE"

echo "  Linking MIX data into stage..."
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] || continue
    ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done
# Copy the EXE into the stage directory (Wine needs it there to find DLLs).
cp "$RA_EXE_PATH" "$RA_STAGE/REDALERT.EXE"

echo ""

# ─── Xvfb setup ──────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1
echo "  Xvfb pid=$XVFB_PID"

cleanup() {
    kill -9 "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Run REDALERT.EXE under Wine ─────────────────────────────────────────────

echo "=== Running REDALERT.EXE under Wine (5s, title screen) ==="
(
    cd "$RA_STAGE"
    DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" \
    WINEDEBUG=+module,+loaddll \
    timeout 10 wine REDALERT.EXE -NORUN 2>&1 &
    WINE_PID=$!
    sleep 5
    # Capture title screen
    if command -v import >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" import -window root \
            "$SCREENSHOT_DIR/wine-ra-title.png" 2>/dev/null && \
            echo "  Screenshot: $SCREENSHOT_DIR/wine-ra-title.png"
    elif command -v scrot >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" scrot "$SCREENSHOT_DIR/wine-ra-title.png" && \
            echo "  Screenshot: $SCREENSHOT_DIR/wine-ra-title.png"
    else
        echo "  WARN: no screenshot tool (import/scrot) — skipping screenshot"
    fi
    sleep 3
    # Capture menu state
    if command -v import >/dev/null 2>&1; then
        DISPLAY="$DISPLAY_NUM" import -window root \
            "$SCREENSHOT_DIR/wine-ra-menu.png" 2>/dev/null && \
            echo "  Menu screenshot: $SCREENSHOT_DIR/wine-ra-menu.png"
    fi
    kill "$WINE_PID" 2>/dev/null || true
) || true

echo ""
echo "=== Done ==="
echo "  wine-ra-title.png: $(test -f "$SCREENSHOT_DIR/wine-ra-title.png" && echo "WRITTEN" || echo "MISSING")"
echo "  wine-ra-menu.png:  $(test -f "$SCREENSHOT_DIR/wine-ra-menu.png" && echo "WRITTEN" || echo "MISSING")"
