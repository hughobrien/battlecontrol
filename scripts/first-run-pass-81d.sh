#!/usr/bin/env bash
# TIM-289 pass-81d: check RULES.INI load + infantry class name with maxspeed=0
#
# Incremental build: reuses pass-81b objects, recompiles INFANTRY.CPP + INIT.CPP.
# New probes:
#   - INIT.CPP: "RULES.INI load=OK/FAIL" + "Rule.Process done"
#   - INFANTRY.CPP CoordMove: adds class_maxspeed + name fields
#
# Run from repo root:
#   bash scripts/first-run-pass-81d.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_B_DIR="$REPO_ROOT/build/first-run-pass-81b"
PASS_DIR="$REPO_ROOT/build/first-run-pass-81d"
OBJ_DIR="$PASS_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-172"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

CXX="${CXX:-g++}"

CXXFLAGS=(
    -std=c++17
    -c
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    -g
    -rdynamic
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    -include "$STUB_DIR/msvc-compat.h"
)

echo "=== Recompiling INFANTRY.CPP and INIT.CPP ==="
fail=0
for src_name in INFANTRY INIT; do
    src="$SRC_DIR/${src_name}.CPP"
    obj="$OBJ_DIR/REDALERT/${src_name}.o"
    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" 2>&1; then
        echo "${src_name}.CPP: OK"
    else
        echo "FAIL: ${src_name}.CPP compile failed"
        fail=$((fail+1))
    fi
done
if [[ $fail -gt 0 ]]; then
    exit 1
fi

# Collect objects: reuse pass-81b for everything except INFANTRY and INIT
echo "=== Collecting objects ==="
OBJECTS=()
for obj in "$PASS_B_DIR/obj/REDALERT/"*.o "$PASS_B_DIR/obj/REDALERT/WIN32LIB/"*.o "$PASS_B_DIR/obj/STUBS/"*.o; do
    [[ -f "$obj" ]] || continue
    base="$(basename "$obj")"
    if [[ "$base" == "INFANTRY.o" || "$base" == "INIT.o" ]]; then
        continue
    fi
    OBJECTS+=("$obj")
done
OBJECTS+=("$OBJ_DIR/REDALERT/INFANTRY.o")
OBJECTS+=("$OBJ_DIR/REDALERT/INIT.o")
echo "Total objects: ${#OBJECTS[@]}"

LINK_BIN="$PASS_DIR/redalert.elf"
echo "=== Linking → $LINK_BIN ==="
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
LINK_RC=$?
echo "Link rc=$LINK_RC"
if [[ $LINK_RC -ne 0 ]]; then
    echo "FAIL: link failed"
    exit 1
fi

if [[ ! -d "$RUN_DIR" ]]; then
    echo "SKIP: $RUN_DIR not found"
    exit 0
fi

echo ""
echo "=== Smoke test from $RUN_DIR (60s timeout, RA_AUTOSTART=1) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 60 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC"
echo ""

echo "--- RULES.INI probe ---"
grep -a "TIM-289.*RULES\|Rule.Process" "$LOG" | head -5 || echo "(no RULES probe)"
echo ""

echo "--- CoordMove probes (class name + maxspeed) ---"
grep -a "CoordMove#" "$LOG" | head -20 || echo "(no CoordMove probe)"
echo ""

echo "--- Crash ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|abort" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

rules_ok = any("RULES.INI load=OK" in l for l in lines)
rules_fail = any("RULES.INI load=FAIL" in l for l in lines)
process_done = any("Rule.Process done" in l for l in lines)

print(f"\n=== TIM-289 pass-81d analysis ===\n")
print(f"RULES.INI load: {'OK' if rules_ok else 'FAIL' if rules_fail else 'NOT PROBED'}")
print(f"Rule.Process: {'done' if process_done else 'NOT called'}")

coordmoves = []
for line in lines:
    m = re.search(
        r'CoordMove#(\d+) frame=(\d+) house=(\d+) maxspeed=(\d+) class_maxspeed=(\d+) '
        r'movespeed=(\d+) dist_arg=(\d+) coord=(0x[\da-fA-F]+) name=(\S+)',
        line)
    if m:
        coordmoves.append({
            'n': int(m.group(1)), 'frame': int(m.group(2)),
            'maxspeed': int(m.group(4)), 'class_maxspeed': int(m.group(5)),
            'movespeed': int(m.group(6)), 'dist_arg': int(m.group(7)),
            'name': m.group(9)
        })

if coordmoves:
    names = set(c['name'] for c in coordmoves)
    class_maxspeeds = set(c['class_maxspeed'] for c in coordmoves)
    print(f"\nInfantry class names observed: {names}")
    print(f"class_maxspeed values: {class_maxspeeds}")
    for cm in coordmoves[:5]:
        print(f"  #{cm['n']:2d} frame={cm['frame']:4d} name={cm['name']:12s} "
              f"class_maxspeed={cm['class_maxspeed']:3d} maxspeed={cm['maxspeed']:3d} "
              f"movespeed={cm['movespeed']:3d} dist_arg={cm['dist_arg']:3d}")

print("\n=== Diagnosis ===")
if rules_fail:
    print("  ROOT CAUSE: RULES.INI load FAILED")
    print("  → CCFileClass cannot find RULES.INI in loaded MIX files")
    print("  → All InfantryTypeClass start with MaxSpeed=MPH_IMMOBILE=0")
    print("  → MAIN.MIX may not contain RULES.INI, or CRC mismatch")
elif rules_ok and not process_done:
    print("  RULES.INI loaded but Rule.Process() not called (should not happen)")
elif rules_ok and process_done:
    if coordmoves and all(c['class_maxspeed'] == 0 for c in coordmoves):
        print("  RULES.INI loaded and processed, but MaxSpeed still 0")
        print("  → TechnoTypeClass::Read_INI may not find 'Speed' key in INI sections")
        print(f"  → Infantry names: {set(c['name'] for c in coordmoves)}")
        print("  → Check if [InfantryName] sections have Speed= entries in RULES.INI")
    else:
        print("  RULES.INI OK and MaxSpeed non-zero — check other fields")
elif not rules_ok and not rules_fail:
    print("  RULES.INI probe not triggered (INIT.CPP may not have compiled)")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 60s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly"
else
    echo "INFO: rc=$RUN_RC"
fi
