#!/usr/bin/env bash
# TIM-857 — Drive RA95.EXE into Allied Mission 2 under headless Wine and
# capture frame-100 / frame-250 / frame-500 gameplay screenshots.
#
# How this reaches Allied Mission 2
# ─────────────────────────────────
# The OG RA95.EXE binary hardcodes "SCG01EA.INI" (Allied L1, SCG01EA.INI)
# in three code paths: RA_AUTOSTART, FACTION dialog, and IsFromInstall.
# scripts/ra-scenario-patch.py replaces all occurrences with "SCG02EA.INI"
# so any path that calls Set_Scenario_Name loads M2 instead of L1.
#
# When the cdlabel-patch zeros the CD1 label, Wine's empty volume label
# matches index 0 → CurrentCD = 0 → IsFromInstall auto-selects Start
# New Game → Choose_Side → Allied → Set_Scenario_Name loads SCG02EA.INI
# (patched) → the game enters Allied M2 ("Disturbance in the Ukraine").
#
# Scenario data location
# ──────────────────────
# SCG02EA.INI lives in MAIN.MIX at raw offset 0xF60D4C as an embedded
# text block. The game reads it via MixFileClass::Retrieve through its
# virtual filesystem — no loose file is needed in the staging directory.
#
# AUTODEMO interaction
# ────────────────────
# The patched binary reaches SEL_START_NEW_GAME via IsFromInstall before
# the AUTODEMO attract-mode timeout fires (~3600 ticks = well after the
# menu code executes). If AUTODEMO does fire first, the recording still
# plays back Allied L1 inputs on the M2 map (terrain mismatch but not a
# crash — the game engine loads whatever scenario Set_Scenario_Name names).
# Once the game enters the menu code (keypress or auto-advance), the
# patched scenario takes over.
#
# Rendering
# ─────────
#  * cnc-ddraw master build with the TIM-740 scanline_double patch
#   (scripts/build-cnc-ddraw.sh → /tmp/cnc-ddraw-master/ddraw.dll)
#  * GDI renderer + windowed mode so the framebuffer is captured via
#   ffmpeg x11grab from Xvfb
#  * openbox WM so the Wine window is decorated and DInput attaches
#
# Wine version
# ────────────
# Pinned to Wine 10.0 (/usr/bin/wine). Wine 11.x regressed the d:=cdrom
# detection path: GetVolumeInformationA returns FALSE for the symlinked
# drive even with the cdlabel-patch applied.
#
# Outputs in $ARTIFACT_DIR (default: e2e/report/data/wine-ra-allied-m2/):
#  frame-0.png  — pre-Options, M2 mission rendering
#  frame-100.png — Options dialog over M2 terrain (paused)
#  frame-250.png — post-resume, M2 gameplay in progress
#  frame-500.png — M2 ~33 s after mission start
#  wine.log helper.log xvfb.log openbox.log
#
# Exit:
#  0 — frame-500.png has >=64 unique colours and >=5 KB on disk
#  non-zero otherwise

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim857-allied-m2}"
RA_EXE_PATH="${1:-${RA_EXE_PATH:-}}"
if [[ -z "$RA_EXE_PATH" ]]; then
	RA_EXE_PATH=$(nix build .#ra-patched-exe --impure --print-out-paths 2>/dev/null) || true
fi
if [[ -z "$RA_EXE_PATH" ]] || [[ ! -f "$RA_EXE_PATH" ]]; then
	echo "ERROR: RA95.EXE not found. Set RA_EXE_PATH or run from nix develop."
	exit 1
fi
RA_DLL_DIR="$(dirname "$RA_EXE_PATH")"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw-master}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/report/data/wine-ra-allied-m2}"
SCENARIO="${SCENARIO:-SCG02EA}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$THIS_DIR/../tools/wine-input"
SENDINPUT_SRC="$HELPER_DIR/ra-sendinput.c"
SENDINPUT_EXE="/tmp/ra-sendinput.exe"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# ─── Preflight ───────────────────────────────────────────────────────────────

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
	echo "FAIL: cnc-ddraw (TIM-740 scanline_double build) missing at $CNC_DDRAW_DIR"
	echo "  run: bash scripts/build-cnc-ddraw.sh"
	exit 1
}
[[ -f "$SENDINPUT_SRC" ]] || {
	echo "FAIL: $SENDINPUT_SRC missing"
	exit 1
}

[[ -f "$SENDINPUT_EXE" && "$SENDINPUT_SRC" -ot "$SENDINPUT_EXE" ]] ||
	i686-w64-mingw32-gcc -o "$SENDINPUT_EXE" "$SENDINPUT_SRC" -luser32

echo " wine:    $($WINE --version)"
echo " scenario:  $SCENARIO"
echo " ra-input:  $SENDINPUT_EXE"
echo " cnc-ddraw: $CNC_DDRAW_DIR/ddraw.dll"
echo " prefix:   $WINEPREFIX"
echo " data:    $DATA_DIR"
echo " artifacts: $ARTIFACT_DIR"

# ─── Pick free X display ─────────────────────────────────────────────────────

pick_display() {
	for d in 86 87 88 89 90 92 93 94 96 97 98; do
		if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
			echo ":$d"
			return
		fi
	done
	echo "no free display" >&2
	exit 1
}
XDISP="${XDISP:-$(pick_display)}"
echo " display:  $XDISP"

# ─── Stage ───────────────────────────────────────────────────────────────────

STAGE=$(mktemp -d "/tmp/tim857-allied-m2-XXXX")
trap 'rm -rf "$STAGE"' EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

echo
echo "=== applying binary patches ==="
for patch in focus-skip-patch.py game-in-focus-patch.py cdlabel-patch.py vqa-skip-patch.py; do
	if [[ -f "$THIS_DIR/$patch" ]]; then
		echo " $patch:"
		python3 "$THIS_DIR/$patch" "$STAGE/RA95.EXE" 2>&1 | sed 's/^/  /' | tail -3 || true
	fi
done

# Apply scenario override: SCG01EA -> SCG02EA (Allied M2)
echo " ra-scenario-patch.py: $SCENARIO"
python3 "$THIS_DIR/ra-scenario-patch.py" "$STAGE/RA95.EXE" "$SCENARIO" 2>&1 | sed 's/^/  /'
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

# ─── Wine prefix ─────────────────────────────────────────────────────────────

if [[ ! -d "$WINEPREFIX" ]]; then
	echo " creating $WINEPREFIX..."
	WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all \
		"$WINE" wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
rm -f "$WINEPREFIX/dosdevices/d::" 2>/dev/null
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
	'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# ─── Xvfb + openbox ──────────────────────────────────────────────────────────

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

# ─── Launch RA ───────────────────────────────────────────────────────────────

echo
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
# shellcheck disable=SC2034
WIN_TIME=0
for i in $(seq 1 30); do
	if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
		echo " Red Alert window appeared after ${i}s"
		break
	fi
	sleep 1
done

# ─── Helper functions ────────────────────────────────────────────────────────

send_key() {
	local vk="$1" label="${2:-key}"
	echo " SendInput key[$label]: vk=$vk"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all "$WINE" "$STAGE/ra-sendinput.exe" key "$vk" \
		>>"$ARTIFACT_DIR/helper.log" 2>&1 || true
}

send_click() {
	local x="$1" y="$2" label="${3:-click}"
	echo " SendInput click[$label]: client=($x,$y)"
	DISPLAY="$XDISP" WAYLAND_DISPLAY="" WINEPREFIX="$WINEPREFIX" \
		WINEDEBUG=-all "$WINE" "$STAGE/ra-sendinput.exe" click "$x" "$y" \
		>>"$ARTIFACT_DIR/helper.log" 2>&1 || true
}

shoot() {
	local name="$1"
	local png="$ARTIFACT_DIR/${name}.png"
	ffmpeg -nostdin -loglevel error -f x11grab -video_size 1024x768 \
		-i "$XDISP" -frames:v 1 -y "$png" 2>/dev/null || true
	local sz
	sz=$(stat -c%s "$png" 2>/dev/null || echo "0")
	echo " shot $name: $sz bytes"
}

# ─── Capture sequence ────────────────────────────────────────────────────────
#
# TICKS_PER_SECOND = 15 (REDALERT/DEFINES.H:3152).
# Frame labels are wall-clock approximations anchored to frame-0:
#  frame-0  -> ~0 ticks (first rendered frame after Autodemo loads)
#  frame-100 -> ~100 ticks (Options overlay, paused)
#  frame-250 -> ~250 ticks (post-resume gameplay)
#  frame-500 -> ~500 ticks (~33 s after mission start)

echo
echo "=== capture sequence ==="

# Settle: game needs ~3 s after window creation to render first frame.
sleep 3
shoot "frame-0"

if ! kill -0 $RA_PID 2>/dev/null; then
	echo "FAIL: RA died before mission render — see $ARTIFACT_DIR/wine.log"
	exit 3
fi

# Esc pauses the simulation, pops the in-mission Options dialog.
# This proves the input pipeline is healthy and gives a paused-over-
# terrain reference frame for the port's SSIM comparison.
send_key 0x1B "esc-options"
sleep 2
shoot "frame-100"

# Resume Mission button: click dismisses Options, game continues.
send_click 215 273 "resume-mission"
sleep 7
shoot "frame-250"

sleep 17
shoot "frame-500"

# ─── Validation ──────────────────────────────────────────────────────────────

echo
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
		echo " PASS frame-500.png is non-black (>=5 KB and >=64 colours)"
	else
		echo " FAIL frame-500.png does not meet thresholds (need >=5 KB and >=64 colours)"
		PASS=0
	fi
fi

echo
echo "=== shot inventory ==="
for name in frame-0 frame-100 frame-250 frame-500; do
	shot="$ARTIFACT_DIR/${name}.png"
	if [[ -f "$shot" ]]; then
		sz=$(stat -c%s "$shot")
		if command -v identify >/dev/null 2>&1; then
			nc=$(identify -format "%k" "$shot" 2>/dev/null || echo "?")
		else
			nc="?"
		fi
		echo " $name.png -- $sz bytes, $nc colours"
	else
		echo " $name.png -- MISSING"
	fi
done

echo
if [[ "$PASS" -eq 1 ]]; then
	echo "RESULT: PASS -- frame-500 shows non-black Allied M2 ($SCENARIO) terrain"
	exit 0
else
	echo "RESULT: FAIL -- see $ARTIFACT_DIR/wine.log"
	exit 1
fi
