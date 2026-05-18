#!/usr/bin/env bash
# TIM-803 — Drive RA95.EXE into Soviet Mission 2 under headless Wine.
# This is a thin wrapper: uses wine-soviet-l1.sh pattern but swaps
# cdlabel-patch for soviet-cdlabel-patch and adds soviet-m2-scenario-patch.
#
# For full documentation see wine-soviet-l1.sh.

set -euo pipefail

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim803-soviet-m2}"
RA_EXE_PATH="${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE.focus_orig}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw-master}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/report/data/wine-ra-soviet-m2}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$THIS_DIR/../tools/wine-input"
SENDINPUT_SRC="$HELPER_DIR/ra-sendinput.c"
SENDINPUT_EXE="/tmp/ra-sendinput.exe"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg i686-w64-mingw32-gcc; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "FAIL: $tool missing"
		exit 1
	}
done
[[ -f "$RA_EXE_PATH" ]] || {
	echo "FAIL: $RA_EXE_PATH missing"
	exit 2
}
[[ -d "$DATA_DIR" ]] || {
	echo "FAIL: $DATA_DIR missing"
	exit 1
}
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || {
	echo "FAIL: cnc-ddraw missing at $CNC_DDRAW_DIR"
	exit 1
}
[[ -f "$SENDINPUT_SRC" ]] || {
	echo "FAIL: $SENDINPUT_SRC missing"
	exit 1
}

[[ -f "$SENDINPUT_EXE" && "$SENDINPUT_SRC" -ot "$SENDINPUT_EXE" ]] ||
	i686-w64-mingw32-gcc -o "$SENDINPUT_EXE" "$SENDINPUT_SRC" -luser32

echo " wine:    $($WINE --version)"
echo " cnc-ddraw: $CNC_DDRAW_DIR/ddraw.dll"
echo " artifacts: $ARTIFACT_DIR"

pick_display() {
	for d in 86 87 88 89 90 91 92 93 94 96 97 98; do
		if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
			echo ":$d"
			return
		fi
	done
	echo "no free display" >&2
	exit 1
}
XDISP="${XDISP:-$(pick_display)}"

STAGE=$(mktemp -d /tmp/tim803-soviet-m2-XXXX)
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

echo "=== applying binary patches ==="
for patch in focus-skip-patch.py game-in-focus-patch.py soviet-cdlabel-patch.py soviet-m2-scenario-patch.py vqa-skip-patch.py; do
	if [[ -f "$THIS_DIR/$patch" ]]; then
		echo " $patch:"
		python3 "$THIS_DIR/$patch" "$STAGE/RA95.EXE" 2>&1 | sed 's/^/  /' | tail -3 || true
	fi
done

cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat >"$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
[ra95]
scanline_double=true
EOF

cp "$SENDINPUT_EXE" "$STAGE/ra-sendinput.exe"

if [[ ! -d "$WINEPREFIX" ]]; then
	WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
rm -f "$WINEPREFIX/dosdevices/d::" 2>/dev/null
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
	'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

echo "=== starting Xvfb + openbox on $XDISP ==="
Xvfb "$XDISP" -screen 0 1024x768x24 -ac >"$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox >"$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

# shellcheck disable=SC2329
cleanup() {
	[[ -n "${RA_PID:-}" ]] && kill "$RA_PID" 2>/dev/null || true
	WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
	[[ -n "${WM_PID:-}" ]] && kill "$WM_PID" 2>/dev/null || true
	[[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
	rm -rf "$STAGE"
}
trap cleanup EXIT

echo "=== launching RA95.EXE ==="
(
	cd "$STAGE"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" \
		WINEPREFIX="$WINEPREFIX" \
		WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
		WINEDEBUG=-all AUDIODEV=null \
		timeout 240 "$WINE" RA95.EXE
) >"$ARTIFACT_DIR/wine.log" 2>&1 &
RA_PID=$!

echo " waiting for Red Alert window..."
for i in $(seq 1 30); do
	if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
		echo " Red Alert window appeared after ${i}s"
		break
	fi
	sleep 1
done

send_key() {
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all "$WINE" "$STAGE/ra-sendinput.exe" key "$1" \
		>>"$ARTIFACT_DIR/helper.log" 2>&1 || true
}

send_click() {
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all "$WINE" "$STAGE/ra-sendinput.exe" click "$1" "$2" \
		>>"$ARTIFACT_DIR/helper.log" 2>&1 || true
}

shoot() {
	local png="$ARTIFACT_DIR/${1}.png"
	ffmpeg -nostdin -loglevel error -f x11grab -video_size 1024x768 \
		-i "$XDISP" -frames:v 1 -y "$png" 2>/dev/null || true
	echo " shot $1: $(stat -c%s "$png" 2>/dev/null || echo 0) bytes"
}

echo "=== capture sequence ==="
sleep 3
shoot "frame-0"
if ! kill -0 $RA_PID 2>/dev/null; then
	echo "FAIL: RA died — see $ARTIFACT_DIR/wine.log"
	exit 3
fi
send_key 0x1B "esc-options"
sleep 2
shoot "frame-100"
send_click 215 273 "resume-mission"
sleep 7
shoot "frame-250"
sleep 17
shoot "frame-500"

echo "=== validation ==="
PASS=1
TARGET="$ARTIFACT_DIR/frame-500.png"
if [[ ! -f "$TARGET" ]]; then
	echo " FAIL frame-500.png missing"
	PASS=0
else
	sz=$(stat -c%s "$TARGET")
	if command -v identify >/dev/null 2>&1; then
		ncolors=$(identify -format "%k" "$TARGET" 2>/dev/null || echo "0")
	else
		ncolors="unknown"
	fi
	echo " frame-500.png: $sz bytes, $ncolors unique colours"
	if [[ "$sz" -ge 5000 && "$ncolors" -ge 64 ]]; then
		echo " PASS frame-500.png is non-black Soviet M2"
	else
		echo " FAIL frame-500.png below thresholds"
		PASS=0
	fi
fi
if [[ "$PASS" -eq 1 ]]; then
	echo "RESULT: PASS"
	exit 0
else
	echo "RESULT: FAIL"
	exit 1
fi
