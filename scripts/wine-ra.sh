#!/usr/bin/env bash
# TIM-699 — Wine setup and OG Red Alert launcher for side-by-side comparison.
#
# Runs the original Windows Red Alert (RA95.EXE) under Wine with a headless
# Xvfb display, dismisses the DirectSound warning dialog, captures screenshots,
# and prints key diagnostic markers for automated comparison tests.
#
# ─── Verified environment ────────────────────────────────────────────────────
# Host: Debian Bookworm (Debian 13), x86_64
# Wine: 10.0 (Debian 10.0~repack-6), wine64 + wine32:i386
# RA95.EXE: from cnc-red-alert Allied ISO at archive.org (SHA-256 below)
# Data: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX (454 MB)
# Result: game launches, shows RA menu background (dark blue #283870)
#
# ─── First-time setup ────────────────────────────────────────────────────────
# Run this once to get all prerequisites:
#   bash scripts/wine-ra-setup.sh
#
# Or manually:
#   1. Install wine32:
#        sudo dpkg --add-architecture i386
#        sudo apt-get update
#        sudo apt-get install wine32:i386
#
#   2. Download RA95.EXE (from the Allied CD ISO at archive.org):
#        sudo mkdir -p /opt/redalert
#        sudo chmod 777 /opt/redalert
#        # Read only the EXE bytes from the ISO (LBA 45220, size 2181632):
#        START=$((45220 * 2048))
#        END=$((START + 2181632 - 1))
#        curl -L -r "${START}-${END}" \
#          "https://archive.org/download/cnc-red-alert/redalert_allied.iso" \
#          -o /opt/redalert/RA95.EXE
#        # Expected SHA-256:
#        # a95e2ac85c4cc3aaacb7795e3c07b8aec7c3e10efe679766fb2ee15b12aa2d55
#
#   3. Download required DLLs from the same ISO:
#        # THIPX32.DLL (LBA 58881, size 25902):
#        START=$((58881 * 2048))
#        curl -L -r "${START}-$((START+25901))" \
#          "https://archive.org/download/cnc-red-alert/redalert_allied.iso" \
#          -o /opt/redalert/THIPX32.DLL
#        # THIPX16.DLL (LBA 58878, size 4192):
#        START=$((58878 * 2048))
#        curl -L -r "${START}-$((START+4191))" \
#          "https://archive.org/download/cnc-red-alert/redalert_allied.iso" \
#          -o /opt/redalert/THIPX16.DLL
#
# ─── Known behavior under Wine ───────────────────────────────────────────────
# • DirectSound warning: "Warning - Unable to create Direct Sound Object"
#   This dialog appears because there is no physical audio card on CI.
#   We dismiss it automatically with xdotool.  The game proceeds normally.
# • ALSA errors in stderr: expected (no audio card), not game failures.
# • Display: RA renders at 640×480 windowed within the Xvfb screen.
#   The characteristic menu background is (40, 56, 108) = #283870 (dark navy).
# • No CD check: the game reads MAIN.MIX from the current directory.
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-ra.sh [EXE_PATH] [DATA_DIR] [SCREENSHOT_DIR]
#
#    EXE_PATH        path to RA95.EXE     (default: /opt/redalert/RA95.EXE)
#    DATA_DIR        CD1 data directory   (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
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

RA_EXE_PATH="${1:-${RA_EXE_PATH:-/opt/redalert/RA95.EXE}}"
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

# wine32 check: fail gracefully if 32-bit support is missing
if wine --version 2>&1 | grep -q "wine32 is missing"; then
	echo "FAIL: wine32 is missing."
	echo "  Fix: sudo dpkg --add-architecture i386 && sudo apt-get update && sudo apt-get install wine32:i386"
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

# ─── Wine prefix + staging ───────────────────────────────────────────────────

echo "=== Wine staging ==="
RA_STAGE="$(mktemp -d)"
trap 'rm -rf "$RA_STAGE"' EXIT

# Link MIX data + DLLs into a temporary staging directory.
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$RA_STAGE/$(basename "$f")"
done
# Copy EXE and IPX DLLs to staging.
cp "$RA_EXE_PATH" "$RA_STAGE/RA95.EXE"
# Copy THIPX DLLs if present (required at startup).
THIPX_DIR="$(dirname "$RA_EXE_PATH")"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$THIPX_DIR/$dll" ]] && cp "$THIPX_DIR/$dll" "$RA_STAGE/$dll"
done

if [[ ! -d "$WINE_PREFIX" ]]; then
	echo "  Creating 32-bit Wine prefix at $WINE_PREFIX..."
	WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 WINEDEBUG=-all wineboot --init 2>/dev/null
fi
echo "  Staging: $RA_STAGE"
echo ""

# ─── Xvfb ────────────────────────────────────────────────────────────────────

echo "=== Starting Xvfb $DISPLAY_NUM ==="
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
XVFB_PID=$!
cleanup_xvfb() { kill -9 "$XVFB_PID" 2>/dev/null || true; }
trap 'rm -rf "$RA_STAGE"; cleanup_xvfb' EXIT
sleep 1
echo "  Xvfb pid=$XVFB_PID"

# ─── Launch RA95.EXE ─────────────────────────────────────────────────────────

echo "=== Launching RA95.EXE ==="
LOG="$(mktemp /tmp/wine-ra-XXXXXX.log)"
(
	cd "$RA_STAGE"
	DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" WINEARCH=win32 \
		WINEDEBUG=-all AUDIODEV=null \
		timeout 45 wine RA95.EXE
) >"$LOG" 2>&1 &
RA_PID=$!

# Wait for the DirectSound warning dialog to appear (~6s), then dismiss it.
sleep 7
echo "  Dismissing DirectSound warning dialog..."
DISPLAY="$DISPLAY_NUM" xdotool key Return 2>/dev/null || true
sleep 1
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

sleep 8
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
		if [[ $sz -lt 5000 ]]; then
			echo "  WARN: $shot is only $sz bytes — may be blank"
		else
			echo "  OK: $shot ($sz bytes)"
		fi
	fi
done

echo ""
echo "  To run Tier 3 Playwright comparison tests:"
echo "    WINE_RA_READY=1 playwright test e2e/tim699-ra-compare.spec.ts --grep 'Tier 3'"
