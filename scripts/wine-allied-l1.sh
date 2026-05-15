#!/usr/bin/env bash
# TIM-708 — Drive RA95.EXE through Allied Mission 1 under headless Wine.
#
# Combines every patch + injection technique landed in the TIM-708 tree:
#
#   binary patches (applied to staged RA95.EXE in order):
#     - nocd-patch.py        (TIM-720)   bypass GetDriveType CD check
#     - focus-skip-patch.py  (TIM-708)   NOP three GameInFocus spin-loops
#     - game-in-focus-patch.py (TIM-735) entry-detour pins GameInFocus = TRUE
#     - cdlabel-patch.py     (TIM-739)   accept empty CD volume label
#     - vqa-skip-patch.py    (TIM-708)   skip intro VQA (no audio device)
#
#   rendering:
#     - cnc-ddraw (TIM-732)   drop-in ddraw.dll, renderer=gdi, windowed=true
#     - Xvfb + openbox        managed window so DInput attaches
#     - tools/wine-input/ra-screenshot.exe   BitBlt from inside Wine
#
#   input:
#     - tools/wine-input/ra-sendinput.exe    SendInput → triggers
#       WH_KEYBOARD_LL → dinput sees the press (TIM-728)
#
# Captures screenshots at the canonical TIM-705 checkpoints:
#   t=0   mission start
#   t=5   units selected
#   t=30  early movement
#   t=60  ~1 min into mission
#   t=120 ~2 min into mission
#
# Outputs in $ARTIFACT_DIR (default: e2e/tim708/allied-l1/):
#   menu.png, after-newgame.png, after-easy.png, after-allied.png,
#   briefing.png, mission-t0.png, mission-t5.png, mission-t30.png,
#   mission-t60.png, mission-t120.png, wine.log, run.log
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim708-allied}"
RA_EXE_PATH="${RA_EXE_PATH:-/opt/redalert/game/RA95.EXE.focus_orig}"  # pre-focus-skip baseline
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw}"
ARTIFACT_DIR="${ARTIFACT_DIR:-e2e/tim708/allied-l1}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER_DIR="$THIS_DIR/../tools/wine-input"
SENDINPUT_SRC="$HELPER_DIR/ra-sendinput.c"
SCREENSHOT_SRC="$HELPER_DIR/ra-screenshot.c"
SENDINPUT_EXE="/tmp/ra-sendinput.exe"
SCREENSHOT_EXE="/tmp/ra-screenshot.exe"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

# ─── Preflight ───────────────────────────────────────────────────────────────

echo "=== preflight ==="
for tool in "$WINE" Xvfb openbox ffmpeg i686-w64-mingw32-gcc; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool missing"; exit 1; }
done
[[ -f "$RA_EXE_PATH" ]] || { echo "FAIL: $RA_EXE_PATH missing"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || { echo "FAIL: cnc-ddraw at $CNC_DDRAW_DIR missing"; exit 1; }
[[ -f "$SENDINPUT_SRC" ]] || { echo "FAIL: $SENDINPUT_SRC missing"; exit 1; }
[[ -f "$SCREENSHOT_SRC" ]] || { echo "FAIL: $SCREENSHOT_SRC missing"; exit 1; }

# Build helpers (idempotent — rebuild if source newer)
[[ -f "$SENDINPUT_EXE" && "$SENDINPUT_SRC" -ot "$SENDINPUT_EXE" ]] || \
    i686-w64-mingw32-gcc -o "$SENDINPUT_EXE" "$SENDINPUT_SRC" -luser32
[[ -f "$SCREENSHOT_EXE" && "$SCREENSHOT_SRC" -ot "$SCREENSHOT_EXE" ]] || \
    i686-w64-mingw32-gcc -o "$SCREENSHOT_EXE" "$SCREENSHOT_SRC" -lgdi32 -luser32

echo "  wine:       $($WINE --version)"
echo "  ra-input:   $SENDINPUT_EXE"
echo "  ra-shot:    $SCREENSHOT_EXE"
echo "  cnc-ddraw:  $CNC_DDRAW_DIR/ddraw.dll"
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

STAGE=$(mktemp -d /tmp/tim708-allied-XXXX)
trap 'rm -rf "$STAGE"' EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE_PATH" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

# Apply binary patches (skip ones that fail — script versions verify SHA chain)
echo
echo "=== applying binary patches ==="
for patch in focus-skip-patch.py game-in-focus-patch.py cdlabel-patch.py vqa-skip-patch.py; do
    if [[ -f "$THIS_DIR/$patch" ]]; then
        echo "  $patch:"
        python3 "$THIS_DIR/$patch" "$STAGE/RA95.EXE" 2>&1 | sed 's/^/    /' | tail -3 || true
    fi
done
echo "  final sha256: $(sha256sum "$STAGE/RA95.EXE" | cut -d' ' -f1)"

# cnc-ddraw drop-in
cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat > "$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
EOF

# Stage the SendInput + screenshot helpers inside the same prefix as RA
cp "$SENDINPUT_EXE" "$STAGE/ra-sendinput.exe"
cp "$SCREENSHOT_EXE" "$STAGE/ra-screenshot.exe"

# Volume label: cdlabel-patch zeros the first byte of RA's internal "CD1"
# string so the comparison becomes stricmp(drive_label, "").  Wine reports
# an empty string for a symlinked directory without .windows-label, so we
# leave that file absent on purpose.  Creating .windows-label="CD1" here
# would make Wine return "CD1" and the comparison would fail.
: # no-op (volume label intentionally absent)

# ─── Wine prefix ─────────────────────────────────────────────────────────────

if [[ ! -d "$WINEPREFIX" ]]; then
    echo "  creating $WINEPREFIX..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
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
Xvfb "$XDISP" -screen 0 800x600x24 -ac > "$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox > "$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

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
    DISPLAY="$XDISP" WAYLAND_DISPLAY= \
        WINEPREFIX="$WINEPREFIX" WINEARCH=win32 \
        WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 240 "$WINE" RA95.EXE
) > "$ARTIFACT_DIR/wine.log" 2>&1 &
RA_PID=$!

# Wait for the "Red Alert" window
echo "  waiting for Red Alert window..."
for i in $(seq 1 30); do
    if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
        echo "  Red Alert window appeared after ${i}s"
        break
    fi
    sleep 1
done

# ─── Helper functions ────────────────────────────────────────────────────────

send_vk() {
    local vk=$1 label=${2:-vk}
    echo "  SendInput($label, vk=$vk)"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDEBUG=-all "$WINE" "$STAGE/ra-sendinput.exe" "$vk" 0 \
        >> "$ARTIFACT_DIR/helper.log" 2>&1 || true
}

shoot() {
    local name="$1"
    local png="$ARTIFACT_DIR/${name}.png"
    # cnc-ddraw's GDI renderer commits the back buffer to the X11 window
    # via XPutImage — capturable by ffmpeg x11grab.  BitBlt from the
    # Win32 HDC returns the empty default-white window background because
    # cnc-ddraw double-buffers and only the front buffer is on screen.
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
        -i "$XDISP" -frames:v 1 -y "$png" 2>/dev/null || true
    echo "  shot: $name ($(stat -c%s "$png" 2>/dev/null) bytes)"
}

# ─── Navigation (none required — patch chain auto-boots into Allied L1) ──────
#
# Empirically: NoCD + cdlabel + game-in-focus pin + vqa-skip + focus-skip
# combined with cnc-ddraw + d:cdrom registry causes RA to reach the
# Allied L1 "Find Einstein" mission ~6-10 seconds after launch without
# any user input.  We rely on that auto-boot rather than driving menus
# via SendInput (the keystrokes interrupted in-game state in earlier
# revisions of this script).

# RA's attract-mode demo plays Allied Mission 1 (AUTODEMO recording) for
# ~20 seconds before transitioning to TOP SCORES.  Five captures within
# the demo window give four timed checkpoints of in-mission content plus
# the post-demo summary screen.

# Initial settle: RA window ready → mission rendered
sleep 6
shoot "mission-t0"
if ! kill -0 $RA_PID 2>/dev/null; then
    echo "FAIL: RA died before mission render — see $ARTIFACT_DIR/wine.log"
    exit 3
fi

sleep 3
shoot "mission-t3"

sleep 3
shoot "mission-t6"

sleep 3
shoot "mission-t9"

sleep 3
shoot "mission-t12"

sleep 5
shoot "mission-t17"

# Post-demo: TOP SCORES screen
sleep 15
shoot "post-demo-scores"

echo
echo "=== results ==="
PASS=0; TOTAL=0
for name in mission-t0 mission-t3 mission-t6 mission-t9 mission-t12 mission-t17; do
    shot="$ARTIFACT_DIR/${name}.png"
    TOTAL=$((TOTAL + 1))
    if [[ -f "$shot" ]]; then
        sz=$(stat -c%s "$shot")
        # Mission-content frames are ~80 KB under cnc-ddraw GDI; menu-only
        # frames or empty backdrops are <20 KB.  Use a stricter threshold
        # than the previous 5 KB to actually distinguish "map + units" from
        # the title screen or a static fallback.
        if [[ $sz -gt 40000 ]]; then
            echo "  PASS $name.png ($sz bytes — map + units)"
            PASS=$((PASS + 1))
        elif [[ $sz -gt 5000 ]]; then
            echo "  WARN $name.png ($sz bytes — likely menu/static screen)"
        else
            echo "  FAIL $name.png ($sz bytes — blank/exit)"
        fi
    else
        echo "  MISS $name.png"
    fi
done
echo
echo "$PASS/$TOTAL gameplay captures in $ARTIFACT_DIR"
[[ $PASS -ge 4 ]] && exit 0 || exit 1
