#!/usr/bin/env bash
# Idempotent Xvfb launcher — ensures a virtual display is running.
# Used by: native-build, e2e-testing, ci-cd, parity-comparison skills.
#
# Usage:
#   source scripts/skill-xvfb-ensure.sh           # :99 1280x1024x24
#   source scripts/skill-xvfb-ensure.sh :98       # custom display
#   source scripts/skill-xvfb-ensure.sh :99 640x480x24  # custom geometry
#
# After sourcing, XVFB_DISPLAY and XVFB_PID are exported.
# The script sets EXIT trap to kill Xvfb automatically.
#
# If Xvfb is already running on the target display, it reuses it.
# If an old Xvfb is dead or stuck, it kills and restarts.

set -euo pipefail

XVFB_DISPLAY="${1:-:99}"
XVFB_GEOMETRY="${2:-1280x1024x24}"
XVFB_PID=""

# Clean up the display number for pid file matching (strip leading colon)
_dpy_num="${XVFB_DISPLAY#:}"

# Kill any existing Xvfb on this display (zombie or stale)
_old_pid=$(pgrep -f "Xvfb ${XVFB_DISPLAY}" 2>/dev/null || true)
if [[ -n "$_old_pid" ]]; then
    # Check if it's actually responding
    if xdpyinfo -display "${XVFB_DISPLAY}" >/dev/null 2>&1; then
        echo "[xvfb] Reusing existing Xvfb on ${XVFB_DISPLAY} (pid=$_old_pid)"
        XVFB_PID="$_old_pid"
        export XVFB_DISPLAY XVFB_PID
        return 0 2>/dev/null || exit 0
    fi
    echo "[xvfb] Killing stale Xvfb on ${XVFB_DISPLAY} (pid=$_old_pid)"
    kill -9 "$_old_pid" 2>/dev/null || true
    sleep 0.5
fi

# Start new Xvfb
echo "[xvfb] Starting Xvfb ${XVFB_DISPLAY} ${XVFB_GEOMETRY}..."
Xvfb "${XVFB_DISPLAY}" -screen 0 "${XVFB_GEOMETRY}" -ac &
XVFB_PID=$!

# Wait for Xvfb to be ready (up to 5 seconds)
for i in $(seq 1 10); do
    if xdpyinfo -display "${XVFB_DISPLAY}" >/dev/null 2>&1; then
        echo "[xvfb] Ready (pid=$XVFB_PID)"
        break
    fi
    sleep 0.5
done

if ! xdpyinfo -display "${XVFB_DISPLAY}" >/dev/null 2>&1; then
    echo "[xvfb] ERROR: Xvfb failed to start on ${XVFB_DISPLAY}" >&2
    exit 1
fi

# Register cleanup trap (append, don't clobber existing traps)
_old_trap=$(trap -p EXIT 2>/dev/null | sed "s/trap -- '//;s/' EXIT//" || true)
if [[ -n "$_old_trap" ]]; then
    trap "$_old_trap; kill $XVFB_PID 2>/dev/null || true" EXIT
else
    trap "kill $XVFB_PID 2>/dev/null || true" EXIT
fi

export XVFB_DISPLAY XVFB_PID
