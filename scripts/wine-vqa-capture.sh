#!/usr/bin/env bash
# Capture frames during VQA playback from RA95.EXE under headless Wine.
#
# Launches RA95.EXE with cnc-ddraw GDI renderer (no VQA skip), lets the
# intro VQAs play, and captures N BMP frames with ra-screenshot.exe at
# evenly-spaced timing offsets. Converts BMP to PNG.
#
# This is the Wine side of the three-way parity comparison. Goldens are
# generated from the VQA decoder via gen-vqa-golden.py.
#
# Usage:
#  bash scripts/wine-vqa-capture.sh ENGLISH [DATA_DIR] [ARTIFACT_DIR] [FRAMES]
#
# Exit: 0 = all frames captured, >5KB each.

set -euo pipefail

VQA_STEM="${1:?usage: $0 <VQA_STEM> [DATA_DIR] [ARTIFACT_DIR] [FRAMES]}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
ARTIFACT_DIR="${3:-e2e/screenshots/wine-vqa}"
FRAMES="${4:-4}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$THIS_DIR/../tools/wine-input"
RA_EXE_PATH="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE_PATH" ]]; then
	RA_EXE_PATH=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE_PATH" ]] || [[ ! -f "$RA_EXE_PATH" ]]; then
	echo "ERROR: RA95.EXE not found. Set RA_EXE_PATH or run from nix develop."
	exit 1
fi
RA_DLL_DIR="$(dirname "$RA_EXE_PATH")"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw-master}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-vqa-capture}"
WINE="${WINE:-/usr/bin/wine}"

SENDINPUT_SRC="$HELPER_DIR/ra-sendinput.c"
SCREENSHOT_SRC="$HELPER_DIR/ra-screenshot.c"
SENDINPUT_EXE="/tmp/ra-sendinput-vqa.exe"
SCREENSHOT_EXE="/tmp/ra-screenshot-vqa.exe"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# --- Preflight ---
echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg i686-w64-mingw32-gcc convert; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "FAIL: $tool missing"
		exit 1
	}
done
[[ -f "$RA_EXE_PATH" ]] || {
	echo "FAIL: $RA_EXE_PATH missing — run scripts/wine-ra-setup.sh"
	exit 2
}
[[ -d "$DATA_DIR" ]] || {
	echo "FAIL: $DATA_DIR missing"
	exit 1
}
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || {
	echo "FAIL: cnc-ddraw missing at $CNC_DDRAW_DIR"
	echo " run: bash scripts/build-cnc-ddraw.sh"
	exit 1
}

# Build helpers
for src in "$SENDINPUT_SRC" "$SCREENSHOT_SRC"; do
	[[ -f "$src" ]] || {
		echo "FAIL: $src missing"
		exit 1
	}
done
i686-w64-mingw32-gcc -o "$SENDINPUT_EXE" "$SENDINPUT_SRC" -luser32 2>/dev/null
i686-w64-mingw32-gcc -o "$SCREENSHOT_EXE" "$SCREENSHOT_SRC" -lgdi32 -luser32 2>/dev/null

echo " vqa:   $VQA_STEM.VQA"
echo " data:  $DATA_DIR"
echo " out:   $ARTIFACT_DIR"
echo " frames: $FRAMES"

# --- Pick free X display ---
pick_display() {
	for d in 92 93 94 96 97 98; do
		if [[ ! -e "/tmp/.X${d}-lock" ]]; then
			echo ":$d"
			return
		fi
	done
	echo "no free display" >&2
	exit 1
}
XDISP="$(pick_display)"
echo " display: $XDISP"

# --- Stage ---
STAGE="$(mktemp -d /tmp/wine-vqa-XXXX)"
trap 'rm -rf "$STAGE"' EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

# Apply patches BUT NOT vqa-skip — we want VQAs to play
echo
echo "=== applying patches (no vqa-skip) ==="
for patch in focus-skip-patch.py game-in-focus-patch.py cdlabel-patch.py; do
	if [[ -f "$THIS_DIR/$patch" ]]; then
		echo " $patch"
		python3 "$THIS_DIR/$patch" "$STAGE/RA95.EXE" 2>&1 | tail -3 || true
	fi
done
echo " final sha256: $(sha256sum "$STAGE/RA95.EXE" | cut -d' ' -f1)"

# cnc-ddraw drop-in
cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat >"$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
maxfps=30

[ra95]
scanline_double=true
EOF

cp "$SENDINPUT_EXE" "$STAGE/ra-sendinput.exe"
cp "$SCREENSHOT_EXE" "$STAGE/ra-screenshot.exe"

# --- Wine prefix ---
if [[ ! -d "$WINEPREFIX" ]]; then
	echo " creating $WINEPREFIX..."
	WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all \
		"$WINE" wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
rm -f "$WINEPREFIX/dosdevices/d::" 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
	'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# --- Xvfb + openbox ---
echo
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

# --- Helper: capture via ra-screenshot.exe, convert BMP to PNG ---
shoot() {
	local stem="$1"
	local delay_ms="${2:-0}"
	local bmp="$ARTIFACT_DIR/${stem}.bmp"
	local png="$ARTIFACT_DIR/${stem}.png"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all "$WINE" "$STAGE/ra-screenshot.exe" "$bmp" "$delay_ms" \
		>>"$ARTIFACT_DIR/helper.log" 2>&1 || true
	if [[ -f "$bmp" ]]; then
		convert "$bmp" "$png" 2>/dev/null && rm -f "$bmp"
	fi
	local sz=0
	[[ -f "$png" ]] && sz=$(stat -c%s "$png")
	echo " shot $stem: ${sz} bytes"
}

# --- Launch RA95.EXE ---
echo
echo "=== launching RA95.EXE ==="
(
	cd "$STAGE"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" \
		WINEPREFIX="$WINEPREFIX" \
		WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
		WINEDEBUG=-all AUDIODEV=null \
		timeout 120 "$WINE" RA95.EXE
) >"$ARTIFACT_DIR/wine.log" 2>&1 &
RA_PID=$!

# --- Wait for Red Alert window ---
echo " waiting for Red Alert window..."
WINDOW_READY=0
for i in $(seq 1 30); do
	if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
		echo " window appeared after ${i}s"
		WINDOW_READY=1
		break
	fi
	sleep 1
done

if [[ $WINDOW_READY -eq 0 ]]; then
	echo "FAIL: Red Alert window never appeared"
	exit 3
fi

# Dismiss DirectSound warning dialog
sleep 5
DISPLAY="$XDISP" xdotool key Return 2>/dev/null || true
sleep 1
DISPLAY="$XDISP" xdotool key Return 2>/dev/null || true
echo " DirectSound dialog dismissed"

# --- VQA playback capture ---
# Read golden manifest to get total frames and calculate timing
GOLDEN_DIR="${GOLDEN_DIR:-e2e/goldens/vqa/$VQA_STEM}"
MANIFEST="$GOLDEN_DIR/manifest.json"
VQA_FPS=15
VQA_DURATION=30
if [[ -f "$MANIFEST" ]]; then
	echo " golden manifest: $MANIFEST"
	TOTAL_FRAMES=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['total_frames'])" 2>/dev/null || echo "0")
	VQA_FPS=15
	VQA_DURATION=$(python3 -c "print($TOTAL_FRAMES / $VQA_FPS)" 2>/dev/null || echo "0")
	echo " total_frames=$TOTAL_FRAMES duration=${VQA_DURATION}s"
else
	echo " WARN: no golden manifest at $MANIFEST — using defaults"
fi

# Capture FRAMES checkpoints at even intervals
echo
echo "=== capture: $FRAMES frames over ${VQA_DURATION}s ==="

for i in $(seq 0 $((FRAMES - 1))); do
	offset_sec=$(((i * VQA_DURATION) / FRAMES))
	if [[ $i -eq 0 ]]; then
		sleep 1
	else
		prev=$((((i - 1) * VQA_DURATION) / FRAMES))
		delta=$((offset_sec - prev))
		sleep "$delta"
	fi
	shoot "vqa-${VQA_STEM}-$(printf '%04d' "$i")" 0
	if ! kill -0 $RA_PID 2>/dev/null; then
		echo " RA exited early"
		break
	fi
done

# --- Validation ---
echo
echo "=== validation ==="
pass=0
fail=0
for i in $(seq 0 $((FRAMES - 1))); do
	png="$ARTIFACT_DIR/vqa-${VQA_STEM}-$(printf '%04d' "$i").png"
	if [[ -f "$png" ]]; then
		sz=$(stat -c%s "$png")
		if [[ $sz -gt 5000 ]]; then
			echo " OK $png ${sz} bytes"
			pass=$((pass + 1))
		else
			echo " WARN $png ${sz} bytes (too small)"
			fail=$((fail + 1))
		fi
	else
		echo " MISS $png"
		fail=$((fail + 1))
	fi
done

echo " captured: $pass/$FRAMES failed: $fail"
[[ $fail -gt 0 ]] && exit 1
exit 0
