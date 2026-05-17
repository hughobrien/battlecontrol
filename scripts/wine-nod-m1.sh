#!/usr/bin/env bash
# TIM-905 — Drive C&C95.EXE into Nod Mission 1 under headless Wine.
#
# Reuses the same rendering strategy as wine-gdi-m1.sh (TIM-724):
#   cnc-ddraw (ddraw=n, renderer=gdi, windowed=true) + Xvfb + openbox.
#
# Differs from wine-gdi-m1.sh
# ──────────────────────────
#   Phase 2: clicks the Nod portrait (right half, ~480,180) instead of
#   GDI portrait (left half, ~160,180) on the side-select screen.
#   Phase 4: clicks the Nod M1 campaign node on the strategic map.
#   Nod M1 is in Libya/Egypt on the world map — south-east of the GDI
#   Germany node at (110,175).  Estimated Nod M1 node: ~(380,250).
#
# Outputs in $ARTIFACT_DIR (default: e2e/report/data/wine-td-nod-m1/):
#   t05-initial.png, t10-pre-side.png, t15-post-nod-click.png,
#   t25-briefing-advance.png, t35-post-map.png,
#   t45-frame100.png, t60-frame250.png, t90-frame500.png,
#   wine.log xvfb.log openbox.log
#
# Exit:
#   0 on clean completion; non-zero if binary/tooling missing.
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim905-nod-m1}"
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/report/data/wine-td-nod-m1}"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# ─── Preflight ───────────────────────────────────────────────────────────────

echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool missing"; exit 1; }
done
[[ -f "$TD_EXE_PATH" ]] || { echo "FAIL: $TD_EXE_PATH missing"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || {
    echo "FAIL: cnc-ddraw missing at $CNC_DDRAW_DIR/ddraw.dll"
    exit 1
}

echo "  wine:       $($WINE --version)"
echo "  exe:        $TD_EXE_PATH ($(sha256sum "$TD_EXE_PATH" | cut -c1-12)...)"
echo "  ddraw:      cnc-ddraw (ddraw=n, renderer=gdi)"
echo "  prefix:     $WINEPREFIX"
echo "  data:       $DATA_DIR"
echo "  artifacts:  $ARTIFACT_DIR"

# ─── Pick free X display ─────────────────────────────────────────────────────

pick_display() {
    for d in 91 92 93 94 95 96 97 98; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"; return
        fi
    done
    echo "no free display" >&2; exit 1
}
XDISP="${XDISP:-$(pick_display)}"
echo "  display:    $XDISP"

# ─── Stage ───────────────────────────────────────────────────────────────────

STAGE=$(mktemp -d /tmp/tim905-nod-m1-XXXX)

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$TD_EXE_PATH" "$STAGE/C&C95.EXE"

# ─── Binary patches (same chain as wine-gdi-m1.sh) ───────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "  applying TD binary patches..."
python3 "$SCRIPT_DIR/td-focus-skip-patch.py"      "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-game-in-focus-patch.py"   "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-vqa-skip-patch.py"        "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-activateapp-patch.py"     "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-ddmode-patch.py"          "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-setcoop-hwnd-patch.py"    "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-ioport-patch.py"          "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-side-preview-skip-patch.py" "$STAGE/C&C95.EXE"
echo "  patch chain done: $(sha256sum "$STAGE/C&C95.EXE" | cut -c1-12)..."

# Use "NOD95" as .windows-label.  Both "GDI95" and "NOD95" work for CD
# detection since TD ships both factions on a single CD.  The side-select
# click below is what actually picks Nod.
printf 'NOD95' > "$STAGE/.windows-label"
echo "  D: label set to NOD95 via .windows-label"
[[ -f "$TD_DLL_DIR/THIPX32.DLL" ]] && cp "$TD_DLL_DIR/THIPX32.DLL" "$STAGE/THIPX32.DLL"

# ─── cnc-ddraw setup ─────────────────────────────────────────────────────────

cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat > "$STAGE/ddraw.ini" <<'DDRAWINI'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
keytogglefullscreen=0x00
DDRAWINI
echo "  cnc-ddraw installed: $CNC_DDRAW_DIR/ddraw.dll → $STAGE/ddraw.dll"

# TEMPERAT.PAL extraction (same as wine-gdi-m1.sh)
python3 - "$DATA_DIR/TEMPERAT.MIX" "$STAGE/TEMPERAT.PAL" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    data = f.read()
num_files = struct.unpack_from('<H', data, 0)[0]
body_offset = 6 + num_files * 12
for i in range(num_files):
    off = 6 + i * 12
    file_id, file_offset, file_size = struct.unpack_from('<III', data, off)
    if file_size == 768:
        pal_data = data[body_offset + file_offset:body_offset + file_offset + 768]
        with open(sys.argv[2], 'wb') as f:
            f.write(pal_data)
        break
PYEOF
[[ -f "$STAGE/TEMPERAT.PAL" ]] && echo "  TEMPERAT.PAL extracted (768 bytes)" || echo "  WARNING: TEMPERAT.PAL extraction failed"

# CONQUER.INI — IsFromInstall=true skips intro and auto-selects SEL_START_NEW_GAME
printf '[Options]\r\nIsFromInstall=true\r\nPlayIntro=No\r\n' > "$STAGE/CONQUER.INI"

# Stub VQP briefing files (same as wine-gdi-m1.sh)
for n in $(seq 1 15); do
    touch "$STAGE/GDI${n}PRE.VQP" "$STAGE/GDI${n}.VQP"
done
for n in $(seq 1 12); do
    touch "$STAGE/NOD${n}PRE.VQP" "$STAGE/NOD${n}.VQP"
done
for f in INTRO.VQP SCORE.VQP NODEND1.VQP NODEND2.VQP GDIFINAL.VQP; do
    touch "$STAGE/$f"
done
echo "  stub VQP files created"

# ─── Wine prefix + d:=cdrom ──────────────────────────────────────────────────

if [[ ! -d "$WINEPREFIX" ]]; then
    echo "  creating $WINEPREFIX..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        "$WINE" wineboot --init 2>/dev/null
fi
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# ─── Xvfb + openbox ──────────────────────────────────────────────────────────

echo
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

# ─── Launch C&C95.EXE ────────────────────────────────────────────────────────

echo
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

# Wait for the C&C95 game window
echo "  waiting for 'Command & Conquer' window..."
WINDOW_NAME=""
for i in $(seq 1 30); do
    if WID=$(DISPLAY="$XDISP" xdotool search --name "Command & Conquer" 2>/dev/null | head -1); then
        if [[ -n "$WID" ]]; then
            WINDOW_NAME="Command & Conquer"
            echo "  game window appeared after ${i}s (wid=$WID)"
            break
        fi
    fi
    if NAME=$(DISPLAY="$XDISP" xdotool search --onlyvisible --name "." 2>/dev/null | head -1); then
        if [[ -n "$NAME" ]]; then
            WINDOW_NAME=$(DISPLAY="$XDISP" xdotool getwindowname "$NAME" 2>/dev/null || echo "(noname)")
            [[ "$WINDOW_NAME" != "Default IME" ]] && { echo "  window appeared after ${i}s: '$WINDOW_NAME'"; break; }
        fi
    fi
    sleep 1
done

TD_SCREENSHOT="${TD_SCREENSHOT:-$(dirname "$SCRIPT_DIR")/tools/wine-input/td-screenshot.exe}"

shoot() {
    local name="$1"
    local png="$ARTIFACT_DIR/${name}.png"

    # Primary: in-Wine BitBlt capture via td-screenshot.exe.
    local bmp_linux="/tmp/td-shot-${name}.bmp"
    local bmp_wine="Z:$(echo "$bmp_linux" | tr '/' '\\')"
    if [[ -f "$TD_SCREENSHOT" ]]; then
        DISPLAY="$XDISP" WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
            WINEDEBUG=-all \
            "$WINE" "$TD_SCREENSHOT" "$bmp_wine" 2>/dev/null || true
        if [[ -f "$bmp_linux" ]]; then
            python3 -c "
from PIL import Image
Image.open('$bmp_linux').convert('RGB').save('$png')
" 2>/dev/null && rm -f "$bmp_linux" || true
        fi
    fi

    # Fallback: ffmpeg x11grab
    if [[ ! -f "$png" ]]; then
        DISPLAY="$XDISP" ffmpeg -nostdin -loglevel error \
            -f x11grab -video_size 800x600 -i "$XDISP" \
            -frames:v 1 -y "$png" 2>/dev/null || true
    fi

    if [[ -f "$png" ]]; then
        local sz=$(stat -c%s "$png")
        local sha=$(sha256sum "$png" | cut -c1-12)
        local colors
        colors=$(python3 -c "
from PIL import Image
img = Image.open('$png').convert('RGB')
print(len(set(img.getdata())))
" 2>/dev/null || echo "?")
        echo "  shot $name: ${sz}B sha=${sha} colors=${colors}"
    else
        echo "  shot $name: FAILED"
    fi
}

# ─── Input helpers (mirror wine-gdi-m1.sh) ───────────────────────────────────

TD_SENDINPUT="${TD_SENDINPUT:-$(dirname "$SCRIPT_DIR")/tools/wine-input/td-sendinput.exe}"

WIN_OX=0
WIN_OY=22  # fallback titlebar height
resolve_window_origin() {
    local wid
    wid=$(DISPLAY="$XDISP" xdotool search --name "Command & Conquer" 2>/dev/null | head -1)
    if [[ -z "$wid" ]]; then
        echo "  WARN: no Command & Conquer window for origin lookup"
        return
    fi
    local geom
    geom=$(DISPLAY="$XDISP" xdotool getwindowgeometry --shell "$wid" 2>/dev/null) || return
    local wx wy wh
    wx=$(echo "$geom" | grep '^X=' | cut -d= -f2)
    wy=$(echo "$geom" | grep '^Y=' | cut -d= -f2)
    wh=$(echo "$geom" | grep '^HEIGHT=' | cut -d= -f2)
    local title_h=$(( ${wh:-422} - 400 ))
    if [[ $title_h -lt 0 || $title_h -gt 80 ]]; then title_h=22; fi
    WIN_OX=${wx:-0}
    WIN_OY=$(( ${wy:-0} + title_h ))
    echo "  window origin: client=($WIN_OX,$WIN_OY) titlebar=${title_h}px"
}

xdo_click() {
    local gx="$1" gy="$2"
    local sx=$(( WIN_OX + gx ))
    local sy=$(( WIN_OY + gy ))
    echo "  xdo_click game=($gx,$gy) screen=($sx,$sy)"
    DISPLAY="$XDISP" xdotool mousemove "$sx" "$sy" click 1 2>/dev/null || true
    sleep 0.5
}

inject_key() {
    local vk="$1"
    if [[ ! -f "$TD_SENDINPUT" ]]; then
        echo "  (td-sendinput.exe missing — skipping inject)"
        return
    fi
    echo "  inject key vk=$vk"
    DISPLAY="$XDISP" WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDEBUG=-all \
        "$WINE" "$TD_SENDINPUT" key "$vk" 2>/dev/null || true
}

inject_click() {
    local x="$1" y="$2"
    if [[ ! -f "$TD_SENDINPUT" ]]; then
        echo "  (td-sendinput.exe missing — skipping click inject)"
        return
    fi
    echo "  inject click ($x,$y)"
    DISPLAY="$XDISP" WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDEBUG=-all \
        "$WINE" "$TD_SENDINPUT" click "$x" "$y" 2>/dev/null || true
}

# ─── Capture sequence ────────────────────────────────────────────────────────
#
# IsFromInstall=true → SEL_START_NEW_GAME → Choose_Side() side-select screen
# → click Nod → briefing → strategic map → click Nod M1 node → mission start

# Initial settle
sleep 5
shoot "t05-initial"
if ! kill -0 $TD_PID 2>/dev/null; then
    echo "FAIL: TD died early — see $ARTIFACT_DIR/wine.log"
    tail -20 "$ARTIFACT_DIR/wine.log"
    exit 3
fi

# Resolve the window origin
resolve_window_origin

# Phase 1 — advance past any main-menu / install prompt to side-select.
echo "  phase 1: advance to side-select menu..."
sleep 2
inject_key 0x0D
sleep 1
inject_key 0x0D
sleep 1
inject_key 0x20
sleep 5
shoot "t10-pre-side"

# Phase 2 — click Nod side.  Nod portrait is the RIGHT half of the
# 640x400 side-select screen.  GDI portrait centre ≈ (160, 180);
# Nod portrait centre ≈ (480, 180).  Uses xdotool for Win32
# WM_LBUTTONDOWN path (same as GDI click in wine-gdi-m1.sh).
echo "  phase 2: click Nod side..."
xdo_click 480 180
sleep 3
shoot "t15-post-nod-click"

# Phase 3 — advance through briefing prompts to strategic map.
echo "  phase 3: advance through briefing → strategic map..."
xdo_click 320 200
sleep 2
inject_key 0x0D
sleep 2
inject_key 0x0D
sleep 5
shoot "t25-briefing-advance"

# Phase 4 — Nod strategic map.  Nod M1 (Libya/Egypt) is south-east of the
# GDI M1 node (Germany ~110,175).  The Nod campaign starts in North Africa.
# Estimated coordinates: ~(380, 250) in the 640x400 client area.
echo "  phase 4: click Nod M1 strategic-map node..."
xdo_click 380 250
sleep 2
inject_key 0x0D
sleep 5
shoot "t35-post-map"

# Phase 5 — capture gameplay frames.
echo "  phase 5: capture gameplay frames..."
sleep 5
shoot "t45-frame100"
sleep 10
shoot "t60-frame250"
sleep 20
shoot "t90-frame500"

# ─── Final ───────────────────────────────────────────────────────────────────

echo
echo "=== final ==="
echo "  TD alive: $(kill -0 $TD_PID 2>/dev/null && echo yes || echo no)"
DISPLAY="$XDISP" xdotool search --name . 2>/dev/null | while read wid; do
    NAME=$(DISPLAY="$XDISP" xdotool getwindowname "$wid" 2>/dev/null || echo "")
    [[ -n "$NAME" ]] && echo "  window: $NAME"
done

echo
echo "=== screenshots ==="
ls -la "$ARTIFACT_DIR"/*.png 2>/dev/null
echo
echo "=== wine.log tail ==="
tail -30 "$ARTIFACT_DIR/wine.log"

exit 0
