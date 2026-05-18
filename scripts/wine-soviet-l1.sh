#!/usr/bin/env bash
# TIM-776 — Drive RA95.EXE into Soviet Mission 1 under headless Wine and
# capture a frame-500 reference screenshot for WASM parity comparison.
#
# Differs from wine-allied-l1.sh
# ──────────────────────────────
# wine-allied-l1.sh relies on the IsFromInstall + CurrentCD=0 auto-start
# code path (INIT.CPP:942/1032) — RA95.EXE under the standard patch
# chain reaches SEL_START_NEW_GAME with no menu interaction and
# launches SCG01EA.INI (Allied L1) within 3-6 s of the window appearing.
#
# This script swaps the auto-start target to Soviet L1 (SCU01EA.INI) by
# substituting `scripts/soviet-cdlabel-patch.py` for the standard
# `scripts/cdlabel-patch.py`. The Soviet variant zeros the first byte
# of "CD2" in _CD_Volume_Label[] (file offset 0x1BFCBB) instead of the
# first byte of "CD1" — so Wine's empty CIFS volume label matches
# index 1 (Soviet) instead of index 0 (Allied). Get_CD_Index then
# returns 1, CurrentCD = 1, and the IsFromInstall branch at
# INIT.CPP:1032-1036 selects SCU01EA.INI.
#
# No menu navigation is needed — Soviet L1 launches automatically the
# same way Allied L1 does in wine-allied-l1.sh. The two scripts differ
# only in the cdlabel patch applied.
#
# Rendering
# ─────────
#  * cnc-ddraw master build with TIM-740 scanline_double patch
#  * GDI renderer + windowed mode (framebuffer reaches X11 → ffmpeg)
#  * openbox WM so the Wine window is decorated for DInput attach
#
# Wine version
# ────────────
# Pinned to Wine 10.0. Wine 11.x regressed the d:=cdrom detection path
# (see project memory `wine_11x_volume_label_regression`).
#
# Outputs in $ARTIFACT_DIR (default: e2e/report/data/wine-ra-soviet-l1/):
#  frame-0.png  — pre-Options, Soviet L1 mission rendering
#  frame-100.png — Options dialog over Soviet L1 terrain (paused)
#  frame-250.png — post-resume, Soviet L1 ~16 s after mission start
#  frame-500.png — Soviet L1 ~33 s after mission start (15 TPS × 33)
#  wine.log helper.log xvfb.log openbox.log
#
# Exit:
#  0 — frame-500.png has ≥64 unique colours and ≥5 KB on disk
#  non-zero otherwise

set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim776-soviet}"
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
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/report/data/wine-ra-soviet-l1}"

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

STAGE=$(mktemp -d /tmp/tim776-soviet-XXXX)

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
	[[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
	[[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

echo
echo "=== applying binary patches ==="
# soviet-cdlabel-patch.py replaces cdlabel-patch.py — see header comment.
for patch in focus-skip-patch.py game-in-focus-patch.py soviet-cdlabel-patch.py vqa-skip-patch.py; do
	if [[ -f "$THIS_DIR/$patch" ]]; then
		echo " $patch:"
		python3 "$THIS_DIR/$patch" "$STAGE/RA95.EXE" 2>&1 | sed 's/^/  /' | tail -3 || true
	fi
done
echo " final sha256: $(sha256sum "$STAGE/RA95.EXE" | cut -d' ' -f1)"

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

# ─── Capture sequence (mirrors wine-allied-l1.sh) ────────────────────────────
#
# Boot under the soviet-cdlabel patch chain:
#  * 0–3 s  : Wine launches RA95.EXE
#  * 3-6 s  : Get_CD_Index returns 1 (CD2 label matched empty Wine label)
#        CurrentCD = 1, IsFromInstall = true, scenario auto-set to
#        SCU01EA.INI by INIT.CPP:1032-1036
#  * frame 0 : Soviet Mission 1 rendered ~6 s after window appears.

echo
echo "=== capture sequence ==="

# Settle: Soviet L1 needs ~3 s after window creation to render first frame.
sleep 3
shoot "frame-0"

if ! kill -0 $RA_PID 2>/dev/null; then
	echo "FAIL: RA died before mission rendered — see $ARTIFACT_DIR/wine.log"
	exit 3
fi

# Esc opens the in-mission Options dialog (pauses the sim). Same pattern
# as wine-allied-l1.sh — proves the input pipeline is healthy and gives a
# paused-over-terrain reference frame.
send_key 0x1B "esc-options"
sleep 2
shoot "frame-100"

# Resume Mission button at client ~(215, 273) under the cnc-ddraw windowed
# layout (TIM-740 scanline-double); see wine-allied-l1.sh for derivation.
send_click 215 273 "resume-mission"
sleep 7
shoot "frame-250"

# Frame 500 ≈ 33 s after mission start at 15 TPS. Wait 17 s more from
# frame-250 (10 s mark) to reach the ~33 s mark.
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
		echo " PASS frame-500.png is non-black Soviet L1 (≥5 KB and ≥64 colours)"
	else
		echo " FAIL frame-500.png does not meet thresholds (need ≥5 KB and ≥64 colours)"
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
		echo " $name.png — $sz bytes, $nc colours"
	else
		echo " $name.png — MISSING"
	fi
done

echo
if [[ "$PASS" -eq 1 ]]; then
	echo "RESULT: PASS — frame-500 shows non-black Soviet L1 terrain"
	exit 0
else
	echo "RESULT: FAIL — see $ARTIFACT_DIR/wine.log"
	exit 1
fi
