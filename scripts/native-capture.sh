#!/usr/bin/env bash
# Native Linux gameplay capture — launch RA under headless Xvfb, drive to a
# specific mission start, capture a gameplay screenshot.
#
# Usage:
#   bash scripts/native-capture.sh allied-l1
#   bash scripts/native-capture.sh soviet-l1
#
#   DATA_DIR=/path/to/RA/CD1  bash scripts/native-capture.sh allied-l1
#   RA_BIN=/path/to/ra        bash scripts/native-capture.sh soviet-l1
#
# Allied L1:  RA_AUTOSTART=1 auto-starts SCG01EA.INI (Allied Mission 1, Easy).
# Soviet L1:  RA_AUTOSTART=1 + RA_AUTOSTART_SCENARIO.FLAG containing SCU01EA.INI
#             overrides the autostart scenario to Soviet Mission 1 (TIM-812).
#
# Output:
#   e2e/screenshots/native-gameplay/<mission>/capture.png
#
# Exit:
#   0 — screenshot captured and validated (>=5 KB)
#   1 — launch or capture failed
#   2 — prerequisites missing (no binary, no data)

set -euo pipefail

MISSION="${1:?usage: $0 <allied-l1|soviet-l1>}"

case "$MISSION" in
    allied-l1) SCENARIO="SCG01EA.INI" ;;
    soviet-l1) SCENARIO="SCU01EA.INI" ;;
    *) echo "FAIL: unknown mission '$MISSION' — expected allied-l1 or soviet-l1" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# --- Config ----------------------------------------------------------------

RA_BIN="${RA_BIN:-build/ra}"
DATA_DIR="${DATA_DIR:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}"
OUT_DIR="${OUT_DIR:-e2e/screenshots/native-gameplay/$MISSION}"
CAPTURE_PATH="$OUT_DIR/capture.png"

mkdir -p "$OUT_DIR"

# --- Preflight -------------------------------------------------------------

for tool in Xvfb ffmpeg xdotool xdpyinfo; do
    command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool missing" >&2; exit 1; }
done

if [[ ! -x "$RA_BIN" ]]; then
    for alt in build/ra build/first-run-pass-94/redalert.elf; do
        if [[ -x "$alt" ]]; then
            RA_BIN="$alt"
            break
        fi
    done
fi
if [[ ! -x "$RA_BIN" ]]; then
    echo "FAIL: RA native binary not found at $RA_BIN" >&2
    echo "  Run: bash scripts/skill-native-build.sh ra" >&2
    exit 2
fi

if [[ ! -d "$DATA_DIR" ]]; then
    echo "FAIL: DATA_DIR not found: $DATA_DIR" >&2
    exit 2
fi
if [[ ! -f "$DATA_DIR/MAIN.MIX" ]] && [[ ! -f "$DATA_DIR/main.mix" ]]; then
    echo "FAIL: MAIN.MIX not found in $DATA_DIR" >&2
    exit 2
fi

echo "=== native-capture: $MISSION ($SCENARIO) ==="
echo "  binary:  $RA_BIN"
echo "  data:    $DATA_DIR"
echo "  output:  $CAPTURE_PATH"

# --- Stage runtime directory -----------------------------------------------

STAGE=$(mktemp -d /tmp/native-capture-XXXX)
trap 'rm -rf "$STAGE"' EXIT

for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI "$DATA_DIR"/*.VQA "$DATA_DIR"/*.VQP; do
    [[ -e "$f" ]] && ln -sf "$f" "$STAGE/$(basename "$f")"
done

# For Soviet L1, write the scenario override flag file (TIM-812).
if [[ "$MISSION" == "soviet-l1" ]]; then
    echo -n "SCU01EA.INI" > "$STAGE/RA_AUTOSTART_SCENARIO.FLAG"
    echo "  wrote RA_AUTOSTART_SCENARIO.FLAG -> SCU01EA.INI"
fi

# --- Xvfb ------------------------------------------------------------------

pick_display() {
    for d in 70 71 72 73 74 75 76 77 78 79; do
        if [[ ! -e "/tmp/.X${d}-lock" && ! -e "/tmp/.X11-unix/X${d}" ]]; then
            echo ":$d"; return
        fi
    done
    echo "no free display" >&2; exit 1
}
XDISP="${XDISP:-$(pick_display)}"
echo "  display:  $XDISP"

Xvfb "$XDISP" -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 0.5

for i in $(seq 1 10); do
    if xdpyinfo -display "$XDISP" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
if ! xdpyinfo -display "$XDISP" >/dev/null 2>&1; then
    echo "FAIL: Xvfb failed to start on $XDISP" >&2
    exit 1
fi
echo "  Xvfb ready (pid=$XVFB_PID)"

cleanup() {
    [[ -n "${RA_PID:-}" ]] && kill "$RA_PID" 2>/dev/null || true
    [[ -n "${XVFB_PID:-}" ]] && kill "$XVFB_PID" 2>/dev/null || true
    rm -rf "$STAGE"
}
trap cleanup EXIT

# --- Launch native RA ------------------------------------------------------

echo
echo "=== launching native RA ==="

RA_LOG="$STAGE/ra.log"
(
    cd "$STAGE"
    DISPLAY="$XDISP" WAYLAND_DISPLAY= \
        SDL_AUDIODRIVER=dummy \
        SDL_VIDEO_X11_FORCE_EGL=0 \
        SDL_RENDER_DRIVER=software \
        RA_AUTOSTART=1 \
        timeout 120 "$RA_BIN"
) > "$RA_LOG" 2>&1 &
RA_PID=$!

# --- Wait for non-black canvas ---------------------------------------------

# RA_AUTOSTART=1 skips intro VQAs (TIM-500) and goes directly to
# Start_Scenario.  The first game frame renders within 5-10s of launch.
echo "  waiting for mission terrain..."
MISSION_STARTED=0
for i in $(seq 1 45); do
    sleep 1

    if ! kill -0 $RA_PID 2>/dev/null; then
        echo "  RA exited early (check $RA_LOG)"
        tail -20 "$RA_LOG"
        echo "FAIL: RA process died before rendering" >&2
        exit 1
    fi

    TMP_PNG="$STAGE/probe.png"
    ffmpeg -nostdin -loglevel error -f x11grab -video_size 640x480 \
        -i "$XDISP" -frames:v 1 -y "$TMP_PNG" 2>/dev/null || true

    if [[ -f "$TMP_PNG" ]]; then
        sz=$(stat -c%s "$TMP_PNG" 2>/dev/null || echo "0")
        if [[ "$sz" -ge 4000 ]]; then
            MISSION_STARTED=1
            echo "  mission terrain visible after ${i}s ($sz bytes)"
            break
        fi
    fi
done

if [[ "$MISSION_STARTED" -eq 0 ]]; then
    echo "FAIL: mission terrain did not render within 45s" >&2
    tail -20 "$RA_LOG"
    exit 1
fi

# Let terrain fully settle before capture.
sleep 2

# --- Capture screenshot ----------------------------------------------------

echo "  capturing screenshot..."
ffmpeg -nostdin -loglevel error -f x11grab -video_size 640x480 \
    -i "$XDISP" -frames:v 1 -y "$CAPTURE_PATH" 2>/dev/null || true

# --- Validation ------------------------------------------------------------

echo
echo "=== validation ==="

if [[ ! -f "$CAPTURE_PATH" ]]; then
    echo "FAIL: screenshot not produced at $CAPTURE_PATH" >&2
    exit 1
fi

sz=$(stat -c%s "$CAPTURE_PATH" 2>/dev/null || echo "0")
if command -v identify >/dev/null 2>&1; then
    ncolors=$(identify -format "%k" "$CAPTURE_PATH" 2>/dev/null || echo "?")
    dims=$(identify -format "%wx%h" "$CAPTURE_PATH" 2>/dev/null || echo "?")
else
    ncolors="?"
    dims="?"
fi

echo "  capture: $CAPTURE_PATH"
echo "  size:    $sz bytes"
echo "  colours: $ncolors"
echo "  dims:    $dims"

if [[ "$sz" -ge 5000 ]]; then
    echo "PASS: native $MISSION screenshot captured ($sz bytes, >=5KB)"
    exit 0
else
    echo "FAIL: screenshot too small ($sz bytes, need >=5KB)" >&2
    exit 1
fi
