#!/usr/bin/env bash
# TIM-724 — Drive C&C95.EXE through GDI Mission 1 under headless Wine.
#
# Rendering strategy (TIM-743 + TIM-747):
#   The C&C95.EXE binary at /opt/tiberiandawn is the CnCNet build.
#   Uses cnc-ddraw (ddraw=n, renderer=gdi) as the DDraw backend inside a
#   Wine virtual desktop (explorer /desktop=tim724,640x400).
#
#   Why cnc-ddraw (not Wine builtin):
#     Wine builtin DDraw in DDSCL_NORMAL creates the primary surface at the
#     virtual desktop depth (24/32bpp).  TD expects an 8bpp paletted surface.
#     When the game writes 8bpp pixels into a 32bpp surface the pitch is wrong
#     and it crashes.  cnc-ddraw handles the 8→32bpp conversion internally.
#
#   Why no virtual desktop:
#     cnc-ddraw with windowed=true intercepts SetDisplayMode and returns DD_OK
#     without calling NtUserChangeDisplaySettings at all.  So Xvfb's
#     DISP_CHANGE_FAILED limitation is irrelevant.  Running without the
#     virtual desktop gives C&C95.EXE a real top-level X11 window, which
#     x11grab can capture directly via the X11 backing store.
#
#   HWND fix:
#     The CnCNet binary calls SetCooperativeLevel(hwnd=0, DDSCL_NORMAL).
#     cnc-ddraw with hook=1 intercepts CreateWindowExA and records the real
#     HWND; that substitution is transparent.  td-setcoop-hwnd-patch.py adds
#     an additional code-cave that re-issues SetCooperativeLevel with the HWND
#     stored at [0x567848] as a belt-and-suspenders fix.
#
#   CD label fix:
#     .windows-label = "GDI95" in STAGE so Wine's GetVolumeInformationA on D:
#     returns "GDI95"; Get_CD_Index finds D: and Set_Search_Drives adds D:\ to
#     the file search path.  td-cdlabel-patch.py is NOT used (it zeroes GDI95[0]
#     making any empty-label drive match, including C: which Wine checks first).
#
#   Capture: ffmpeg x11grab reads from the virtual desktop's X11 backing store.
#   cnc-ddraw's GDI renderer uses XPutImage to commit frames there.
#
#   binary patches (TIM-743 + TIM-747):
#     - td-focus-skip-patch.py    NOP 3 GameInFocus spin-loops
#     - td-game-in-focus-patch.py entry-detour pin 0x53dd44=1
#     - td-vqa-skip-patch.py      Play_Movie entry -> ret
#     - td-activateapp-patch.py   NOP WM_ACTIVATEAPP GameInFocus store
#     - td-ddmode-patch.py        stub SetDisplayMode → DD_OK (xr eax+NOP pushes)
#     - td-setcoop-hwnd-patch.py  code-cave: SetCooperativeLevel with real HWND
#     - td-ioport-patch.py        NOP VGA port 0x3DA spin-loop (PRIV_INSN flood)
#
# Outputs in $ARTIFACT_DIR (default: e2e/tim724/gdi-m1/):
#   t05-initial.png, t10.png, t20.png, t30.png, t60.png, wine.log
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim724-gdi}"
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw}"
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
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || { echo "FAIL: cnc-ddraw missing at $CNC_DDRAW_DIR/ddraw.dll"; exit 1; }

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

STAGE=$(mktemp -d /tmp/tim724-gdi-XXXX)

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$TD_EXE_PATH" "$STAGE/C&C95.EXE"

# ─── Binary patches (TIM-743 + TIM-747) ──────────────────────────────────────
# Apply TD-specific patches. td-ddmode-patch is NOT used here: cnc-ddraw
# intercepts SetDisplayMode internally and returns DD_OK without calling
# NtUserChangeDisplaySettings, so the ddmode stub is redundant.
# setcoop-hwnd-patch expects the activateapp output SHA directly.
# td-ioport-patch NOPs the VGA port 0x3DA spin-loop that floods the main
# thread with EXCEPTION_PRIV_INSTRUCTION and prevents Init_Game from running.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "  applying TD binary patches..."
python3 "$SCRIPT_DIR/td-focus-skip-patch.py"      "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-game-in-focus-patch.py"   "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-vqa-skip-patch.py"        "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-activateapp-patch.py"     "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-ddmode-patch.py"          "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-setcoop-hwnd-patch.py"    "$STAGE/C&C95.EXE"
python3 "$SCRIPT_DIR/td-ioport-patch.py"          "$STAGE/C&C95.EXE"
echo "  patch chain done: $(sha256sum "$STAGE/C&C95.EXE" | cut -c1-12)..."

# Give D: the volume label "GDI95" so Wine's GetVolumeInformationA returns it.
# td-cdlabel-patch zeroes GDI95[0] → stricmp("","")=0 matches ANY drive with empty
# label, including C:, which Wine checks first.  Wine returns an empty label for C:
# because drive_c has no .windows-label file.  That causes Get_CD_Index to return C:
# instead of D:, so Set_Search_Drives adds C:\ as the CD path, MIX files aren't found
# there, and the game errors/spins before ever calling Flip.
# .windows-label is read by Wine's DOSFS from the root of the mapped host directory.
printf 'GDI95' > "$STAGE/.windows-label"
echo "  D: label set to GDI95 via .windows-label"
[[ -f "$TD_DLL_DIR/THIPX32.DLL" ]] && cp "$TD_DLL_DIR/THIPX32.DLL" "$STAGE/THIPX32.DLL"

# ─── cnc-ddraw setup ─────────────────────────────────────────────────────────
# Copy cnc-ddraw.dll as ddraw.dll so WINEDLLOVERRIDES="ddraw=n" picks it up.
# cnc-ddraw handles 8bpp→32bpp palette conversion internally; the GDI renderer
# commits frames via XPutImage so ffmpeg x11grab can capture them.
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

# Stub VQP briefing files — C&C95 checks file existence in a tight retry loop
# (~21k NtCreateFile/sec) before calling Play_Movie for each briefing video.
# td-vqa-skip-patch patches Play_Movie to return immediately, but the existence-
# check loop fires first.  Creating 0-byte stubs breaks the spin: File_Exists
# returns TRUE, Play_Movie is called and returns immediately, loop exits.
# We stub all GDI (1-15) and NOD (1-12) PRE and mission VQPs so the game
# doesn't re-spin on subsequent briefings.
for n in $(seq 1 15); do
    touch "$STAGE/GDI${n}PRE.VQP" "$STAGE/GDI${n}.VQP"
done
for n in $(seq 1 12); do
    touch "$STAGE/NOD${n}PRE.VQP" "$STAGE/NOD${n}.VQP"
done
# Also stub any transition/outro VQPs
for f in INTRO.VQP SCORE.VQP NODEND1.VQP NODEND2.VQP GDIFINAL.VQP; do
    touch "$STAGE/$f"
done
echo "  stub VQP files created (all GDI/NOD mission briefings)"

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

# TD is 640x400; 800x600 gives headroom for the window manager titlebar.
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
# ddraw=n: use the native (cnc-ddraw) ddraw.dll we copied into STAGE.
# cnc-ddraw handles 8bpp→32bpp palette conversion internally and uses the GDI
# renderer (XPutImage) so ffmpeg x11grab can capture real game frames.
# td-setcoop-hwnd-patch rewrites the DDSCL_NORMAL preamble so SetCooperativeLevel
# receives the real HWND from [0x567848] instead of hwnd=0 (belt-and-suspenders).
# No virtual desktop needed — cnc-ddraw with windowed=true intercepts
# SetDisplayMode internally without calling NtUserChangeDisplaySettings.

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
    # Also accept any visible window in case the title differs
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
    # cnc-ddraw's GDI renderer does BitBlt from its backbuffer to the game
    # HWND's DC; capturing via another Win32 BitBlt reads that same DC.
    # Z: = Linux root in Wine; path must use backslashes.
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

    # Fallback: ffmpeg x11grab from X11 backing store (captures desktop chrome).
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

# ─── SendInput helper ────────────────────────────────────────────────────────
# Inject synthetic keypresses into the TD window via a Wine-side helper.
# td-sendinput.exe uses SendInput which fires WH_KEYBOARD_LL hooks that
# DirectInput reads — xdotool/XTest events do NOT reach DInput.
TD_SENDINPUT="${TD_SENDINPUT:-$(dirname "$SCRIPT_DIR")/tools/wine-input/td-sendinput.exe}"
inject_key() {
    local vk="$1"
    if [[ ! -f "$TD_SENDINPUT" ]]; then
        echo "  (td-sendinput.exe missing at $TD_SENDINPUT — skipping inject)"
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

# Initial settle
sleep 5
shoot "t05-initial"
if ! kill -0 $TD_PID 2>/dev/null; then
    echo "FAIL: TD died early — see $ARTIFACT_DIR/wine.log"
    tail -20 "$ARTIFACT_DIR/wine.log"
    exit 3
fi

# Dismiss the GDI01 mission briefing and any main-menu prompts.
# The briefing in TD requires a click or Enter/Space to advance.
# IsFromInstall=true causes the game to auto-select "Start New Game" and
# land on the side select / briefing screen requiring one keypress.
echo "  injecting keypresses to advance past briefing..."
sleep 2
inject_key 0x0D   # Enter — advance past any main-menu prompt
sleep 1
inject_key 0x0D   # Enter — advance past side-select or briefing
sleep 1
inject_click 320 200  # click centre of screen (fallback for click-to-advance)
sleep 1
inject_key 0x20   # Space — additional advance

# Settle into menu / first-render
sleep 5
shoot "t10"

# Second injection in case briefing needs multiple dismisses
inject_key 0x0D
sleep 1
inject_click 320 200
sleep 8
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
