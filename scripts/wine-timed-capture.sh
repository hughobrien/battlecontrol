#!/usr/bin/env bash
# TIM-xxx — Wine OG timed capture using cnc-ddraw (no wined3d dependency)
# Runs RA95.EXE under Wine+Xvfb with cnc-ddraw replacing wined3d ddraw.
set -euo pipefail

RA_EXE="${1:-/opt/redalert/RA95.EXE}"
DATA_DIR="${2:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
SHOT_DIR="${3:-e2e/screenshots/timed}"
WINE_PREFIX="${WINE_PREFIX:-$HOME/.wine-ra-cnc}"
DISPLAY_NUM=":99"
STUB_DLL="$(cd "$(dirname "$0")/.." && pwd)/tools/stub-thipx/thipx32.dll"

mkdir -p "$SHOT_DIR"

# Build/source cnc-ddraw from upstream
CNC_DLL=""
if CNC_PATH=$(nix build .#cnc-ddraw --impure --print-out-paths 2>/dev/null); then
    CNC_DLL="$CNC_PATH/bin/ddraw.dll"
fi
if [[ ! -f "$CNC_DLL" ]]; then
    echo "Building cnc-ddraw from upstream GitHub (Nix)..."
    CNC_DLL="$(nix build .#cnc-ddraw --impure 2>/dev/null --print-out-paths)/bin/ddraw.dll"
fi

# ─── Staging ────────────────────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"; pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true' EXIT

for f in "$DATA_DIR"/*.MIX; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cat >"$STAGE/REDALERT.INI" <<'EOF'
[Sound]
Card=0
Port=3F8h
IRQ=4
DMA=-1
[Options]
HardwareFills=no
EOF

cp "$RA_EXE" "$STAGE/RA95.EXE"
cp "$CNC_DLL" "$STAGE/DDRAW.DLL"
cp "$STUB_DLL" "$STAGE/THIPX32.DLL"

# ─── Wine prefix (create once) ──────────────────────────────────────────────
if [[ ! -d "$WINE_PREFIX" ]]; then
    WINEPREFIX="$WINE_PREFIX" WINEDEBUG=-all wineboot --init 2>/dev/null
fi

# ─── Xvfb ───────────────────────────────────────────────────────────────────
echo "Starting Xvfb $DISPLAY_NUM..."
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null || true
Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
sleep 1

# ─── Launch RA ──────────────────────────────────────────────────────────────
echo "Launching RA95.EXE with cnc-ddraw..."
(
    cd "$STAGE"
    DISPLAY="$DISPLAY_NUM" WINEPREFIX="$WINE_PREFIX" \
        WINEDEBUG=-all AUDIODEV=null \
        timeout 40 wine RA95.EXE
) >/tmp/wine-cnc-timed.log 2>&1 &
RA_PID=$!

# ─── Timed screenshots ──────────────────────────────────────────────────────
for i in 5 10 15 20 25 30; do
    sleep 5
    out="$SHOT_DIR/frame-t${i}s.png"
    if DISPLAY="$DISPLAY_NUM" import -window root "$out" 2>/dev/null; then
        sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
        printf "  t=%02ds  %d bytes\n" "$i" "$sz"
    else
        printf "  t=%02ds  FAILED\n" "$i"
    fi
done

kill "$RA_PID" 2>/dev/null || true
wait "$RA_PID" 2>/dev/null || true
echo ""
echo "=== Results ==="
python3 -c "
from PIL import Image
import os, glob
for f in sorted(glob.glob('$SHOT_DIR/frame-*.png')):
    im = Image.open(f)
    colors = len(im.getcolors()) if im.getcolors() else ('many' if im.mode == 'RGB' else 0)
    sz = os.path.getsize(f)
    print(f'  {os.path.basename(f)}: {im.size} {im.mode} {sz}b {'✅' if sz > 1000 else '⚠️blank'}')
"
