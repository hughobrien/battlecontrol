#!/usr/bin/env bash
# TIM-699 — Wine setup and OG Red Alert launcher for side-by-side comparison.
#
# Runs the original Windows Red Alert (RA95.EXE) under Wine with a headless
# Xvfb display, dismisses the DirectSound warning dialog, captures screenshots,
# and prints key diagnostic markers for automated comparison tests.
#
# ─── Verified environment ────────────────────────────────────────────────────
# Host: Debian Bookworm (Debian 13), x86_64
# Wine: 11.0 (Nix wow64), wine-11.0 (Debian 10.0~repack-6 also tested)
# RA95.EXE: from cnc-red-alert Allied ISO at archive.org (SHA-256 below)
#   Original SHA: a95e2ac8...  (stored as RA95.EXE.orig)
#   Patched SHA:  c9e9be01...  (cnc-ddraw compatible, better rendering)
# Data: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX (454 MB)
#
# Notes:
#   - Wine 11.0 (wow64) does NOT support WINEARCH=win32 — removed from all cmds.
#   - THIPX32.DLL (original) fails under wow64 due to 16-bit THIPX16.DLL thunk.
#     A stub THIPX32.DLL (tools/stub-thipx/) replaces it automatically.
#   - DirectDraw renders blank on Xvfb without GPU — GDI renderer + virtual
#     desktop registry settings are applied before launch.
#   - Title→menu transition requires a hardware GL context; only the title
#     screen is captured reliably under Xvfb.
# Result: game launches to title screen (~4266 bytes, 8-bit sRGB)
#
# ─── Prerequisites ──────────────────────────────────────────────────────────
# Requires:
#   - Wine (provided by nix develop shell)
#   - RA95.EXE (auto-resolved from Nix store via .#ra-patched-exe)
#   - RA game data at RA_ASSETS (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
#   - Stub THIPX32.DLL at tools/stub-thipx/thipx32.dll
#
# Run this once to install stub THIPX32.DLL:
#   bash scripts/build-stub-thipx.sh tools/stub-thipx
#
# ─── Known behavior under Wine ───────────────────────────────────────────────
# • DirectSound warning: "Warning - Unable to create Direct Sound Object"
#   This dialog appears because there is no physical audio card on CI.
#   We dismiss it with a single xdotool key Return. The game then shows
#   the title screen (~4266 bytes, 8-bit sRGB, ~277 unique colors).
# • Title→menu transition requires a hardware GL context. Under Xvfb without
#   a GPU, the menu screenshot will match the title screen.
# • THIPX32.DLL (original): Uses 16-bit thunking to THIPX16.DLL which is NOT
#   supported by Wine 11.0 wow64. A stub DLL (tools/stub-thipx/) is used.
# • ALSA errors in stderr: expected (no audio card), not game failures.
# • Display: RA renders at 640×480 windowed within the Xvfb screen.
#   The title screen is a dark navy/black background with the Westwood logo.
# • No CD check: the game reads MAIN.MIX from the current directory.
# • The GDI renderer is forced (DirectDrawRenderer=gdi) so the DirectDraw
#   surfaces render via Wine's software path rather than requiring OpenGL.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-ra.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to RA95.EXE     (default: Nix store ra-patched-exe)
#    DATA_DIR        CD1 data directory   (default: RA_ASSETS env var)
#    SCREENSHOT_DIR  output dir           (default: e2e/screenshots)
#
# ─── Outputs ─────────────────────────────────────────────────────────────────
#    $SCREENSHOT_DIR/wine-ra-title.png   — after dialog dismissed (~10s)
#    $SCREENSHOT_DIR/wine-ra-menu.png    — menu state (~20s)
#
# ─── CI integration ──────────────────────────────────────────────────────────
#    Set WINE_RA_READY=1 when wine32 + RA95.EXE are present and verified.
#    Playwright tests in e2e/tim699-ra-compare.spec.ts Tier 3 skip unless set.

set -euo pipefail

# Argument defaults: explicit arg → env var → Nix store → error
RA_EXE_PATH="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE_PATH" ]]; then
  RA_EXE_PATH=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE_PATH" ]] || [[ ! -f "$RA_EXE_PATH" ]]; then
  echo "ERROR: RA95.EXE not found."
  echo "  Pass as first argument, set RA_EXE_PATH, or run from nix develop."
  exit 1
fi

DATA_DIR="${2:-${RA_ASSETS:-}}"
if [[ -z "$DATA_DIR" ]]; then
  echo "ERROR: RA game data directory not found."
  echo "  Pass as second argument or set RA_ASSETS."
  exit 1
fi

SCREENSHOT_DIR="${3:-e2e/screenshots}"
DISPLAY_NUM="${WINE_DISPLAY:-:98}"

mkdir -p "$SCREENSHOT_DIR"

# ─── Preflight checks ────────────────────────────────────────────────────────

echo "=== Wine RA preflight ==="

if ! command -v wine >/dev/null 2>&1; then
	echo "FAIL: wine not found. Run from nix develop shell."
	exit 1
fi
WINE_VER=$(wine --version 2>/dev/null || echo "unknown")
echo "  wine: $WINE_VER"

# wine32 check: fail gracefully if 32-bit support is missing
if wine --version 2>&1 | grep -q "wine32 is missing"; then
	echo "FAIL: wine32 is missing."
	echo "  Fix: run from nix develop shell (wine-wow64-11.0)."
	exit 1
fi

if [[ ! -f "$RA_EXE_PATH" ]]; then
	echo "SKIP: RA95.EXE not found at $RA_EXE_PATH"
	echo "  Run: bash scripts/wine-ra-setup.sh"
	echo "  Or download manually — see header of this script for instructions."
	exit 2
fi

if [[ ! -d "$DATA_DIR" ]]; then
	echo "FAIL: data directory not found: $DATA_DIR"
	exit 1
fi

EXE_SHA=$(sha256sum "$RA_EXE_PATH" | awk '{print $1}')
echo "  exe:  $RA_EXE_PATH (sha256=$EXE_SHA)"
echo "  data: $DATA_DIR"
echo ""

# ─── Ephemeral WINEPREFIX + staging ──────────────────────────────────────────

echo "=== Wine staging ==="

# Create ephemeral prefix under /tmp (no /opt, no $HOME/.wine-ra)
WINE_PREFIX="$(mktemp -d /tmp/wine-ra-XXXXXX)"

# Stage directory inside the prefix
RA_STAGE="$WINE_PREFIX/drive_c/game"
mkdir -p "$RA_STAGE"

# Initialize the prefix
echo "  Prefix: $WINE_PREFIX"
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null

# Configure Wine GDI renderer + virtual desktop (needed under Xvfb for DirectDraw).
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Explorer\Desktops' \
  /v Default /t REG_SZ /d "640x480" /f >/dev/null 2>&1 || true
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
  'HKCU\Software\Wine\Direct3D' \
  /v DirectDrawRenderer /t REG_SZ /d gdi /f >/dev/null 2>&1 || true

# Link MIX data into staging
echo "  Linking data: $DATA_DIR"
for f in "$DATA_DIR"/*.MIX; do
  [[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done

# Write REDALERT.INI with intro skipping
cat >"$RA_STAGE/REDALERT.INI" <<'INIEOF'
[Sound]
Card=0
Port=3F8h
IRQ=4
DMA=-1

[Options]
HardwareFills=no

[Intro]
PlayIntro=no
INIEOF

# Copy EXE into staging
cp "$RA_EXE_PATH" "$RA_STAGE/RA95.EXE"

# Use stub THIPX32.DLL (avoids 16-bit THIPX16.DLL thunking not supported
# by Wine 11.0 wow64). The stub provides the same exports but returns
# sensible defaults — networking will be non-functional, which is fine
# for title/menu screenshots.
STUB_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/stub-thipx"
if [[ -f "$STUB_DIR/thipx32.dll" ]]; then
  cp "$STUB_DIR/thipx32.dll" "$RA_STAGE/THIPX32.DLL"
fi

echo "  Staging: $RA_STAGE"
echo ""

# ─── Xvfb ────────────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
XVFB_PID=$!
cleanup_xvfb() { kill -9 "$XVFB_PID" 2>/dev/null || true; }
trap 'rm -rf "$WINE_PREFIX"; cleanup_xvfb' EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# ─── Launch RA95.EXE ─────────────────────────────────────────────────────────

echo "=== Launching RA95.EXE ==="
LOG="$(mktemp /tmp/wine-ra-XXXXXX.log)"
(
	cd "$RA_STAGE"
	DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" \
		WINEDEBUG=-all AUDIODEV=null \
		timeout 45 wine RA95.EXE
) >"$LOG" 2>&1 &
RA_PID=$!

# Wait for the DirectSound warning dialog to appear (~6s), then dismiss it.
sleep 7
echo "  Dismissing DirectSound warning dialog..."
DISPLAY="$DISPLAY_NUM" xdotool key Return 2>/dev/null || true

# Capture title/menu state
sleep 3
take_screenshot() {
	local out="$1"
	if command -v import >/dev/null 2>&1; then
		DISPLAY="$DISPLAY_NUM" import -window root "$out" 2>/dev/null && echo "  Screenshot: $out"
	fi
}

take_screenshot "$SCREENSHOT_DIR/wine-ra-title.png"

# Wait for menu to appear (title -> menu transition takes ~12s after dialog dismiss)
sleep 12
take_screenshot "$SCREENSHOT_DIR/wine-ra-menu.png"

kill "$RA_PID" 2>/dev/null || true

echo ""
echo "=== Results ==="
echo "  wine-ra-title.png: $(test -f "$SCREENSHOT_DIR/wine-ra-title.png" && stat -c '%s (written)' "$SCREENSHOT_DIR/wine-ra-title.png" || echo "MISSING")"
echo "  wine-ra-menu.png:  $(test -f "$SCREENSHOT_DIR/wine-ra-menu.png" && stat -c '%s (written)' "$SCREENSHOT_DIR/wine-ra-menu.png" || echo "MISSING")"

# Verify screenshots are non-trivially sized.
for shot in "$SCREENSHOT_DIR/wine-ra-title.png" "$SCREENSHOT_DIR/wine-ra-menu.png"; do
	if [[ -f "$shot" ]]; then
		sz=$(stat -c%s "$shot")
		if [[ $sz -lt 1000 ]]; then
			echo "  WARN: $shot is only $sz bytes — may be blank"
		else
			echo "  OK: $shot ($sz bytes)"
		fi
	fi
done

echo ""
echo "  To run Tier 3 Playwright comparison tests:"
echo "    WINE_RA_READY=1 playwright test e2e/tim699-ra-compare.spec.ts --grep 'Tier 3'"
