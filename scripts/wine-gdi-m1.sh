#!/usr/bin/env bash
# TIM-724 — Drive C&C95.EXE through GDI Mission 1 under headless Wine.
#
# Rendering strategy (TIM-743 investigation):
#   The C&C95.EXE binary at /opt/tiberiandawn is the CnCNet build.  It uses
#   DDSCL_NORMAL (windowed) rather than DDSCL_EXCLUSIVE|FULLSCREEN, and falls
#   back to its own built-in GDI renderer when Wine's SetDisplayMode fails.
#   This is the correct/simpler path — no cnc-ddraw needed.
#
#   With ddraw=b (Wine builtin):
#     SetCooperativeLevel(NORMAL)   → OK
#     SetDisplayMode(640,400,8)     → DDERR_UNSUPPORTED (Wine can't change mode)
#     → CnCNet binary falls to GDI render path → writes to X window via Win32 GDI
#     → capturable by ffmpeg x11grab
#
#   With ddraw=n (cnc-ddraw):
#     SetDisplayMode succeeds → binary stays in DirectDraw path
#     → primary surface stays black (cnc-ddraw GDI blit never fires for CnCNet binary)
#
#   filesystem:
#     - d:=cdrom registry + staged MIX/INI symlinks
#
#   binary patches (TIM-743):
#     - td-focus-skip-patch.py    NOP 3 GameInFocus spin-loops
#     - td-game-in-focus-patch.py entry-detour pin 0x53dd44=1
#     - td-vqa-skip-patch.py      Play_Movie entry -> ret
#     - td-activateapp-patch.py   NOP WM_ACTIVATEAPP GameInFocus store
#
# Outputs in $ARTIFACT_DIR (default: e2e/tim724/gdi-m1/):
#   t05-initial.png, t10.png, t20.png, t30.png, t60.png, wine.log
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim724-gdi}"
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/tim724/gdi-m1}"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# ─── Preflight ───────────────────────────────────────────────────────────────

echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool missing"; exit 1; }
done
[[ -f "$TD_EXE_PATH" ]] || { echo "FAIL: $TD_EXE_PATH missing"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }

echo "  wine:       $($WINE --version)"
echo "  exe:        $TD_EXE_PATH ($(sha256sum "$TD_EXE_PATH" | cut -c1-12)...)"
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

STAGE=$(mktemp -d /tmp/tim724-gdi-XXXX)

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$TD_EXE_PATH" "$STAGE/C&C95.EXE"

# ─── Binary patches (TIM-743) ─────────────────────────────────────────────────
# Apply TD-specific patches analogous to the RA focus/vqa chain in TIM-708.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "  applying TD binary patches..."
python3 "$SCRIPT_DIR/td-focus-skip-patch.py"      "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-game-in-focus-patch.py"   "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-vqa-skip-patch.py"        "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-activateapp-patch.py"     "$STAGE/C&C95.EXE"
echo "  patch chain done: $(sha256sum "$STAGE/C&C95.EXE" | cut -c1-12)..."
[[ -f "$TD_DLL_DIR/THIPX32.DLL" ]] && cp "$TD_DLL_DIR/THIPX32.DLL" "$STAGE/THIPX32.DLL"

# TEMPERAT.PAL — TD's Init_Game reads this directly (not via MIX) before TEMPERAT.MIX
# is loaded, and MixFileClass::Calculate_CRC produces a different hash than what's stored
# in TEMPERAT.MIX.  Without this file the render loop spins issuing 1M+ failed open()
# calls per run, leaving the primary surface all-black.
# Extract the 768-byte palette entry from TEMPERAT.MIX (offset 57071, id 0x35f90a09).
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

# CRLF CONQUER.INI — TD's PROFILE.CPP uses strchr('\r') so LF-only is silently
# ignored.  (Per TIM-695 memory note.)  IsFromInstall=true skips the intro and
# auto-selects SEL_START_NEW_GAME so the game proceeds without user input.
printf '[Options]\r\nIsFromInstall=true\r\nPlayIntro=No\r\n' > "$STAGE/CONQUER.INI"

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

# TD is a 640x400 game (vs RA's 640x480) — Xvfb screen sized accordingly,
# but with extra headroom for the window manager titlebar.
echo
echo "=== starting Xvfb + openbox on $XDISP ==="
Xvfb "$XDISP" -screen 0 800x600x24 -ac > "$ARTIFACT_DIR/xvfb.log" 2>&1 &
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
#
# ddraw=b: use Wine's builtin ddraw so SetDisplayMode fails, triggering the
# CnCNet binary's own GDI renderer.  With ddraw=n (cnc-ddraw), SetDisplayMode
# succeeds but the primary surface stays black (TIM-743 investigation).

echo
echo "=== launching C&C95.EXE ==="
(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= \
        WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDLLOVERRIDES="ddraw=b;mscoree=;mshtml=" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 180 "$WINE" 'C&C95.EXE'
) > "$ARTIFACT_DIR/wine.log" 2>&1 &
TD_PID=$!

# Wait for a TD window
echo "  waiting for game window..."
WINDOW_NAME=""
for i in $(seq 1 30); do
    if NAME=$(DISPLAY="$XDISP" xdotool search --onlyvisible --name . 2>/dev/null | head -1); then
        if [[ -n "$NAME" ]]; then
            WINDOW_NAME=$(DISPLAY="$XDISP" xdotool getwindowname "$NAME" 2>/dev/null || echo "(noname)")
            echo "  window appeared after ${i}s: '$WINDOW_NAME'"
            break
        fi
    fi
    sleep 1
done

shoot() {
    local name="$1"
    local png="$ARTIFACT_DIR/${name}.png"
    # x11grab captures what Wine's GDI renderer committed to the X window
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 640x400 \
        -i "${XDISP}+0,0" -frames:v 1 -y "$png" 2>/dev/null || true
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
    fi
}

# Initial settle
sleep 5
shoot "t05-initial"
if ! kill -0 $TD_PID 2>/dev/null; then
    echo "FAIL: TD died early — see $ARTIFACT_DIR/wine.log"
    tail -20 "$ARTIFACT_DIR/wine.log"
    exit 3
fi

# Settle into menu / first-render (IsFromInstall auto-starts new game)
sleep 5
shoot "t10"

sleep 10
shoot "t20"

sleep 10
shoot "t30"

sleep 30
shoot "t60"

# Document final state
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
