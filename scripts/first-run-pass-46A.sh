#!/usr/bin/env bash
# TIM-173 pass-46A: first real SDL2 window — remove SDL_VIDEODRIVER=dummy.
#
# Survey conducted 2026-05-07:
#   - SDL_VIDEODRIVER=offscreen: binary alive after 6s, VmRSS≈120MB, threads=11
#   - SDL_VIDEODRIVER=x11 (via Xvfb :99): binary alive after 5s, VmRSS≈149MB,
#     threads=11, 1024×768 all-black frame captured (expected: no game assets)
#   - SDL_RENDERER_ACCELERATED succeeds via Mesa swrast on Xvfb (libGL software)
#
# This script starts a fresh Xvfb display, runs redalert.elf against it,
# confirms liveness after 6s, then kills both and reports pass/fail.
#
# Usage:
#   bash scripts/first-run-pass-46A.sh [path/to/redalert.elf]
#
# Expected output (pass): PASS: redalert alive after 6s, VmRSS≥50MB
# Expected output (fail): FAIL: <reason>

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ELF="${1:-$REPO_ROOT/build/first-link-pass-161/redalert.elf}"

if [[ ! -x "$ELF" ]]; then
    echo "FAIL: $ELF not found or not executable"
    exit 1
fi

DISP=:98
XVFB_PID=""
RA_PID=""

cleanup() {
    [[ -n "$RA_PID" ]] && kill -9 "$RA_PID" 2>/dev/null || true
    [[ -n "$XVFB_PID" ]] && kill -9 "$XVFB_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Start Xvfb
if ! command -v Xvfb &>/dev/null; then
    echo "SKIP: Xvfb not available; SDL_VIDEODRIVER=offscreen fallback"
    SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy "$ELF" &
    RA_PID=$!
    sleep 6
    if kill -0 "$RA_PID" 2>/dev/null; then
        vmrss=$(awk '/VmRSS/{print $2}' /proc/$RA_PID/status 2>/dev/null || echo 0)
        echo "PASS (offscreen): redalert alive after 6s, VmRSS=${vmrss}kB"
        exit 0
    else
        echo "FAIL: redalert exited within 6s (offscreen)"
        exit 1
    fi
fi

Xvfb "$DISP" -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

if ! kill -0 "$XVFB_PID" 2>/dev/null; then
    echo "FAIL: Xvfb failed to start on $DISP"
    exit 1
fi

DISPLAY="$DISP" SDL_AUDIODRIVER=dummy "$ELF" &
RA_PID=$!
sleep 6

if ! kill -0 "$RA_PID" 2>/dev/null; then
    echo "FAIL: redalert exited within 6s (x11/$DISP)"
    exit 1
fi

vmrss=$(awk '/VmRSS/{print $2}' /proc/$RA_PID/status 2>/dev/null || echo 0)
threads=$(awk '/Threads/{print $2}' /proc/$RA_PID/status 2>/dev/null || echo 0)

if [[ "$vmrss" -lt 50000 ]]; then
    echo "FAIL: VmRSS=${vmrss}kB too low (expected ≥50MB) — window may not have opened"
    exit 1
fi

echo "PASS: redalert alive after 6s, VmRSS=${vmrss}kB, Threads=${threads} (x11 via Xvfb $DISP)"
