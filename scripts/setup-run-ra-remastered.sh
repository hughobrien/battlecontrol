#!/bin/bash
# TIM-346: set up the RA remastered run directory.
#
# Creates build/run-remastered/ with:
#   - symlinks to the remastered collection's RED_ALERT/CD1/ assets
#   - VTX palette files copied from build/run-172/ (Chronal Vortex, not in CD1)
#   - redalert.elf binary copied from build/first-run-pass-72/
#
# Remastered CD1 ships HIRES1.MIX/LORES1.MIX (1-suffix) and EXPAND.MIX/EXPAND2.MIX.
# The RA source already uses the 1-suffix names for HIRES1/LORES1 (patched in TIM-173).
# EXPAND.MIX is present and loads cleanly.
# EXPAND2.MIX and HIRES1.MIX/LORES1.MIX trigger a crash in the encrypted-MIX
# loader path — excluded here until that is fixed (see TIM-348).
#
# Usage: run from repo root.
#   bash scripts/setup-run-ra-remastered.sh
#
# Prerequisites:
#   Remastered RA assets at /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/
#   build/run-172/       — for VTX palette files
#   build/first-run-pass-72/redalert.elf — working RA binary

set -e
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RA_DATA="/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1"
SRC_RUN172="$REPO_ROOT/build/run-172"
SRC_BINARY="$REPO_ROOT/build/first-run-pass-72/redalert.elf"
RUN_DIR="$REPO_ROOT/build/run-remastered"

if [ ! -d "$RA_DATA" ]; then
	echo "ERROR: RA remastered data not found at $RA_DATA" >&2
	exit 1
fi
if [ ! -f "$SRC_BINARY" ]; then
	echo "ERROR: RA binary not found at $SRC_BINARY" >&2
	echo "Build the redalert target first." >&2
	exit 1
fi

mkdir -p "$RUN_DIR"
cd "$RUN_DIR"

echo "Linking core remastered assets..."
for f in MAIN.MIX REDALERT.MIX REDALERT.INI EXPAND.MIX; do
	if [ -f "$RA_DATA/$f" ]; then
		ln -sf "$RA_DATA/$f" "$f"
		echo "  linked $f"
	else
		echo "  WARNING: $f not found in $RA_DATA"
	fi
done

# EXPAND2.MIX, HIRES1.MIX, LORES1.MIX excluded: encrypted-MIX crash (TIM-348)

echo "Copying VTX palette files (Chronal Vortex effect)..."
for f in SNOW_VTX.PAL TEMP_VTX.PAL; do
	if [ -f "$SRC_RUN172/$f" ]; then
		cp -f "$SRC_RUN172/$f" "$f"
		echo "  copied $f"
	else
		echo "  WARNING: $f not found in $SRC_RUN172"
	fi
done

echo "Copying RA binary..."
cp -f "$SRC_BINARY" redalert.elf
echo "  copied redalert.elf"

echo ""
echo "Done. To run RA with remastered assets:"
echo "  cd build/run-remastered"
echo "  RA_AUTOSTART=1 DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 30 ./redalert.elf"
