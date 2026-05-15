#!/usr/bin/env bash
# TIM-724 — Drive C&C95.EXE through GDI Mission 1 under headless Wine.
#
# Adapts the TIM-708 RA substrate for Tiberian Dawn:
#
#   rendering:
#     - cnc-ddraw (TIM-732)   drop-in ddraw.dll, renderer=gdi, windowed=true
#     - Xvfb + openbox        real WM so cnc-ddraw can create a managed window
#
#   filesystem:
#     - d:=cdrom registry + staged MIX/INI symlinks
#
#   binary patches:
#     - TBD — TD-specific patch sites differ from RA's (different binary).
#       This script first smokes the unpatched binary; subsequent patches
#       will be filed as child issues once TD's failure modes are observed.
#
# Outputs in $ARTIFACT_DIR (default: e2e/tim724/gdi-m1/):
#   menu.png, mission-t0.png, mission-t3.png, ..., wine.log
set -euo pipefail

# ─── Config ──────────────────────────────────────────────────────────────────

WINE="${WINE:-/opt/wine-devel/bin/wine}"
WINEPREFIX="${WINEPREFIX:-$HOME/.wine-tim724-gdi}"
TD_EXE_PATH="${TD_EXE_PATH:-/opt/tiberiandawn/C&C95.EXE}"
TD_DLL_DIR="${TD_DLL_DIR:-/opt/tiberiandawn}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}"
CNC_DDRAW_DIR="${CNC_DDRAW_DIR:-/tmp/cnc-ddraw}"
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
[[ -f "$CNC_DDRAW_DIR/ddraw.dll" ]] || { echo "FAIL: cnc-ddraw at $CNC_DDRAW_DIR missing"; exit 1; }

echo "  wine:       $($WINE --version)"
echo "  exe:        $TD_EXE_PATH ($(sha256sum "$TD_EXE_PATH" | cut -c1-12)...)"
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

STAGE=$(mktemp -d /tmp/tim724-gdi-XXXX)

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done
cp "$TD_EXE_PATH" "$STAGE/C&C95.EXE"
[[ -f "$TD_DLL_DIR/THIPX32.DLL" ]] && cp "$TD_DLL_DIR/THIPX32.DLL" "$STAGE/THIPX32.DLL"

# CRLF CONQUER.INI — TD's PROFILE.CPP uses strchr('\r') so LF-only is silently
# ignored.  (Per TIM-695 memory note.)  We need a real game-config INI here so
# the launcher takes our settings instead of falling back to its defaults.
printf '[Options]\r\nHardwareFills=0\r\nVideoBackBuffer=0\r\nVideoBackBufferAllowed=0\r\nAllowHardwareBlitFills=0\r\nIsFromInstall=true\r\n' > "$STAGE/CONQUER.INI"

# cnc-ddraw drop-in: same config used for RA in TIM-708.
cp "$CNC_DDRAW_DIR/ddraw.dll" "$STAGE/ddraw.dll"
cat > "$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
EOF

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

# TD is a 640x400 game (vs RA's 640x480) — Xvfb screen sized accordingly,
# but with extra headroom for the window manager titlebar.
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

# Wait for a TD window
echo "  waiting for game window..."
WINDOW_NAME=""
for i in $(seq 1 30); do
    if NAME=$(DISPLAY="$XDISP" xdotool search --onlyvisible --name . 2>/dev/null | head -1); then
        if [[ -n "$NAME" ]]; then
            WINDOW_NAME=$(DISPLAY="$XDISP" xdotool getwindowname "$NAME" 2>/dev/null || echo "(noname)")
            echo "  window appeared after ${i}s: '$WINDOW_NAME'"
            break
        fi
    fi
    sleep 1
done

shoot() {
    local name="$1"
    local png="$ARTIFACT_DIR/${name}.png"
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 800x600 \
        -i "$XDISP" -frames:v 1 -y "$png" 2>/dev/null || true
    if [[ -f "$png" ]]; then
        local sz=$(stat -c%s "$png")
        local sha=$(sha256sum "$png" | cut -c1-12)
        echo "  shot $name: $sz B sha=$sha"
    fi
}

# Initial settle
sleep 5
shoot "t05-initial"
if ! kill -0 $TD_PID 2>/dev/null; then
    echo "FAIL: TD died early — see $ARTIFACT_DIR/wine.log"
    tail -20 "$ARTIFACT_DIR/wine.log"
    exit 3
fi

# Dismiss any startup dialog
DISPLAY="$XDISP" xdotool key Return 2>/dev/null || true
sleep 1
DISPLAY="$XDISP" xdotool key Return 2>/dev/null || true
sleep 4
shoot "t10-after-dismiss"

# Settle into menu / first-render
sleep 5
shoot "t15-menu-or-intro"

sleep 5
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
