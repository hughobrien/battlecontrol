#!/usr/bin/env bash
# TIM-772 — Capture the RA95 difficulty selector under Wine + Xvfb as the
# reference baseline for the WASM artefact in [TIM-772]. Mirrors the boot
# path of scripts/wine-ra-xvfb-allied-l1.sh but stops after clicking
# "New Campaign" so the difficulty dialog is captured undisturbed.
#
# Usage:
#   bash scripts/wine-ra-difficulty-capture.sh [DATA_DIR] [ARTIFACT_DIR]
#
# Output:
#   $ARTIFACT_DIR/wine-difficulty.png — full Xvfb framebuffer with the
#                                       difficulty dialog centred.
set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
ARTIFACT_DIR="${2:-e2e/screenshots}"
RA_EXE="${RA_EXE_PATH:-/opt/redalert/RA95.EXE}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-ra-xvfb}"
HELPER_SRC="${HELPER_SRC:-$(dirname "$0")/../tools/wine-input/ra-sendinput.c}"
HELPER_BIN="${HELPER_BIN:-/tmp/ra-sendinput.exe}"

pick_display() {
    for d in 91 92 93 94 95 96 97 98 99; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"
            return
        fi
    done
    echo "no free display in :91-:99" >&2; exit 1
}
XDISP="${XDISP:-$(pick_display)}"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

command -v "$WINE" >/dev/null || { echo "FAIL: wine missing"; exit 1; }
command -v Xvfb     >/dev/null || { echo "FAIL: Xvfb missing"; exit 1; }
command -v openbox  >/dev/null || { echo "FAIL: openbox missing"; exit 1; }
command -v ffmpeg   >/dev/null || { echo "FAIL: ffmpeg missing"; exit 1; }
command -v i686-w64-mingw32-gcc >/dev/null || { echo "FAIL: mingw32 missing"; exit 1; }
[[ -f "$RA_EXE" ]] || { echo "SKIP: $RA_EXE missing — run scripts/wine-ra-setup.sh"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR missing"; exit 1; }
[[ -f "$HELPER_SRC" ]] || { echo "FAIL: helper source $HELPER_SRC missing"; exit 1; }

if [[ ! -f "$HELPER_BIN" || "$HELPER_SRC" -nt "$HELPER_BIN" ]]; then
    i686-w64-mingw32-gcc -o "$HELPER_BIN" "$HELPER_SRC" -luser32
fi

STAGE=$(mktemp -d /tmp/wine-ra-difficulty-XXXX)
cleanup() {
    [[ -n "${WINE_PID:-}" ]] && kill "$WINE_PID" 2>/dev/null || true
    [[ -n "${WM_PID:-}"   ]] && kill "$WM_PID"   2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done
cp "$HELPER_BIN" "$STAGE/ra-sendinput.exe"

if [[ ! -d "$WINEPREFIX" ]]; then
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        "$WINE" wineboot --init 2>/dev/null
fi

WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg add \
    'HKCU\Software\Wine\Direct3D' /v renderer /t REG_SZ /d gdi /f 2>/dev/null || true
WINEPREFIX="$WINEPREFIX" wineserver -k 2>/dev/null || true
sleep 1

mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"
cat > "$STAGE/d-cdrom.reg" <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives]
"d:"="cdrom"
EOF
WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all "$WINE" reg import "$STAGE/d-cdrom.reg" 2>/dev/null || true

Xvfb "$XDISP" -screen 0 640x480x24 -ac > "$ARTIFACT_DIR/xvfb.log" 2>&1 &
XVFB_PID=$!
sleep 1
DISPLAY="$XDISP" openbox > "$ARTIFACT_DIR/openbox.log" 2>&1 &
WM_PID=$!
sleep 1

take_shot() {
    local out="$ARTIFACT_DIR/$1"
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 640x480 \
        -i "$XDISP" -frames:v 1 -y "$out" 2>/dev/null \
        && echo "  shot $1 ($(stat -c%s "$out") bytes)" \
        || echo "  shot $1 FAILED"
}

send_input() {
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDEBUG=-all \
        "$WINE" "$STAGE/ra-sendinput.exe" "$@" >> "$ARTIFACT_DIR/helper.log" 2>&1 || true
}

echo "=== launching RA95.EXE ==="
(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 360 "$WINE" RA95.EXE
) > "$ARTIFACT_DIR/wine.log" 2>&1 &
WINE_PID=$!

for i in $(seq 1 30); do
    if DISPLAY="$XDISP" xdotool search --name "^Red Alert$" >/dev/null 2>&1; then
        echo "  RA window present at t=${i}s"; break
    fi
    sleep 1
done

# Settle and dismiss boot dialogs (disk-space, DirectSound, etc.)
sleep 4
take_shot "wine-difficulty-boot.png"
send_input key 0x0D 0          # disk-space OK
sleep 2
send_input key 0x0D 0          # DirectSound OK / second boot dialog
sleep 2
take_shot "wine-difficulty-postdialogs.png"

# Wait for the menu to settle.
sleep 3
take_shot "wine-difficulty-menu.png"

# Click "New Campaign" at (322,183) — same coords as the WASM nav.
send_input seq "s=500;c=322,183@1500"
sleep 4
take_shot "wine-difficulty.png"

echo "=== captured: $ARTIFACT_DIR/wine-difficulty.png ==="
