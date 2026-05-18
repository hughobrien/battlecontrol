#!/usr/bin/env bash
# TIM-711 — Wine setup and OG C&C Tiberian Dawn launcher for baseline comparison.
#
# Runs the original Windows C&C95.EXE under Wine with a headless Xvfb display,
# dismisses the DirectDraw/DirectSound warning dialog, captures screenshots,
# and prints key diagnostic markers for automated comparison tests.
#
# ─── Verified environment ────────────────────────────────────────────────────
# Host: Debian Bookworm (Debian 13), x86_64
# Wine: 11.0 (Nix wow64), wine-11.0
# C&C95.EXE: 1,161,216 bytes (C&C Gold Win95 port, from command-aand-conquer-gold)
# Data: /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/ (23 MIX files)
#
# Notes:
#   - Wine 11.0 (wow64) does NOT support WINEARCH=win32 — removed from all cmds.
#   - Uses GDI renderer + virtual desktop + 8-bit Xvfb for TD's DirectDraw.
#   - CONQUER.INI disables hardware blits for Wine compatibility.
#   - Title→menu transition may require GL context (same as RA).
#
# ─── Prerequisites ──────────────────────────────────────────────────────────
# Requires:
#   - Wine (provided by nix develop shell)
#   - C&C95.EXE at TD_EXE_PATH or first argument
#   - TD game data at TD_ASSETS (default: /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1)
#   - Stub THIPX32.DLL at tools/stub-thipx/thipx32.dll
#
# See bash scripts/wine-td-setup.sh for C&C95.EXE download instructions.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-td.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to C&C95.EXE     (default: TD_EXE_PATH env var)
#    DATA_DIR        CD1 data directory    (default: TD_ASSETS env var)
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

# Argument defaults: explicit arg → env var → error
CC95_EXE_PATH="${1:-${CC95_EXE_PATH:-}}"
if [[ -z "$CC95_EXE_PATH" ]] || [[ ! -f "$CC95_EXE_PATH" ]]; then
  echo "ERROR: C&C95.EXE not found."
  echo "  Pass as first argument, set TD_EXE_PATH, or download manually."
  echo "  See: bash scripts/wine-td-setup.sh"
  exit 1
fi

DATA_DIR="${2:-${TD_ASSETS:-}}"
if [[ -z "$DATA_DIR" ]]; then
  echo "ERROR: TD game data directory not found."
  echo "  Pass as second argument or set TD_ASSETS."
  exit 1
fi

SCREENSHOT_DIR="${3:-e2e/screenshots}"
DISPLAY_NUM="${WINE_DISPLAY:-:99}"

mkdir -p "$SCREENSHOT_DIR"

# ─── Preflight checks ────────────────────────────────────────────────────────

echo "=== Wine TD preflight ==="

if ! command -v wine >/dev/null 2>&1; then
	echo "FAIL: wine not found. Run from nix develop shell."
	exit 1
fi
WINE_VER=$(wine --version 2>/dev/null || echo "unknown")
echo "  wine: $WINE_VER"

if wine --version 2>&1 | grep -q "wine32 is missing"; then
	echo "FAIL: wine32 is missing."
	echo "  Fix: run from nix develop shell."
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

# ─── Ephemeral WINEPREFIX + staging ──────────────────────────────────────────

echo "=== Wine staging ==="

# Create ephemeral prefix under /tmp (no /opt, no $HOME/.wine-td)
WINE_PREFIX="$(mktemp -d /tmp/wine-td-XXXXXX)"

# Stage directory inside the prefix
TD_STAGE="$WINE_PREFIX/drive_c/game"
mkdir -p "$TD_STAGE"

# Initialize the prefix
echo "  Prefix: $WINE_PREFIX"
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null

# Configure Wine virtual desktop (640x400) and GDI renderer
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Explorer\Desktops' \
  /v Default /t REG_SZ /d "640x400" /f >/dev/null 2>&1 || true
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Direct3D' \
  /v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true

# Link MIX data into staging
echo "  Linking data: $DATA_DIR"
for f in "$DATA_DIR"/*.MIX; do
  [[ -e "$f" ]] && ln -sf "$f" "$TD_STAGE/$(basename "$f")"
done

# Copy EXE into staging
cp "$CC95_EXE_PATH" "$TD_STAGE/C&C95.EXE"

# Use stub THIPX32.DLL (no /opt/tiberiandawn fallback)
STUB_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/stub-thipx"
if [[ -f "$STUB_DIR/thipx32.dll" ]]; then
  cp "$STUB_DIR/thipx32.dll" "$TD_STAGE/THIPX32.DLL"
fi

# CONQUER.INI: disable hardware blits
cat >"$TD_STAGE/CONQUER.INI" <<'INIEOF'
[Options]
HardwareFills=0
VideoBackBuffer=0
Compatibility=1
VideoBackBufferAllowed=0
AllowHardwareBlitFills=0
ScreenHeight=400
INIEOF

echo "  Staging: $TD_STAGE"
echo ""

# ─── Xvfb ────────────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x400x8 -ac &
XVFB_PID=$!
cleanup_xvfb() { kill -9 "$XVFB_PID" 2>/dev/null || true; }
trap 'rm -rf "$WINE_PREFIX"; cleanup_xvfb' EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# ─── Launch C&C95.EXE ────────────────────────────────────────────────────────

echo "=== Launching C&C95.EXE ==="
LOG="$(mktemp /tmp/wine-td-XXXXXX.log)"
(
	cd "$TD_STAGE"
	DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" \
		WINEDEBUG=-all AUDIODEV=null \
		WINEDLLOVERRIDES="winealsa.drv=,wineoss.drv=,winemac.drv=" \
		timeout 45 wine "C&C95.EXE"
) >"$LOG" 2>&1 &
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

# Wait for game to initialize after dialog, then capture menu.
sleep 8
take_screenshot "$SCREENSHOT_DIR/wine-td-menu.png"

kill "$TD_PID" 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "  wine-td-title.png: $(test -f "$SCREENSHOT_DIR/wine-td-title.png" && stat -c '%s (written)' "$SCREENSHOT_DIR/wine-td-title.png" || echo "MISSING")"
echo "  wine-td-menu.png:  $(test -f "$SCREENSHOT_DIR/wine-td-menu.png" && stat -c '%s (written)' "$SCREENSHOT_DIR/wine-td-menu.png" || echo "MISSING")"

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
echo "    WINE_TD_READY=1 playwright test e2e/tim711-td-compare.spec.ts --grep 'Tier 3'"
