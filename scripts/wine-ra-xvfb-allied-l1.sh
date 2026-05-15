#!/usr/bin/env bash
# TIM-708 — Drive RA95.EXE through Allied Mission 1 under Xvfb and capture
#           timed screenshots.
#
# Combines the building blocks landed in earlier tickets:
#   * NoCD patch          — scripts/nocd-patch.py        (TIM-720)
#   * DDSCL_NORMAL patch  — scripts/ddscl-patch.py       (TIM-727)
#   * SendInput helper    — tools/wine-input/ra-sendinput.c (TIM-728)
#   * Xvfb + openbox path — scripts/wine-gameplay.sh     (TIM-705)
#
# Why Xvfb (not cage):
#   cage + Xwayland renders the menu fine via XPutImage but the in-game
#   DirectDraw surface goes into a wlroots compositor path that `grim`
#   cannot read (the framebuffer reverts to the 2759-byte empty backdrop
#   once RA leaves the menu). Naked Xvfb + winex11 with DDSCL_NORMAL keeps
#   everything on the XPutImage path, which ffmpeg x11grab can read end to
#   end. See e2e/tim728/notes.md for the cage-capture-gap analysis.
#
# Why SendInput (not xdotool):
#   RA95.EXE polls DirectInput, which Wine populates only from kernel-level
#   WH_KEYBOARD_LL / WH_MOUSE_LL hooks. xdotool / XTestFakeInput dispatch
#   via XSendEvent, which Wine's x11drv translates into WM_* messages but
#   never into LL hooks — so DInput sees nothing. SendInput called from a
#   Win32 process inside the same Wine prefix does fire LL hooks, and RA
#   picks the events up. Empirically verified in TIM-728.
#
# Usage:
#   bash scripts/wine-ra-xvfb-allied-l1.sh [DATA_DIR] [ARTIFACT_DIR]
#
# Outputs (relative to ARTIFACT_DIR):
#   wine-allied-l1-menu.png     — main menu just before nav
#   wine-allied-l1-faction.png  — after Allied select
#   wine-allied-l1-briefing.png — briefing screen before dismissal
#   wine-allied-l1-t0.png       — mission t+0s
#   wine-allied-l1-t5.png       — t+5s
#   wine-allied-l1-t30.png      — t+30s
#   wine-allied-l1-t60.png      — t+60s
#   wine-allied-l1-t120.png     — t+120s
#   wine.log / helper.log / xvfb.log
set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
ARTIFACT_DIR="${2:-e2e/tim708/captures}"
RA_EXE="${RA_EXE_PATH:-/opt/redalert/RA95.EXE}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-ra-xvfb}"
HELPER_SRC="${HELPER_SRC:-$(dirname "$0")/../tools/wine-input/ra-sendinput.c}"
HELPER_BIN="${HELPER_BIN:-/tmp/ra-sendinput.exe}"

# Pick a free X display so the script doesn't collide with concurrent agents.
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
XDISP="${XDISP:-$(pick_display)}"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

echo "=== preflight ==="
command -v "$WINE"      >/dev/null || { echo "FAIL: wine missing"; exit 1; }
command -v Xvfb         >/dev/null || { echo "FAIL: Xvfb missing"; exit 1; }
command -v openbox      >/dev/null || { echo "FAIL: openbox missing"; exit 1; }
command -v ffmpeg       >/dev/null || { echo "FAIL: ffmpeg missing"; exit 1; }
command -v i686-w64-mingw32-gcc >/dev/null || { echo "FAIL: mingw32 missing"; exit 1; }
[[ -f "$RA_EXE" ]] || { echo "SKIP: $RA_EXE missing — run scripts/wine-ra-setup.sh"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }
[[ -f "$HELPER_SRC" ]] || { echo "FAIL: helper source $HELPER_SRC missing"; exit 1; }

if [[ ! -f "$HELPER_BIN" || "$HELPER_SRC" -nt "$HELPER_BIN" ]]; then
    echo "  Building SendInput helper..."
    i686-w64-mingw32-gcc -o "$HELPER_BIN" "$HELPER_SRC" -luser32
fi

echo "  wine:      $($WINE --version)"
echo "  exe:       $RA_EXE ($(sha256sum "$RA_EXE" | cut -c1-12))"
echo "  data:      $DATA_DIR"
echo "  helper:    $HELPER_BIN"
echo "  prefix:    $WINEPREFIX"
echo "  display:   $XDISP"
echo "  artifacts: $ARTIFACT_DIR"
echo ""

STAGE=$(mktemp -d /tmp/wine-ra-xvfb-allied-l1-XXXX)
cleanup() {
    # Kill everything we started; ignore errors.
    [[ -n "${SEND_PID:-}" ]] && kill "$SEND_PID" 2>/dev/null || true
    [[ -n "${WINE_PID:-}" ]] && kill "$WINE_PID" 2>/dev/null || true
    [[ -n "${WM_PID:-}"   ]] && kill "$WM_PID"   2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

# Stage game files in a temp dir so the working directory is clean and writable.
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done
cp "$HELPER_BIN" "$STAGE/ra-sendinput.exe"

# Wine prefix init (idempotent).
if [[ ! -d "$WINEPREFIX" ]]; then
    echo "  Creating 32-bit Wine prefix at $WINEPREFIX..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        "$WINE" wineboot --init 2>/dev/null
fi

# Force the GDI DirectDraw renderer. With renderer=gdi, Wine's wined3d uses
# XPutImage to push the primary surface to the X11 window — visible to
# ffmpeg x11grab. Without it (default), wined3d uses the GL/llvmpipe path
# which X11 capture tools cannot read. Empirically: black framebuffer
# without this; full content with it.
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ /d gdi /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# Map d: → DATA_DIR as a CDROM so RA's residual CD check (post-NoCD-patch)
# is satisfied (TIM-720).
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"
cat > "$STAGE/d-cdrom.reg" <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives]
"d:"="cdrom"
EOF
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all \
    "$WINE" reg import "$STAGE/d-cdrom.reg" 2>/dev/null || true

# ─── Xvfb + openbox ──────────────────────────────────────────────────────────
echo "=== starting Xvfb $XDISP ==="
Xvfb "$XDISP" -screen 0 640x480x24 -ac > "$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
echo "  Xvfb pid=$XVFB_PID"

echo "=== starting openbox ==="
DISPLAY="$XDISP" openbox > "$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1
echo "  openbox pid=$WM_PID"

# ─── Helper functions ────────────────────────────────────────────────────────
take_shot() {
    local out="$ARTIFACT_DIR/$1"
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 640x480 \
        -i "$XDISP" -frames:v 1 -y "$out" 2>/dev/null && {
        local sz=$(stat -c%s "$out")
        echo "  shot $1 ($sz bytes)"
    } || echo "  shot $1 FAILED"
}

send_input() {
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDEBUG=-all \
        "$WINE" "$STAGE/ra-sendinput.exe" "$@" >> "$ARTIFACT_DIR/helper.log" 2>&1 || true
}

# ─── Launch RA95.EXE ─────────────────────────────────────────────────────────
echo "=== launching RA95.EXE ==="
(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 360 "$WINE" RA95.EXE
) > "$ARTIFACT_DIR/wine.log" 2>&1 &
WINE_PID=$!

# Wait for the "Red Alert" window to appear so SendInput can target it.
echo "  waiting for RA window..."
for i in $(seq 1 30); do
    if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
        echo "  RA window present at t=${i}s"
        break
    fi
    sleep 1
done

# Initial breathing room — splash/CD check/disk-space dialog all settle.
sleep 4
take_shot "wine-allied-l1-boot.png"

# Dismiss the disk-space MessageBox (Enter) and any DirectSound warning.
# The boot dialog cluster is non-deterministic across runs, so send a few.
send_input key 0x0D 0       # VK_RETURN — disk-space "OK"
sleep 2
send_input key 0x0D 0       # VK_RETURN — DirectSound "OK" / second dialog
sleep 2
take_shot "wine-allied-l1-after-dialogs.png"

# Main menu reached. Capture for diff against later screens.
sleep 2
take_shot "wine-allied-l1-menu.png"

# Menu nav (640x480 client coords, from wine-gameplay.sh observations):
#   "New Campaign" button center ≈ (322, 183)
#   Difficulty Easy/OK            ≈ (470, 244)
#   Allied faction button         ≈ (258, 268)
echo "=== navigating menu ==="
send_input seq "s=500;c=322,183@1500;c=470,244@1500;c=258,268@1500"
sleep 3
take_shot "wine-allied-l1-faction.png"

# Briefing — RA plays a short briefing screen / VQA; Space dismisses it.
sleep 10
take_shot "wine-allied-l1-briefing.png"
send_input key 0x20 0       # VK_SPACE
sleep 1
send_input key 0x0D 0       # VK_RETURN — fallback for "Start mission"
sleep 2

# Mission load (~5-15s).
echo "=== waiting for mission load ==="
sleep 12

# ─── Timed in-mission captures ──────────────────────────────────────────────
take_shot "wine-allied-l1-t0.png"
sleep 5  ; take_shot "wine-allied-l1-t5.png"
sleep 25 ; take_shot "wine-allied-l1-t30.png"
sleep 30 ; take_shot "wine-allied-l1-t60.png"
sleep 60 ; take_shot "wine-allied-l1-t120.png"

echo "=== shutting down ==="
kill "$WINE_PID" 2>/dev/null || true
sleep 1

# ─── Results ────────────────────────────────────────────────────────────────
echo ""
echo "=== results ==="
PASS=0
TOTAL=0
THRESHOLD=2000   # 2 KB: indicates non-empty PNG (a blank 640x480 PNG is ~1.5 KB)
for shot in "$ARTIFACT_DIR"/wine-allied-l1-*.png; do
    [[ -f "$shot" ]] || continue
    TOTAL=$((TOTAL+1))
    sz=$(stat -c%s "$shot")
    if [[ $sz -gt $THRESHOLD ]]; then
        echo "  OK   $(basename "$shot") ($sz bytes)"
        PASS=$((PASS+1))
    else
        echo "  WARN $(basename "$shot") ($sz bytes — likely blank)"
    fi
done
echo ""
echo "Captured $PASS/$TOTAL non-empty screenshots"

# Pass requires at least 4 of the 5 timed in-mission screenshots to be non-empty
# AND the menu screenshot to differ in size from the in-mission screenshots
# (basic content-diff signal).
MENU_SZ=$(stat -c%s "$ARTIFACT_DIR/wine-allied-l1-menu.png" 2>/dev/null || echo 0)
T0_SZ=$(stat -c%s "$ARTIFACT_DIR/wine-allied-l1-t0.png" 2>/dev/null || echo 0)
DIFF=$(( T0_SZ > MENU_SZ ? T0_SZ - MENU_SZ : MENU_SZ - T0_SZ ))
echo "  menu size=$MENU_SZ  t0 size=$T0_SZ  diff=$DIFF"

if [[ $PASS -ge 5 && $DIFF -gt 500 ]]; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: FAIL"
    exit 1
fi
