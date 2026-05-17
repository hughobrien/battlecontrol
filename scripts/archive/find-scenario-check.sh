#!/usr/bin/env bash
# TIM-821 — Find the Scenario <= 1 comparison in Start_Scenario using winedbg+gdb HW watchpoint
#
# This script runs C&C95.EXE under winedbg --gdb, connects GDB, sets a hardware
# read watchpoint on the Scenario global (VA 0x0054172C), and captures the
# instruction context each time Scenario is read by the game code.
#
# Because the game takes time to reach Start_Scenario, this script runs for
# up to 30 seconds.  The watchpoint fires on every Scenario read; the GDB
# session logs the EIP and surrounding disassembly for manual triage.
#
# Usage:
#   bash scripts/find-scenario-check.sh [EXE_PATH] [WINE_PREFIX]
#
#   EXE_PATH      path to patched C&C95.EXE (default: /opt/tiberiandawn/C&C95.EXE)
#   WINE_PREFIX   32-bit Wine prefix         (default: $HOME/.wine-td)
#
# Prerequisites:
#   - wine32 installed
#   - 32-bit Wine prefix created
#   - Xvfb available
#   - gdb installed
#
# Output:
#   /tmp/tim821-watchpoint.log — GDB session log with EIP+dissassembly at each hit

set -euo pipefail

CC95="${1:-/opt/tiberiandawn/C&C95.EXE}"
WINE_PREFIX="${2:-$HOME/.wine-td}"
SCENARIO_VA="0x0054172C"

STAGE="$(mktemp -d)"
trap "rm -rf $STAGE" EXIT

# Stage the binary and data
ln -sf "$CC95" "$STAGE/C&C95.EXE"
THIPX="$(dirname "$CC95")/THIPX32.DLL"
[[ -f "$THIPX" ]] && ln -sf "$THIPX" "$STAGE/THIPX32.DLL"

DATA_DIR="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
if [[ -d "$DATA_DIR" ]]; then
    for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
        [[ -e "$f" ]] && ln -sf "$f" "$STAGE/"
    done
fi

cat > "$STAGE/CONQUER.INI" << 'EOF'
[Options]
HardwareFills=0
VideoBackBuffer=0
Compatibility=1
VideoBackBufferAllowed=0
AllowHardwareBlitFills=0
ScreenHeight=400
EOF

# Start Xvfb
export DISPLAY=:92
pkill Xvfb 2>/dev/null || true
sleep 1
Xvfb :92 -screen 0 640x400x8 -ac &
XVFB_PID=$!
sleep 1

# Create GDB command file
cat > "$STAGE/gdb-cmds" << GDBEOF
set confirm off
set pagination off
echo === HW watchpoint on Scenario $SCENARIO_VA ===\n
rwatch *$SCENARIO_VA
echo === Continuing (wait for watchpoint to fire) ===\n
continue
GDBEOF

cd "$STAGE"

echo "[TIM-821] Starting winedbg --gdb..."
export WINEPREFIX="$WINE_PREFIX"
export WINEARCH=win32
export AUDIODEV=null

# Start winedbg in gdb server mode
winedbg --gdb "C&C95.EXE" > /tmp/tim821-winedbg.log 2>&1 &
DBG_PID=$!
sleep 3

# Connect GDB
echo "[TIM-821] Connecting GDB..."
timeout 25 gdb -batch -x "$STAGE/gdb-cmds" > /tmp/tim821-gdb.log 2>&1 || true

# Cleanup
kill $DBG_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

echo "[TIM-821] Logs:"
echo "  winedbg: /tmp/tim821-winedbg.log"
echo "  gdb:     /tmp/tim821-gdb.log"
echo ""
echo "=== GDB log ==="
cat /tmp/tim821-gdb.log
