#!/usr/bin/env bash
# TIM-719 — RA95.EXE under cage 0.3.0 + Xwayland + winex11.drv.
#
# Why not winewayland.drv: it lacks NtUserChangeDisplaySettings support, so
# DDraw's SetDisplayMode fails (DISP_CHANGE_BADMODE = -2) and the primary
# surface never allocates. winex11.drv accepts the mode change. We run a
# standalone Xwayland as a Wayland client of cage so input still flows
# through the wlroots virtual-pointer/virtual-keyboard protocols.
#
# ─── Prerequisites ───────────────────────────────────────────────────────────
# * cage 0.3.0      — from scripts/build-cage-headless.sh
# * wine-devel 11.8 — apt install wine-devel + wine-devel-i386:i386
# * Xwayland        — apt install xwayland (24.1.6+)
# * RA95.EXE + MIX data + THIPX32/16.DLL — see scripts/wine-ra-setup.sh
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#    bash scripts/wine-ra-cage.sh [DATA_DIR] [SCREENSHOT_DIR]
#
#    DATA_DIR        CD1 data directory   (default: /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1)
#    SCREENSHOT_DIR  output dir           (default: e2e/screenshots)
#
# ─── Outputs ─────────────────────────────────────────────────────────────────
#    $SCREENSHOT_DIR/wine-ra-cage-t6.png   — CD prompt or main menu (~6s)
#    $SCREENSHOT_DIR/wine-ra-cage-t18.png  — later state             (~18s)

set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
SCREENSHOT_DIR="${2:-e2e/screenshots}"
RA_EXE="${RA_EXE_PATH:-/opt/redalert/RA95.EXE}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-ra-wayland}"
CAGE="${CAGE:-/usr/local/bin/cage}"
XDISPLAY="${XDISPLAY:-:99}"

mkdir -p "$SCREENSHOT_DIR"

echo "=== preflight ==="
command -v "$WINE" >/dev/null || { echo "FAIL: wine not at $WINE"; exit 1; }
command -v "$CAGE" >/dev/null || { echo "FAIL: cage not at $CAGE — run scripts/build-cage-headless.sh"; exit 1; }
command -v Xwayland >/dev/null || { echo "FAIL: Xwayland not installed — apt install xwayland"; exit 1; }
[[ -f "$RA_EXE" ]] || { echo "SKIP: $RA_EXE not found — run scripts/wine-ra-setup.sh"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: data dir $DATA_DIR not found"; exit 1; }

echo "  wine: $($WINE --version)"
echo "  cage: $($CAGE -v 2>&1 | head -1)"
echo "  exe:  $RA_EXE"
echo "  data: $DATA_DIR"
echo ""

STAGE=$(mktemp -d)
INNER=$(mktemp /tmp/tim719-inner-XXXX.sh)
trap 'rm -rf "$STAGE" "$INNER"' EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done

if [[ ! -d "$WINEPREFIX" ]]; then
    echo "  Creating 32-bit Wine prefix at $WINEPREFIX..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        "$WINE" wineboot --init 2>/dev/null
fi

cat > "$INNER" <<INNER_EOF
#!/usr/bin/env bash
set -uo pipefail
cd "$STAGE"
Xwayland -geometry 640x480 -decorate "$XDISPLAY" > "$SCREENSHOT_DIR/wine-ra-cage-xwayland.log" 2>&1 &
XWL_PID=\$!
sleep 2
DISPLAY="$XDISPLAY" WAYLAND_DISPLAY= WINEPREFIX="$WINEPREFIX" \\
WINEDLLOVERRIDES="mscoree=;mshtml=" \\
WINEDEBUG=-all AUDIODEV=null \\
"$WINE" RA95.EXE > "$SCREENSHOT_DIR/wine-ra-cage-wine.log" 2>&1 &
WINE_PID=\$!
sleep 7
DISPLAY="$XDISPLAY" xdotool key Return 2>/dev/null || true
grim "$SCREENSHOT_DIR/wine-ra-cage-t6.png" 2>/dev/null || true
sleep 12
grim "$SCREENSHOT_DIR/wine-ra-cage-t18.png" 2>/dev/null || true
kill \$WINE_PID 2>/dev/null || true
kill \$XWL_PID 2>/dev/null || true
INNER_EOF
chmod +x "$INNER"

echo "=== launching RA95.EXE under cage + Xwayland + winex11 ==="
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 30 "$CAGE" -- "$INNER" 2>/dev/null

echo ""
echo "=== screenshots ==="
for shot in "$SCREENSHOT_DIR/wine-ra-cage-t6.png" "$SCREENSHOT_DIR/wine-ra-cage-t18.png"; do
    if [[ -f "$shot" ]]; then
        sz=$(stat -c%s "$shot")
        if [[ $sz -lt 5000 ]]; then
            echo "  WARN: $shot is only $sz bytes — may be blank backdrop"
        else
            echo "  OK: $shot ($sz bytes)"
        fi
    else
        echo "  MISSING: $shot"
    fi
done
