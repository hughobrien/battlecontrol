#!/usr/bin/env bash
# TIM-728 — RA95.EXE under cage + Xwayland + winex11 with SendInput-based input.
#
# Builds on scripts/wine-ra-cage.sh (TIM-719) and adds working input injection
# via the SendInput helper at tools/wine-input/ra-sendinput.c — which fires
# WH_KEYBOARD_LL hooks that RA's DirectInput polling actually sees, unlike
# xdotool/XTestFakeKeyEvent which DInput drops (the TIM-709 gap).
#
# Usage:
#   bash scripts/wine-ra-cage-input.sh [DATA_DIR] [ARTIFACT_DIR]
#
# Outputs:
#   ARTIFACT_DIR/wine-ra-cage-input-t<N>.png   — periodic captures
#   ARTIFACT_DIR/wine.log                       — Wine stderr
#   ARTIFACT_DIR/helper.log                     — SendInput helper output
#
# Prereqs:
#   - cage 0.3.0 (scripts/build-cage-headless.sh)
#   - Xwayland 24.x (apt install xwayland)
#   - wine-devel 11.8 (apt install wine-devel:i386)
#   - i686-w64-mingw32-gcc (apt install gcc-mingw-w64-i686)
#   - RA95.EXE + MIX data + THIPX DLLs (scripts/wine-ra-setup.sh +
#     scripts/nocd-patch.py)
set -euo pipefail

DATA_DIR="${1:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
ARTIFACT_DIR="${2:-e2e/screenshots}"
RA_EXE="${RA_EXE_PATH:-/opt/redalert/RA95.EXE}"
RA_DLL_DIR="${RA_DLL_DIR:-/opt/redalert/game}"
WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-ra-wayland}"
CAGE="${CAGE:-/usr/local/bin/cage}"
HELPER_SRC="${HELPER_SRC:-$(dirname "$0")/../tools/wine-input/ra-sendinput.c}"
HELPER_BIN="${HELPER_BIN:-/tmp/ra-sendinput.exe}"

# Pick a free X display number — concurrent agents may hold :99/:97/:94
pick_display() {
    for d in 89 88 87 86 85 84 83 82 81 80; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"
            return
        fi
    done
    echo "no free display in :80-:89 — clean up stale X locks?" >&2
    exit 1
}
XDISP="${XDISP:-$(pick_display)}"

mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"

echo "=== preflight ==="
command -v "$WINE" >/dev/null || { echo "FAIL: wine not at $WINE"; exit 1; }
command -v "$CAGE" >/dev/null || { echo "FAIL: cage not at $CAGE"; exit 1; }
command -v Xwayland >/dev/null || { echo "FAIL: Xwayland missing"; exit 1; }
[[ -f "$RA_EXE" ]] || { echo "SKIP: $RA_EXE not found"; exit 2; }
[[ -d "$DATA_DIR" ]] || { echo "FAIL: $DATA_DIR not found"; exit 1; }
[[ -f "$HELPER_SRC" ]] || { echo "FAIL: helper source $HELPER_SRC missing"; exit 1; }

if [[ ! -f "$HELPER_BIN" || "$HELPER_SRC" -nt "$HELPER_BIN" ]]; then
    echo "  Building SendInput helper..."
    i686-w64-mingw32-gcc -o "$HELPER_BIN" "$HELPER_SRC" -luser32
fi

echo "  wine:     $($WINE --version)"
echo "  cage:     $($CAGE -v 2>&1 | head -1)"
echo "  exe:      $RA_EXE ($(sha256sum "$RA_EXE" | cut -c1-12))"
echo "  data:     $DATA_DIR"
echo "  helper:   $HELPER_BIN"
echo "  display:  $XDISP"
echo "  artifacts: $ARTIFACT_DIR"

STAGE=$(mktemp -d /tmp/wine-ra-cage-input-XXXX)
INNER=$(mktemp /tmp/wine-ra-cage-input-inner-XXXX.sh)
trap 'rm -rf "$STAGE" "$INNER"' EXIT

# Stage files
for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$RA_EXE" "$STAGE/RA95.EXE"
for dll in THIPX32.DLL THIPX16.DLL; do
    [[ -f "$RA_DLL_DIR/$dll" ]] && cp "$RA_DLL_DIR/$dll" "$STAGE/$dll"
done
cp "$HELPER_BIN" "$STAGE/ra-sendinput.exe"

# Wine prefix init
if [[ ! -d "$WINEPREFIX" ]]; then
    echo "  Creating 32-bit Wine prefix..."
    WINEPREFIX="$WINEPREFIX" WINEARCH=win32 WINEDEBUG=-all \
        WINEDLLOVERRIDES="mscoree=;mshtml=" \
        "$WINE" wineboot --init 2>/dev/null
fi

# Register d: as a CDROM drive (TIM-720 — Wine's GetDriveType returns
# DRIVE_REMOTE for symlinked dirs by default, which RA's residual CD
# check rejects)
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$DATA_DIR" "$WINEPREFIX/dosdevices/d:"
cat > "$STAGE/d-cdrom.reg" <<EOF
REGEDIT4

[HKEY_LOCAL_MACHINE\\Software\\Wine\\Drives]
"d:"="cdrom"
EOF
WINEPREFIX="$WINEPREFIX" "$WINE" reg import "$STAGE/d-cdrom.reg" 2>/dev/null || true

cat > "$INNER" <<INNER_EOF
#!/usr/bin/env bash
set -uo pipefail
cd "$STAGE"

rm -f /tmp/.X${XDISP#:}-lock 2>/dev/null
Xwayland -geometry 640x480 "$XDISP" > "$ARTIFACT_DIR/xwayland.log" 2>&1 &
XWL_PID=\$!
sleep 2

DISPLAY="$XDISP" WAYLAND_DISPLAY= \\
  WINEPREFIX="$WINEPREFIX" \\
  WINEDLLOVERRIDES="mscoree=;mshtml=" \\
  WINEDEBUG=err-all,fixme-all \\
  AUDIODEV=null \\
  "$WINE" RA95.EXE > "$ARTIFACT_DIR/wine.log" 2>&1 &
WINE_PID=\$!
sleep 5

# Capture initial state
grim "$ARTIFACT_DIR/wine-ra-cage-input-t5.png" 2>/dev/null || true

# Dismiss any first-dialog (CD prompt, low-disk warning, etc.) via SendInput.
# These dialogs vary by setup; sending a single VK_RETURN works for the
# default "Yes" button on Win32 MessageBoxes and the OK button on RA's
# DDraw-rendered prompts.
DISPLAY="$XDISP" WAYLAND_DISPLAY= \\
  WINEPREFIX="$WINEPREFIX" \\
  "$WINE" "$STAGE/ra-sendinput.exe" 0x0D 0 >> "$ARTIFACT_DIR/helper.log" 2>&1 || true
sleep 2

grim "$ARTIFACT_DIR/wine-ra-cage-input-t8.png" 2>/dev/null || true

# Periodic captures
for t in 15 30 60 90 120; do
    sleep \$(( t > 15 ? 15 : t - 8 ))
    grim "$ARTIFACT_DIR/wine-ra-cage-input-t\${t}.png" 2>/dev/null || true
done

kill \$WINE_PID 2>/dev/null
kill \$XWL_PID 2>/dev/null
INNER_EOF
chmod +x "$INNER"

echo
echo "=== launching cage + Xwayland + winex11 with SendInput ==="
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    timeout 150 "$CAGE" -- "$INNER" 2>&1 | tail -5

echo
echo "=== captures ==="
for f in "$ARTIFACT_DIR"/wine-ra-cage-input-*.png; do
    [[ -f "$f" ]] || continue
    sz=$(stat -c%s "$f")
    if [[ $sz -lt 5000 ]]; then
        echo "  WARN: $f ($sz bytes — likely empty backdrop)"
    else
        echo "  OK:   $f ($sz bytes)"
    fi
done
