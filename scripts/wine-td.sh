#!/usr/bin/env bash
# TIM-711 — Wine setup and OG C&C Tiberian Dawn launcher for baseline comparison.
#
# Runs the original Windows C&C95.EXE under Wine with a headless Xvfb display,
# dismisses the DirectDraw/DirectSound warning dialog, captures screenshots,
# and prints key diagnostic markers for automated comparison tests.
#
# ─── Verified environment ────────────────────────────────────────────────────
# Host: Debian Bookworm (Debian 13), x86_64
# Wine: 10.0 (Debian 10.0~repack-6), wine64 + wine32:i386
# C&C95.EXE: 1,161,216 bytes (C&C Gold Win95 port, from command-aand-conquer-gold)
# Data: /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/ (23 MIX files)
#
# ─── First-time setup ────────────────────────────────────────────────────────
# Run this once to get all prerequisites:
#   bash scripts/wine-td-setup.sh
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-td.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to C&C95.EXE     (default: /opt/tiberiandawn/C&C95.EXE)
#    DATA_DIR        CD1 data directory    (default: /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1)
#    SCREENSHOT_DIR  output dir            (default: e2e/screenshots)
#
# ─── Outputs ─────────────────────────────────────────────────────────────────
#    $SCREENSHOT_DIR/wine-td-title.png   — after dialog dismissed (~10s)
#    $SCREENSHOT_DIR/wine-td-menu.png    — menu state (~20s)
#
# ─── CI integration ──────────────────────────────────────────────────────────
#    Set WINE_TD_READY=1 when wine32 + C&C95.EXE are present and verified.
#    Playwright tests in e2e/tim711-td-compare.spec.ts Tier 3 skip unless set.

set -euo pipefail

CC95_EXE_PATH="${1:-${CC95_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
SCREENSHOT_DIR="${3:-e2e/screenshots}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-td}"
DISPLAY_NUM="${WINE_DISPLAY:-:99}"

mkdir -p "$SCREENSHOT_DIR"

# ─── Preflight checks ────────────────────────────────────────────────────────

echo "=== Wine TD preflight ==="

if ! command -v wine >/dev/null 2>&1; then
    echo "FAIL: wine not found. Install with: sudo apt-get install wine"
    exit 1
fi
WINE_VER=$(wine --version 2>/dev/null || echo "unknown")
echo "  wine: $WINE_VER"

if wine --version 2>&1 | grep -q "wine32 is missing"; then
    echo "FAIL: wine32 is missing."
    echo "  Fix: sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install wine32:i386"
    exit 1
fi

if [[ ! -f "$CC95_EXE_PATH" ]]; then
    echo "SKIP: C&C95.EXE not found at $CC95_EXE_PATH"
    echo "  Run: bash scripts/wine-td-setup.sh"
    exit 2
fi

if [[ ! -d "$DATA_DIR" ]]; then
    echo "FAIL: data directory not found: $DATA_DIR"
    exit 1
fi

EXE_SHA=$(sha256sum "$CC95_EXE_PATH" | awk '{print $1}')
echo "  exe:  $CC95_EXE_PATH (sha256=$EXE_SHA)"
echo "  data: $DATA_DIR"
echo ""

# ─── Wine prefix + staging ───────────────────────────────────────────────────

echo "=== Wine staging ==="
TD_STAGE="$(mktemp -d)"
trap "rm -rf $TD_STAGE" EXIT

# Link MIX data into a temporary staging directory.
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$TD_STAGE/$(basename "$f")"
done
# Symlink EXE into staging (avoids copying 1.2 MB on a space-constrained disk).
ln -sf "$CC95_EXE_PATH" "$TD_STAGE/C&C95.EXE"
# Stage THIPX32.DLL (required by C&C95.EXE; IPX network DLL).
THIPX_SRC="$(dirname "$CC95_EXE_PATH")/THIPX32.DLL"
[[ -f "$THIPX_SRC" ]] && ln -sf "$THIPX_SRC" "$TD_STAGE/THIPX32.DLL"

# CONQUER.INI: disable hardware blits so game stays alive under Wine's GDI path.
cat > "$TD_STAGE/CONQUER.INI" << 'INIEOF'
[Options]
HardwareFills=0
VideoBackBuffer=0
Compatibility=1
VideoBackBufferAllowed=0
AllowHardwareBlitFills=0
ScreenHeight=400
INIEOF

if [[ ! -d "$WINE_PREFIX" ]]; then
    echo "  Creating 32-bit Wine prefix at $WINE_PREFIX..."
    WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 WINEDEBUG=-all wineboot --init 2>/dev/null
fi

# Configure Wine virtual desktop (640x400) and GDI renderer so the game
# window is capturable via ffmpeg x11grab without needing DirectDraw.
WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 WINEDEBUG=-all wine reg add \
    'HKCU\Software\Wine\Explorer\Desktops' \
    /v Default /t REG_SZ /d "640x400" /f >/dev/null 2>&1 || true
WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 WINEDEBUG=-all wine reg add \
    'HKCU\Software\Wine\Direct3D' \
    /v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true

echo "  Staging: $TD_STAGE"
echo ""

# ─── Xvfb ────────────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x400x8 -ac &
XVFB_PID=$!
cleanup_xvfb() { kill -9 "$XVFB_PID" 2>/dev/null || true; }
trap "rm -rf $TD_STAGE; cleanup_xvfb" EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# ─── Launch C&C95.EXE ────────────────────────────────────────────────────────

echo "=== Launching C&C95.EXE ==="
LOG="$(mktemp /tmp/wine-td-XXXXXX.log)"
(
    cd "$TD_STAGE"
    DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 \
    WINEDEBUG=-all AUDIODEV=null \
    WINEDLLOVERRIDES="winealsa.drv=,wineoss.drv=,winemac.drv=" \
    timeout 45 wine "C&C95.EXE"
) > "$LOG" 2>&1 &
TD_PID=$!

# Capture title/menu state using ffmpeg x11grab (works under Wine+Xvfb).
# NOTE: 'import -window root' returns blank 1-bit PNGs under Wine+Xvfb;
#       ffmpeg x11grab captures the actual framebuffer content.
# NOTE: On headless Xvfb without hardware GL, DirectDraw surfaces render
#       through Wine's software path.  The dialog (Win32 GDI) captures at
#       ~3-5 KB; the game screen (DirectDraw) may be blank on Xvfb.
take_screenshot() {
    local out="$1"
    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -f x11grab -video_size 640x400 -i "${DISPLAY_NUM}" \
               -frames:v 1 "$out" -y 2>/dev/null && echo "  Screenshot: $out"
    fi
}

# Wait for DirectDraw/DirectSound warning dialog (~7s).
sleep 7
# Capture title state — dialog is visible here (GDI-rendered, ~3-5 KB).
take_screenshot "$SCREENSHOT_DIR/wine-td-title.png"
echo "  Dismissing dialog..."
DISPLAY="$DISPLAY_NUM" xdotool key Return 2>/dev/null || true
sleep 1
DISPLAY="$DISPLAY_NUM" xdotool key Return 2>/dev/null || true

# Wait for game to initialize after dialog, then capture menu.
sleep 8
take_screenshot "$SCREENSHOT_DIR/wine-td-menu.png"

kill "$TD_PID" 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "  wine-td-title.png: $(test -f "$SCREENSHOT_DIR/wine-td-title.png" && ls -lh "$SCREENSHOT_DIR/wine-td-title.png" | awk '{print $5, "(written)"}' || echo "MISSING")"
echo "  wine-td-menu.png:  $(test -f "$SCREENSHOT_DIR/wine-td-menu.png"  && ls -lh "$SCREENSHOT_DIR/wine-td-menu.png"  | awk '{print $5, "(written)"}' || echo "MISSING")"

for shot in "$SCREENSHOT_DIR/wine-td-title.png" "$SCREENSHOT_DIR/wine-td-menu.png"; do
    if [[ -f "$shot" ]]; then
        sz=$(stat -c%s "$shot")
        if [[ $sz -lt 5000 ]]; then
            echo "  WARN: $shot is only $sz bytes — may be blank"
        else
            echo "  OK: $shot ($sz bytes)"
        fi
    fi
done

echo ""
echo "  To run Tier 3 Playwright comparison tests:"
echo "    WINE_TD_READY=1 npx playwright test e2e/tim711-td-compare.spec.ts --grep 'Tier 3'"
