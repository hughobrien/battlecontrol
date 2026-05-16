#!/usr/bin/env bash
# TIM-821: Diagnostic — capture [0x541a68] value at the cmp dh,5 checkpoint
# This tells us what dh value Scenario=2 produces, so we can patch accordingly.
set -euo pipefail

CC95="/opt/tiberiandawn/C&C95.EXE"
WINE_PREFIX="${1:-$HOME/.wine-td}"
OUTDIR="/tmp/tim821-diag"
mkdir -p "$OUTDIR"

STAGE="$(mktemp -d)"
trap "rm -rf $STAGE" EXIT

cp "$CC95" "$STAGE/C&C95.EXE"
THIPX="$(dirname "$CC95")/THIPX32.DLL"
[[ -f "$THIPX" ]] && cp "$THIPX" "$STAGE/THIPX32.DLL"

DATA_DIR="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
if [[ -d "$DATA_DIR" ]]; then
    for f in "$DATA_DIR"/*.MIX "$DATA_DIR"/*.INI; do
        [[ -e "$f" ]] && ln -sf "$f" "$STAGE/"
    done
fi

# Apply Scenario=2 patch
python3 -c "
import sys
data = bytearray(open('$STAGE/C&C95.EXE','rb').read())
# Change mov [Scenario], 1 -> mov [Scenario], 2 at offset 0x6754B
data[0x6754B + 6] = 0x02
open('$STAGE/C&C95.EXE','wb').write(data)
print('Patched Scenario=2 at offset 0x6754B')
"

printf '[Options]\r\nIsFromInstall=true\r\nPlayIntro=No\r\n' > "$STAGE/CONQUER.INI"
for n in $(seq 1 15); do
    touch "$STAGE/GDI${n}PRE.VQP" "$STAGE/GDI${n}.VQP"
done
printf 'GDI95' > "$STAGE/.windows-label"

export WINEPREFIX="$WINE_PREFIX"
export WINEARCH=win32
export AUDIODEV=null
export DISPLAY=:94

pkill Xvfb 2>/dev/null || true
sleep 1
Xvfb :94 -screen 0 800x600x8 -ac &
XVFB_PID=$!
sleep 1

mkdir -p "$WINEPREFIX/dosdevices"
ln -sfT "$STAGE" "$WINEPREFIX/dosdevices/d:"

cd "$STAGE"

# GDB commands: breakpoint at cmp dh,5 (VA 0x4789A9), print dh, continue
cat > "$OUTDIR/gdb-cmds" << 'GDBEOF'
set confirm off
set pagination off
set logging file /tmp/tim821-diag/gdb.log
set logging on
echo === Breakpoint at cmp dh,5 (0x4789A9) ===\n
break *0x4789A9
echo === Continuing until breakpoint ===\n
continue
echo === Hit breakpoint ===\n
info registers dh
echo === dh value captured ===\n
continue
GDBEOF

echo "[TIM-821] Starting winedbg --gdb..."
WINEDEBUG=-all timeout 25 winedbg --gdb "C&C95.EXE" > "$OUTDIR/winedbg.log" 2>&1 &
DBG_PID=$!
sleep 3

echo "[TIM-821] Connecting GDB..."
timeout 20 gdb -batch -x "$OUTDIR/gdb-cmds" > "$OUTDIR/gdb-main.log" 2>&1 || true

kill $DBG_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

echo "[TIM-821] === Diagnostic output ==="
echo "=== GDB log ==="
cat "$OUTDIR/gdb.log" 2>/dev/null | grep -A2 "dh"
echo ""
echo "=== Full GDB output ==="
cat "$OUTDIR/gdb-main.log" 2>/dev/null | head -60
