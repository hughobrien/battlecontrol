#!/usr/bin/env bash
# TIM-772 — Wine + RA95.EXE difficulty dialog capture for WASM baseline comparison.
# Uses cnc-ddraw with GDI renderer for X11-capturable frames.
#
# Usage:
#   bash scripts/wine-ra-difficulty-capture.sh [DATA_DIR] [ARTIFACT_DIR]
#
# Outputs (relative to ARTIFACT_DIR):
#   wine-difficulty-menu.png       — main menu
#   wine-difficulty-dialog.png     — difficulty selector
#   wine-difficulty-faction.png    — faction selector
set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
ARTIFACT_DIR="${2:-e2e/tim772/captures}"
RA_EXE="${RA_EXE:-/opt/redalert/game/RA95.EXE}"
WINE="${WINE:-wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim772}"
CNC_DDRAW="${CNC_DDRAW:-/tmp/cnc-ddraw-master/ddraw.dll}"
DLL_DIR="${DLL_DIR:-/opt/redalert/game}"
RUN_SECONDS="${RUN_SECONDS:-120}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
CDLABEL_PATCH="${CDLABEL_PATCH:-$THIS_DIR/cdlabel-patch.py}"
GAME_IN_FOCUS="${GAME_IN_FOCUS:-$THIS_DIR/game-in-focus-patch.py}"

rm -rf "$ARTIFACT_DIR"
mkdir -p "$ARTIFACT_DIR"

pick_display() {
	for d in 91 92 93 94 95 96 97 98 99; do
		if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
			echo ":$d"
			return
		fi
	done
	echo "no free display in :91-:99" >&2
	exit 1
}

echo "=== TIM-772 Wine difficulty capture ==="
echo "  wine: $($WINE --version)"
echo "  data: $DATA_DIR"
echo "  cnc-ddraw: $CNC_DDRAW"

STAGE=$(mktemp -d /tmp/tim772-wine-XXXX)
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$DLL_DIR/$dll" ]] && cp "$DLL_DIR/$dll" "$STAGE/$dll"
done
cp "$CNC_DDRAW" "$STAGE/ddraw.dll"

# Apply patches
python3 "$GAME_IN_FOCUS" "$STAGE/RA95.EXE" 2>&1 | tail -1
python3 "$CDLABEL_PATCH" "$STAGE/RA95.EXE" 2>&1 | tail -1

# Build helpers
i686-w64-mingw32-gcc -o "$STAGE/ra-sendinput.exe" "$THIS_DIR/../tools/wine-input/ra-sendinput.c" -luser32 2>/dev/null

# cnc-ddraw config: GDI renderer for X11-capturable frames
cat >"$STAGE/ddraw.ini" <<'INI'
[ddraw]
renderer=gdi
windowed=true
hook=0
INI

# Wine prefix
if [[ ! -d "$WINEPREFIX" ]]; then
	WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"

XDISP=$(pick_display)
echo "  display=$XDISP"

Xvfb "$XDISP" -screen 0 800x600x24 -ac >"$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox >"$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

cleanup() {
	kill ${WINE_PID:-} 2>/dev/null || true
	WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
	kill ${WM_PID:-} ${XVFB_PID:-} 2>/dev/null || true
	rm -rf "$STAGE"
}
trap cleanup EXIT

echo "=== Launching RA95.EXE ==="
(
	cd "$STAGE"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
		WINEDEBUG="-all" AUDIODEV=null \
		timeout "$RUN_SECONDS" "$WINE" RA95.EXE
) >"$ARTIFACT_DIR/wine.log" 2>&1 &
WINE_PID=$!

take_shot() {
	local name="$1"
	DISPLAY="$XDISP" ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
		-i "$XDISP" -frames:v 1 -y "$ARTIFACT_DIR/$name" 2>/dev/null
	echo "  $name: $(stat -c%s "$ARTIFACT_DIR/$name" 2>/dev/null || echo 0) bytes"
}

send_input() {
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all \
		"$WINE" "$STAGE/ra-sendinput.exe" "$@" >>"$ARTIFACT_DIR/helper.log" 2>&1 || true
}

# Wait for RA window
echo "Waiting for RA window..."
for i in $(seq 1 30); do
	if DISPLAY="$XDISP" xdotool search --name "Red Alert" >/dev/null 2>&1; then
		echo "  window found at t=${i}s"
		break
	fi
	sleep 1
done

# Dismiss boot dialogs
sleep 4
send_input key 0x0D 0
sleep 3
send_input key 0x0D 0

# Wait for intro VQAs to finish (ENGLISH.VQA ~10s + PROLOG.VQA ~45s)
echo "Waiting for intro VQAs to finish (~55s)..."
sleep 55

# Main menu
take_shot "wine-difficulty-menu.png"

# Click "New Campaign" button (322,183 in 640x480)
echo "=== Clicking New Campaign ==="
send_input click 322 183 1500
sleep 4
take_shot "wine-difficulty-dialog.png"

# Click OK on difficulty (470,244 in 640x480)
echo "=== Clicking OK ==="
send_input click 470 244 1500
sleep 4
take_shot "wine-difficulty-faction.png"

echo "=== Results ==="
PASS=0
for shot in wine-difficulty-menu.png wine-difficulty-dialog.png wine-difficulty-faction.png; do
	sz=$(stat -c%s "$ARTIFACT_DIR/$shot" 2>/dev/null || echo 0)
	if [[ $sz -gt 5000 ]]; then
		echo "  OK   $shot ($sz bytes)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL $shot ($sz bytes — likely blank)"
	fi
done
echo "Captured $PASS/3 non-empty screenshots"
[[ $PASS -ge 2 ]] && echo "RESULT: PASS"
