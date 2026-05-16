#!/usr/bin/env bash
# TIM-821 v2 — Minimal winedbg+GDB HW watchpoint to find Scenario comparison
# Only runs for a few seconds, just long enough to catch the Start_Scenario read.
set -euo pipefail

CC95="/opt/tiberiandawn/C&C95.EXE"
WINE_PREFIX="${1:-$HOME/.wine-td}"
SCENARIO_VA="0x0054172C"
OUTDIR="/tmp/tim821-v2"
mkdir -p "$OUTDIR"

STAGE="$(mktemp -d)"
trap "rm -rf $STAGE" EXIT

# Stage the binary and data (minimal staging)
cp "$CC95" "$STAGE/C&C95.EXE"
THIPX="$(dirname "$CC95")/THIPX32.DLL"
[[ -f "$THIPX" ]] && cp "$THIPX" "$STAGE/THIPX32.DLL"

DATA_DIR="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
if [[ -d "$DATA_DIR" ]]; then
    for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
        [[ -e "$f" ]] && ln -sf "$f" "$STAGE/"
    done
fi

# Minimal CONQUER.INI
printf '[Options]\r\nIsFromInstall=true\r\nPlayIntro=No\r\n' > "$STAGE/CONQUER.INI"

# Create 0-byte VQP stubs to avoid spin loops
for n in $(seq 1 15); do
    touch "$STAGE/GDI${n}PRE.VQP" "$STAGE/GDI${n}.VQP"
done

# Set D: as cdrom with GDI95 label
printf 'GDI95' > "$STAGE/.windows-label"

export WINEPREFIX="$WINE_PREFIX"
export WINEARCH=win32
export AUDIODEV=null
export DISPLAY=:93

# Start Xvfb
pkill Xvfb 2>/dev/null || true
sleep 1
Xvfb :93 -screen 0 800x600x8 -ac &
XVFB_PID=$!
sleep 1

# Link D: to stage
mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"
"$WINE" reg add 'HKEY_LOCAL_MACHINE\Software\Wine\Drives' /v 'd:' /t REG_SZ /d 'cdrom' /f 2>/dev/null || true

cd "$STAGE"

# GDB command file: set read watchpoint on Scenario, continue
cat > "$OUTDIR/gdb-cmds" << 'GDBEOF'
set confirm off
set pagination off
set logging file /tmp/tim821-v2/gdb-output.log
set logging on
echo === HW watchpoint on Scenario ===\n
rwatch *0x0054172C
echo === Continuing ===\n
continue
GDBEOF

echo "[TIM-821] Starting winedbg --gdb..."
WINEDEBUG=-all timeout 30 winedbg --gdb "C&C95.EXE" > "$OUTDIR/winedbg.log" 2>&1 &
DBG_PID=$!
sleep 3

echo "[TIM-821] Connecting GDB..."
timeout 20 gdb -batch -x "$OUTDIR/gdb-cmds" > "$OUTDIR/gdb.log" 2>&1 || true

kill $DBG_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

echo "[TIM-821] Logs at $OUTDIR/"
echo "  winedbg: $OUTDIR/winedbg.log"
echo "  gdb:     $OUTDIR/gdb.log"
echo "  gdb-output: $OUTDIR/gdb-output.log"
