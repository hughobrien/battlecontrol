#!/usr/bin/env bash
# Capture RA95.EXE screenshots via cnc-ddraw under Wine + Xvfb.
#
# Bypasses wined3d entirely — no GL context needed. Works on any X server.
#
# Usage:
#   bash scripts/wine-cnc-capture.sh [EXE] [DATA_DIR] [OUT_DIR]
#
# Defaults:
#   EXE:      /opt/redalert/RA95.EXE  (must have NoCD+DDSCL+cdlabel patches)
#   DATA_DIR: /mnt/redalert           (mounted archive.org ISO)
#   OUT_DIR:  e2e/screenshots/cnc
#
# Set TIMED=1 for every-5s capture:  TIMED=1 bash scripts/wine-cnc-capture.sh

set -euo pipefail

RA_EXE="${1:-/opt/redalert/RA95.EXE}"
DATA_DIR="${2:-/mnt/redalert}"
SHOT_DIR="${3:-e2e/screenshots/cnc}"
TIMED="${TIMED:-0}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$SHOT_DIR"

# ─── Build cnc-ddraw if needed ──────────────────────────────────────────────
CNC_DLL=$(nix build .#cnc-ddraw --impure --print-out-paths 2>/dev/null)/bin/ddraw.dll
if [[ ! -f "$CNC_DLL" ]]; then
    echo "Building cnc-ddraw..."
    CNC_DLL=$(nix build .#cnc-ddraw --impure 2>/dev/null --print-out-paths)/bin/ddraw.dll
fi

# ─── Preflight ───────────────────────────────────────────────────────────────
echo "=== cnc-ddraw capture ==="
echo "  exe:  $RA_EXE ($(sha256sum "$RA_EXE" | awk '{print $1}' | head -c 20)...)"
echo "  data: $DATA_DIR"
echo "  dll:  $CNC_DLL"
echo ""

# ─── Staging ────────────────────────────────────────────────────────────────
STAGE="$(mktemp -p /tmp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$RA_EXE" "$STAGE/RA95.EXE"
cp "$CNC_DLL" "$STAGE/DDRAW.DLL"
cp "$REPO/tools/stub-thipx/thipx32.dll" "$STAGE/THIPX32.DLL" 2>/dev/null || true

# Copy MIX files from data directory
cp "$DATA_DIR/MAIN.MIX" "$STAGE/"
if [[ -f "$DATA_DIR/INSTALL/REDALERT.MIX" ]]; then
    cp "$DATA_DIR/INSTALL/REDALERT.MIX" "$STAGE/"
fi

cat >"$STAGE/REDALERT.INI" <<'EOF'
[Sound]
Card=-1
[Options]
HardwareFills=no
[Intro]
PlayIntro=no
EOF

cat >"$STAGE/ddraw.ini" <<'EOF'
[ddraw]
fullscreen=false
windowed=true
no_compat_warning=true
fake_mode=640x400x8
renderer=gdi
EOF

# ─── Wine prefix ────────────────────────────────────────────────────────────
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra-cnc}"
if [[ ! -d "$WINE_PREFIX" ]]; then
    WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null
fi
# Virtual desktop for window positioning
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wine reg add \
    'HKCU\Software\Wine\Explorer\Desktops' \
    /v Default /t REG_SZ /d "640x480" /f >/dev/null 2>&1 || true

# Map CD drive to data dir (needed for Get_CD_Index file-open check)
mkdir -p "$WINE_PREFIX/dosdevices"
rm -f "$WINE_PREFIX/dosdevices/d:"
ln -sfn "$DATA_DIR" "$WINE_PREFIX/dosdevices/d:"
WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --restart 2>/dev/null || true
sleep 4

# ─── Xvfb ────────────────────────────────────────────────────────────────────
DISPLAY=":97"
pkill -f "Xvfb $DISPLAY" 2>/dev/null || true
Xvfb "$DISPLAY" -screen 0 640x480x24 -ac &
sleep 1

# ─── Launch ──────────────────────────────────────────────────────────────────
(
    cd "$STAGE"
    DISPLAY="$DISPLAY" WINEPREFIX="$WINE_PREFIX" \
        WINEDLLOVERRIDES="ddraw=n" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 40 wine RA95.EXE
) >/dev/null 2>&1 &
RA_PID=$!

# Dismiss DirectSound dialog
sleep 8
DISPLAY="$DISPLAY" xdotool key Return 2>/dev/null || true

# ─── Screenshots ─────────────────────────────────────────────────────────────
take_shot() {
    local out="$1"
    if DISPLAY="$DISPLAY" import -window root "$out" 2>/dev/null; then
        sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
        printf "  %-30s %d bytes" "$out" "$sz"
        if [[ $sz -gt 30000 ]]; then echo "  *** GAME ***"
        elif [[ $sz -gt 10000 ]]; then echo "  game progressing"
        elif [[ $sz -gt 3000 ]]; then echo "  dialog"
        else echo "  blank"
        fi
    fi
}

if [[ "$TIMED" == "1" ]]; then
    sleep 3
    for i in 5 10 15 20 25 30; do
        sleep 5
        take_shot "$SHOT_DIR/frame-t${i}s.png"
    done
else
    sleep 3
    take_shot "$SHOT_DIR/wine-cnc-title.png"
    sleep 12
    take_shot "$SHOT_DIR/wine-cnc-menu.png"
fi

kill "$RA_PID" 2>/dev/null || true
wait "$RA_PID" 2>/dev/null || true
