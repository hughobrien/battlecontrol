#!/usr/bin/env bash
# TIM-740 — verify cnc-ddraw scanline_double fix.
#
# Variant A : patched cnc-ddraw (scanline_double NOT enabled) -- control
# Variant B : patched cnc-ddraw + [ra95] scanline_double=true -- expected fix
#
# Capture two frames and compare odd/even row content.
set -euo pipefail

RA_EXE="${RA_EXE:-/opt/redalert/game/RA95.EXE.focus_orig}"
WINE="${WINE:-/usr/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim732-w10}"
ARTIFACT="${ARTIFACT:-/tmp/tim740/verify}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
DLL_DIR="${DLL_DIR:-/opt/redalert/game}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw-master}"
RUN_SECONDS="${RUN_SECONDS:-20}"

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"
GAME_IN_FOCUS="$THIS_DIR/game-in-focus-patch.py"
CDLABEL_PATCH="$THIS_DIR/cdlabel-patch.py"

rm -rf "$ARTIFACT"
mkdir -p "$ARTIFACT"

pick_display() {
    for d in 91 92 93 94 95 96 97 98 99; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"; return
        fi
    done
    echo "no free display in :91-:99" >&2; exit 1
}

run_variant() {
    local label="$1"
    local ini_extra="$2"
    local out_dir="$ARTIFACT/$label"
    mkdir -p "$out_dir"

    local STAGE
    STAGE=$(mktemp -d /tmp/tim740-verify-${label}-XXXX)

    for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
        [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
    done
    cp "$RA_EXE" "$STAGE/RA95.EXE"
    for dll in THIPX32.DLL THIPX16.DLL; do
        [[ -f "$DLL_DIR/$dll" ]] && cp "$DLL_DIR/$dll" "$STAGE/$dll"
    done
    python3 "$GAME_IN_FOCUS" "$STAGE/RA95.EXE" 2>&1 | tail -2
    python3 "$CDLABEL_PATCH"  "$STAGE/RA95.EXE" 2>&1 | tail -2

    cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
    {
        echo "[ddraw]"
        echo "renderer=gdi"
        echo "windowed=true"
        echo "hook=0"
        if [[ -n "$ini_extra" ]]; then
            echo ""
            echo "$ini_extra"
        fi
    } > "$STAGE/ddraw.ini"

    mkdir -p "$WINEPREFIX/dosdevices"
    ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"

    local XDISP=$(pick_display)
    echo "[$label] display=$XDISP cnc_ddraw=$(md5sum "$STAGE/ddraw.dll" | awk '{print $1}')"
    Xvfb "$XDISP" -screen 0 800x600x24 -ac > "$out_dir/xvfb.log" 2>&1 &
    local XVFB_PID=$!; sleep 1
    DISPLAY="$XDISP" openbox > "$out_dir/openbox.log" 2>&1 &
    local WM_PID=$!; sleep 1

    (
        cd "$STAGE"
        DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
            WINEDLLOVERRIDES="ddraw=n;mscoree=;mshtml=" \
            WINEDEBUG="-all" AUDIODEV=null \
            timeout "$RUN_SECONDS" "$WINE" RA95.EXE
    ) > "$out_dir/wine.log" 2>&1 &
    local WINE_PID=$!

    # Capture every second from t=8 to t=14 so we sample several VQA frames.
    for t in 8 10 12 14; do
        sleep 2
        DISPLAY="$XDISP" ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
            -i "$XDISP" -frames:v 1 -y "$out_dir/t${t}.png" 2>/dev/null || true
        echo "[$label] t${t}: $(stat -c%s "$out_dir/t${t}.png" 2>/dev/null || echo 0) bytes"
    done
    cp "$STAGE/ddraw.ini" "$out_dir/ddraw.ini"
    for raw in "$STAGE"/tim740-pre.raw "$STAGE"/tim740-post.raw; do
        [[ -e "$raw" ]] && cp "$raw" "$out_dir/"
    done

    kill "$WINE_PID" 2>/dev/null || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    kill "$WM_PID" "$XVFB_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    rm -rf "$STAGE"
}

run_variant "A_control"            ""
run_variant "B_scanline_double"    "[ra95]
scanline_double=true"

echo ""
echo "Captures in: $ARTIFACT/"
ls "$ARTIFACT"/*/t12.png
