#!/usr/bin/env bash
# TIM-869 — Drive C&C95.EXE into GDI Mission 2 under headless Wine and
# capture mission-start + frame-500 reference screenshots.
#
# How: td-scenario-patch.py replaces the "SC%c%02d%c%c.INI" format string
# at 0xdb375 with fixed "SCG02EA.INI" so Set_Scenario_Name always loads GDI M2.
# IsFromInstall=true + side-select GDI + VQA-skipped briefing = direct entry.
#
# Outputs in $ARTIFACT_DIR (default: e2e/tim869/gdi-m2/):
#   mission-start.png, frame-500.png, wine.log, xvfb.log, openbox.log
#
# Exit 0 if frame-500.png >=5 KB and >=64 unique colours.
set -euo pipefail

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim869-gdi-m2}"
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw-master}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/tim869/gdi-m2}"
SCENARIO="${SCENARIO:-SCG02EA}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool missing"; exit 1; }
done
[[ -f "$TD_EXE_PATH" ]] || { echo "FAIL: $TD_EXE_PATH missing"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || { echo "FAIL: cnc-ddraw missing at $CNC_DDRAW_DIR/ddraw.dll"; exit 1; }
echo "  wine: $($WINE --version)  scenario: $SCENARIO  cnc-ddraw: $CNC_DDRAW_DIR/ddraw.dll"

pick_display() {
    for d in 86 87 88 89 90 92 93 94 96 97 98; do
        [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]] && { echo ":$d"; return; }
    done
    echo "no free display" >&2; exit 1
}
XDISP="${XDISP:-$(pick_display)}"
echo "  display: $XDISP  artifacts: $ARTIFACT_DIR"

# Stage
STAGE=$(mktemp -d "/tmp/tim869-gdi-m2-XXXX")
trap 'rm -rf "$STAGE"' EXIT
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$TD_EXE_PATH" "$STAGE/C&C95.EXE"

# Patch chain
echo "=== applying binary patches ==="
python3 "$THIS_DIR/td-focus-skip-patch.py"      "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-game-in-focus-patch.py"   "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-vqa-skip-patch.py"        "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-activateapp-patch.py"     "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-ddmode-patch.py"          "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-setcoop-hwnd-patch.py"    "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-ioport-patch.py"          "$STAGE/C&C95.EXE"
python3 "$THIS_DIR/td-side-preview-skip-patch.py" "$STAGE/C&C95.EXE"
echo "  td-scenario-patch.py: $SCENARIO"
python3 "$THIS_DIR/td-scenario-patch.py" "$STAGE/C&C95.EXE" "$SCENARIO"
echo "  final sha256: $(sha256sum "$STAGE/C&C95.EXE" | cut -d' ' -f1)"

printf 'GDI95' > "$STAGE/.windows-label"
[[ -f "$TD_DLL_DIR/THIPX32.DLL" ]] && cp "$TD_DLL_DIR/THIPX32.DLL" "$STAGE/THIPX32.DLL"

# cnc-ddraw
cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat > "$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
keytogglefullscreen=0x00
EOF

# TEMPERAT.PAL
python3 - "$DATA_DIR/TEMPERAT.MIX" "$STAGE/TEMPERAT.PAL" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    data = f.read()
num_files = struct.unpack_from('<H', data, 0)[0]
body_offset = 6 + num_files * 12
for i in range(num_files):
    off = 6 + i * 12
    _, foff, fsize = struct.unpack_from('<III', data, off)
    if fsize == 768:
        pal = data[body_offset + foff:body_offset + foff + 768]
        with open(sys.argv[2], 'wb') as f: f.write(pal)
        break
PYEOF

printf '[Options]\r\nIsFromInstall=true\r\nPlayIntro=No\r\n' > "$STAGE/CONQUER.INI"
for n in $(seq 1 15); do touch "$STAGE/GDI${n}PRE.VQP" "$STAGE/GDI${n}.VQP"; done
for n in $(seq 1 12); do touch "$STAGE/NOD${n}PRE.VQP" "$STAGE/NOD${n}.VQP"; done
for f in INTRO.VQP SCORE.VQP NODEND1.VQP NODEND2.VQP GDIFINAL.VQP; do touch "$STAGE/$f"; done

# Wine prefix
if [[ ! -d "$WINEPREFIX" ]]; then
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all "$WINE" wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# Xvfb + openbox
echo "=== starting Xvfb + openbox on $XDISP ==="
Xvfb "$XDISP" -screen 0 1024x768x24 -ac > "$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox > "$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

cleanup() {
    [[ -n "${TD_PID:-}" ]] && kill "$TD_PID" 2>/dev/null || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    [[ -n "${WM_PID:-}" ]] && kill "$WM_PID" 2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

# Launch
echo "=== launching C&C95.EXE ==="
(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= \
        WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 180 "$WINE" 'C&C95.EXE'
) > "$ARTIFACT_DIR/wine.log" 2>&1 &
TD_PID=$!

echo "  waiting for C&C window..."
for i in $(seq 1 30); do
    if WID=$(DISPLAY="$XDISP" xdotool search --name "Command & Conquer" 2>/dev/null | head -1); then
        [[ -n "$WID" ]] && { echo "  window after ${i}s (wid=$WID)"; break; }
    fi
    sleep 1
done

TD_SENDINPUT="${TD_SENDINPUT:-$THIS_DIR/../tools/wine-input/td-sendinput.exe}"

WIN_OX=0; WIN_OY=22
resolve_origin() {
    local wid geom wx wy wh title_h
    wid=$(DISPLAY="$XDISP" xdotool search --name "Command & Conquer" 2>/dev/null | head -1)
    [[ -z "$wid" ]] && return
    geom=$(DISPLAY="$XDISP" xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || return
    wx=$(echo "$geom" | grep '^X=' | cut -d= -f2)
    wy=$(echo "$geom" | grep '^Y=' | cut -d= -f2)
    wh=$(echo "$geom" | grep '^HEIGHT=' | cut -d= -f2)
    title_h=$(( ${wh:-422} - 400 ))
    [[ $title_h -lt 0 || $title_h -gt 80 ]] && title_h=22
    WIN_OX=${wx:-0}
    WIN_OY=$(( ${wy:-0} + title_h ))
}

xdo_click() {
    local sx=$(( WIN_OX + $1 )) sy=$(( WIN_OY + $2 ))
    DISPLAY="$XDISP" xdotool mousemove "$sx" "$sy" click 1 2>/dev/null || true
    sleep 0.5
}

inject_key() {
    [[ -f "$TD_SENDINPUT" ]] || return
    DISPLAY="$XDISP" WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDEBUG=-all "$WINE" "$TD_SENDINPUT" key "$1" 2>/dev/null || true
}

shoot() {
    local png="$ARTIFACT_DIR/$1.png"
    DISPLAY="$XDISP" ffmpeg -nostdin -loglevel error \
        -f x11grab -video_size 1024x768 -i "$XDISP" -frames:v 1 -y "$png" 2>/dev/null || true
    if [[ -f "$png" ]]; then
        local sz=$(stat -c%s "$png")
        local nc=$(python3 -c "from PIL import Image; print(len(set(Image.open('$png').convert('RGB').getdata())))" 2>/dev/null || echo "?")
        echo "  $1: ${sz}B ${nc}colours"
    else
        echo "  $1: FAILED"
    fi
}

# Capture
echo "=== capture ==="
sleep 5
shoot "t05-initial"
kill -0 $TD_PID 2>/dev/null || { echo "FAIL: TD died early"; exit 3; }
resolve_origin

# Phase 1: advance to side-select
sleep 2; inject_key 0x0D; sleep 1; inject_key 0x0D; sleep 1; inject_key 0x20; sleep 5
shoot "t10-pre-side"

# Phase 2: click GDI side (left half, centre ~160,180)
xdo_click 160 180; sleep 3
shoot "t15-post-gdi-click"

# Phase 3: advance briefing -> mission
xdo_click 320 200; sleep 2; inject_key 0x0D; sleep 2; inject_key 0x0D; sleep 5
shoot "t25-mission-start"

# Phase 4: gameplay frames (TD 15 Hz, frame-500 ~33s)
sleep 5; shoot "t35-frame100"
sleep 10; shoot "t50-frame250"
sleep 20; shoot "t75-frame500"

# Validate
echo "=== validation ==="
TARGET="$ARTIFACT_DIR/t75-frame500.png"
if [[ -f "$TARGET" ]]; then
    sz=$(stat -c%s "$TARGET")
    nc=$(python3 -c "from PIL import Image; print(len(set(Image.open('$TARGET').convert('RGB').getdata())))" 2>/dev/null || echo "0")
    echo "  frame-500: ${sz}B ${nc}colours"
    if [[ "$sz" -ge 5000 && "$nc" -ge 64 ]]; then
        echo "RESULT: PASS - GDI M2 ($SCENARIO)"
        exit 0
    fi
fi
echo "RESULT: FAIL"
exit 1
