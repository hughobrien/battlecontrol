#!/bin/bash
# TIM-343 pass-99: set up the TD smoke-test run directory.
#
# Creates build/run-td/ with:
#   - symlinks to real TD game data (TEMPERAT.MIX, CONQUER.MIX, etc.)
#   - minimal CONQUER.ENG stub (4567 empty strings)
#   - minimal SCG01EA.INI scenario stub
#   - CONQUER.INI (game options)
#
# Usage: run from repo root.
#   bash scripts/setup-run-td.sh
#
# Prerequisites:
#   TD game data at /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/
#   (Steam CnC Remastered Collection install on Linux)

set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TD_DATA="/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1"
RUN_DIR="$REPO_ROOT/build/run-td"

if [ ! -d "$TD_DATA" ]; then
    echo "ERROR: TD game data not found at $TD_DATA" >&2
    echo "Install CnC Remastered Collection via Steam (Linux) and retry." >&2
    exit 1
fi

mkdir -p "$RUN_DIR"
cd "$RUN_DIR"

echo "Linking TD mix files..."
for f in CCLOCAL.MIX CONQUER.MIX GENERAL.MIX TEMPERAT.MIX TRANSIT.MIX \
          DESERT.MIX WINTER.MIX LOCAL.MIX SC-000.MIX SC-001.MIX \
          DESEICNH.MIX TEMPICNH.MIX WINTICNH.MIX; do
    if [ -f "$TD_DATA/$f" ]; then
        ln -sf "$TD_DATA/$f" "$f"
        echo "  linked $f"
    else
        echo "  WARNING: $f not found in $TD_DATA"
    fi
done

echo "Linking loose palette files..."
for f in TEMPERAT.PAL DESERT.PAL WINTER.PAL; do
    if [ -f "$TD_DATA/$f" ]; then
        ln -sf "$TD_DATA/$f" "$f"
        echo "  linked $f"
    fi
done

echo "Writing CONQUER.ENG stub (4567 empty strings)..."
python3 - <<'EOF'
import struct, os
N = 4567
header_size = N * 2   # 9134 bytes of 2-byte offsets
offsets = [header_size] * N  # all point to the null byte at offset 9134
data = struct.pack('<' + 'H' * N, *offsets) + b'\x00'
with open("CONQUER.ENG", "wb") as f:
    f.write(data)
print("  wrote CONQUER.ENG (%d bytes)" % len(data))
EOF

echo "Writing CONQUER.INI..."
cat > CONQUER.INI <<'INIEOF'
[Options]
GameSpeed=4
ScrollRate=4
Contrast=128
Color=128
Brightness=128
SlowPalette=0
VideoEveryFrame=Yes
DestroyBuildings=No

[Screen]
ScreenWidth=640
ScreenHeight=480

[Intro]
PlayIntro=No
INIEOF

echo "Writing SCG01EA.INI (minimal GDI mission 1 stub)..."
cat > SCG01EA.INI <<'INIEOF'
; TIM-343: minimal Tiberian Dawn GDI scenario 1 stub for Linux smoke test.
; Enough structure for Read_Scenario_Ini to succeed and Main_Loop to enter.

[Basic]
Name=Test Scenario
Intro=x
Brief=x
Win=x
Lose=x
Action=x
Player=GoodGuy

[Map]
Theater=TEMPERATE
X=1
Y=1
Width=20
Height=20

[Waypoints]
0=21
1=400

[Houses]
[TeamTypes]
[Triggers]
[CellTriggers]
[Infantry]
[Units]
[Aircraft]
[Structures]
[Terrain]
[Smudge]
[Overlay]
[Base]
INIEOF

echo ""
echo "Done. To run the TD smoke test:"
echo "  mkdir -p build/cmake-td && cd build/cmake-td"
echo "  cmake ../.. -G Ninja && ninja td"
echo "  cd ../run-td"
echo "  TD_AUTOSTART=1 DISPLAY=:99 ./cmake-td/td"
