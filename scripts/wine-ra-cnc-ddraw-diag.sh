#!/usr/bin/env bash
# TIM-732 — Reproducer for the cnc-ddraw + Wine deep-dive findings.
#
# Drives RA95.EXE under Xvfb + openbox with cnc-ddraw 7.5.0 as the DDraw
# wrapper. Designed to be re-runnable so the next pass (GameInFocus pin
# patch) can verify against the same baseline.
#
# Env:
#   WINE              = /opt/wine-devel/bin/wine (Wine 11.8) | /usr/bin/wine (Wine 10.0)
#   WINEPREFIX        = $HOME/.wine-tim732-w11 | $HOME/.wine-tim732-w10
#   RA_EXE            = /opt/redalert/game/RA95.EXE.focus_orig (default; will be focus-skip-patched)
#   RUN_SECONDS       = 25
#   ARTIFACT          = /tmp/tim732/run
#   WINEDEBUG_CHAN    = +dsound,err+all (default)
#   CNC_DDRAW_DIR     = /tmp/cnc-ddraw
#   DATA_DIR          = /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1
#
# Verified findings (see e2e/tim708/notes.md TIM-732 section):
#   Wine 11.8 → bare 640x400 white rectangle (regression)
#   Wine 10.0 → "Red Alert" titled window, black DDraw surface
#   Neither   → renders RA title or menu; root cause = GameInFocus stays FALSE
#                because WM_ACTIVATEAPP is not delivered under openbox-on-Xvfb,
#                and focus-skip-patch.py only NOPs three of seven+ guarded
#                sites in RA's render path.

set -euo pipefail

RA_EXE="${RA_EXE:-/opt/redalert/game/RA95.EXE.focus_orig}"
WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim732}"
RUN_SECONDS="${RUN_SECONDS:-25}"
ARTIFACT="${ARTIFACT:-/tmp/tim732/run}"
WINEDEBUG_CHAN="${WINEDEBUG_CHAN:-+dsound,err+all}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
DLL_DIR="${DLL_DIR:-/opt/redalert/game}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
FOCUS_SKIP="$THIS_DIR/focus-skip-patch.py"
GAME_IN_FOCUS="$THIS_DIR/game-in-focus-patch.py"

[[ -f "$RA_EXE" ]] || { echo "FAIL: $RA_EXE missing"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 2; }
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || { echo "FAIL: cnc-ddraw not at $CNC_DDRAW_DIR"; exit 2; }
# focus-skip-patch.py lands in TIM-708 / PR #135. Run un-patched if missing —
# the TIM-732 repro outcome is unchanged in either state (both stall pre-render).
if [[ ! -f "$FOCUS_SKIP" ]]; then
    echo "warn: $FOCUS_SKIP not present (TIM-708 / PR #135 not merged yet); running un-patched"
    FOCUS_SKIP=""
fi
# game-in-focus-patch.py (TIM-735) pins GameInFocus = TRUE at PE entry so the
# render guard at CONQUER.CPP:2579 fires under headless Wine where
# WM_ACTIVATEAPP is never delivered.
if [[ ! -f "$GAME_IN_FOCUS" ]]; then
    echo "warn: $GAME_IN_FOCUS not present; render guards will stay shut"
    GAME_IN_FOCUS=""
fi
# cdlabel-patch.py (TIM-739) patches _CD_Volume_Label[0] from "CD1" to "" so
# Wine's empty-label D:\ passes Get_CD_Index's label check (CONQUER.CPP:4701).
# Without this, Get_CD_Index spins forever because the CIFS-backed D:\ returns
# an empty volume label and the "CD1" comparison never matches.
CDLABEL_PATCH="$THIS_DIR/cdlabel-patch.py"
if [[ ! -f "$CDLABEL_PATCH" ]]; then
    echo "warn: $CDLABEL_PATCH not present; CD label spin-loop will block rendering"
    CDLABEL_PATCH=""
fi

rm -rf "$ARTIFACT"
mkdir -p "$ARTIFACT"

STAGE=$(mktemp -d /tmp/tim732-cncdiag-XXXX)
echo "wine=$WINE prefix=$WINEPREFIX exe=$RA_EXE stage=$STAGE artifact=$ARTIFACT"

# Stage game files (symlinks for MIX/INI, copy for the EXE we will patch).
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$DLL_DIR/$dll" ]] && cp "$DLL_DIR/$dll" "$STAGE/$dll"
done
if [[ -n "$FOCUS_SKIP" ]]; then
    python3 "$FOCUS_SKIP" "$STAGE/RA95.EXE" 2>&1 | tail -5
fi
if [[ -n "$GAME_IN_FOCUS" ]]; then
    python3 "$GAME_IN_FOCUS" "$STAGE/RA95.EXE" 2>&1 | tail -5
fi
if [[ -n "$CDLABEL_PATCH" ]]; then
    python3 "$CDLABEL_PATCH" "$STAGE/RA95.EXE" 2>&1 | tail -5
fi

# cnc-ddraw drop-in (gdi renderer, windowed, no hook).
cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat > "$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
debug=true
EOF

# Prefix initialisation is idempotent — assume already done.
[[ -d "$WINEPREFIX" ]] || {
    echo "Initialising $WINEPREFIX..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        "$WINE" wineboot --init 2>/dev/null
}
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"
# Register d: as DRIVE_CDROM in the Wine registry so RA's GetDriveType
# check passes.  Without this the prefix treats d: as DRIVE_FIXED and
# the title screen never renders even with the focus-skip + game-in-focus
# + cdlabel chain applied.  (TIM-708 follow-up; was missing in PR #138.)
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

# Pick a free X display so this can run alongside other agents.
pick_display() {
    for d in 91 92 93 94 95 96 97 98 99; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"; return
        fi
    done
    echo "no free display in :91-:99" >&2; exit 1
}
XDISP=$(pick_display)
echo "display=$XDISP"

Xvfb "$XDISP" -screen 0 800x600x24 -ac > "$ARTIFACT/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox > "$ARTIFACT/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

cleanup() {
    [[ -n "${WINE_PID:-}" ]] && kill "$WINE_PID" 2>/dev/null || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    kill "$WM_PID" "$XVFB_PID" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
        WINEDEBUG="$WINEDEBUG_CHAN" AUDIODEV=null \
        timeout "$RUN_SECONDS" "$WINE" RA95.EXE
) > "$ARTIFACT/wine.log" 2>&1 &
WINE_PID=$!

# Wait for the "Red Alert" window.
for i in $(seq 1 20); do
    DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1 && break
    sleep 1
done

# Capture frames at t=5/10/15/20s.
shot() {
    local out="$ARTIFACT/$1"
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
        -i "$XDISP" -frames:v 1 -y "$out" 2>/dev/null || true
    echo "  $1: $(stat -c%s "$out" 2>/dev/null || echo 0) bytes"
}
shot "t5.png"; sleep 5
shot "t10.png"; sleep 5
shot "t15.png"; sleep 5
shot "t20.png"

# Drain ddraw.log if cnc-ddraw produced one.
[[ -f "$STAGE/ddraw.log" ]] && cp "$STAGE/ddraw.log" "$ARTIFACT/ddraw.log"

wait "$WINE_PID" 2>/dev/null || true

# Quick distinguisher: black-surface (Wine 10) vs white-rect (Wine 11).
SZ=$(stat -c%s "$ARTIFACT/t20.png" 2>/dev/null || echo 0)
echo ""
echo "t20 size: $SZ bytes"
if [[ "$SZ" -gt 5500 && "$SZ" -lt 6500 ]]; then
    echo "RESULT: 'Red Alert' titled window with black DDraw surface (Wine 10 expected pattern)."
elif [[ "$SZ" -gt 10000 && "$SZ" -lt 12000 ]]; then
    echo "RESULT: bare white 640x400 rectangle (Wine 11.x regression pattern)."
elif [[ "$SZ" -gt 20000 ]]; then
    echo "RESULT: non-black RA content rendered — title screen or menu visible."
else
    echo "RESULT: unexpected frame size — inspect $ARTIFACT/t20.png."
fi
echo "Captures in: $ARTIFACT/"
