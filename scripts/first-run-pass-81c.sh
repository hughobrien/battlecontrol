#!/usr/bin/env bash
# TIM-289 pass-81c: CoordMove probe — logs maxspeed, movespeed, dist_arg, coord before/after
#
# Incremental build: reuses pass-81b objects, recompiles only INFANTRY.CPP.
# New probes in INFANTRY.CPP Movement_AI:
#   - CoordMove#N: maxspeed, movespeed, dist_arg, coord before Coord_Move
#   - CoordMoveAfter#N: coord after, dist_after, coord_changed
#
# Pass criterion:
#   - CoordMove lines appear showing dist_arg value
#   - If dist_arg=0: speed computation bug (max or movespeed is 0)
#   - If dist_arg>0 but coord_changed=0: Coord_Move bug
#   - If coord_changed=1 but Driving probe still shows same dist: Distance() issue
#
# Run from repo root:
#   bash scripts/first-run-pass-81c.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_B_DIR="$REPO_ROOT/build/first-run-pass-81b"
PASS_DIR="$REPO_ROOT/build/first-run-pass-81c"
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

echo "=== Recompiling INFANTRY.CPP with CoordMove probe ==="
INF_OBJ="$OBJ_DIR/REDALERT/INFANTRY.o"
if "$CXX" "${CXXFLAGS[@]}" "$SRC_DIR/INFANTRY.CPP" -o "$INF_OBJ" 2>&1; then
    echo "INFANTRY.CPP: OK"
else
    echo "FAIL: INFANTRY.CPP compile failed"
    exit 1
fi

# Collect objects: reuse pass-81b for everything except INFANTRY, use new for INFANTRY
echo "=== Collecting objects from pass-81b (reuse unchanged) ==="
OBJECTS=()

# Add all pass-81b objects except INFANTRY
for obj in "$PASS_B_DIR/obj/REDALERT/"*.o "$PASS_B_DIR/obj/REDALERT/WIN32LIB/"*.o "$PASS_B_DIR/obj/STUBS/"*.o; do
    [[ -f "$obj" ]] || continue
    base="$(basename "$obj")"
    if [[ "$base" == "INFANTRY.o" ]]; then
        continue  # replaced by new version
    fi
    OBJECTS+=("$obj")
done
OBJECTS+=("$INF_OBJ")

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
    echo "SKIP: $RUN_DIR not found — game data missing"
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

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- CoordMove probes ---"
grep -a "CoordMove" "$LOG" | head -40 || echo "(no CoordMove probe output)"
echo ""

echo "--- Driving probes ---"
grep -a "Driving#" "$LOG" | head -20 || echo "(no Driving probe)"
echo ""

echo "--- TIM-289 all ---"
grep -a "\[TIM-289\]" "$LOG" | head -60 || echo "(no TIM-289 output)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 10 lines ---"
tail -10 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

coordmoves = []
for line in lines:
    m = re.search(
        r'CoordMove#(\d+) frame=(\d+) house=(\d+) maxspeed=(\d+) movespeed=(\d+) dist_arg=(\d+) coord=(0x[\da-fA-F]+)',
        line)
    if m:
        n = int(m.group(1))
        after_line = None
        # scan for matching After line
        for al in lines:
            am = re.search(r'CoordMoveAfter#(\d+) coord_after=(0x[\da-fA-F]+) dist_after=(\d+) coord_changed=(\d+)', al)
            if am and int(am.group(1)) == n:
                after_line = am
                break
        coordmoves.append({
            'n': n, 'frame': int(m.group(2)), 'house': int(m.group(3)),
            'maxspeed': int(m.group(4)), 'movespeed': int(m.group(5)),
            'dist_arg': int(m.group(6)), 'coord_before': m.group(7),
            'coord_after': after_line.group(2) if after_line else '?',
            'dist_after': int(after_line.group(3)) if after_line else -1,
            'coord_changed': int(after_line.group(4)) if after_line else -1,
        })

print("\n=== TIM-289 pass-81c CoordMove analysis ===\n")
print(f"CoordMove probes logged: {len(coordmoves)}")
if coordmoves:
    for cm in coordmoves[:10]:
        changed_str = {-1: '?', 0: 'NO', 1: 'YES'}.get(cm['coord_changed'], '?')
        print(f"  #{cm['n']:2d} frame={cm['frame']:4d} house={cm['house']} "
              f"maxspeed={cm['maxspeed']:3d} movespeed={cm['movespeed']:3d} "
              f"dist_arg={cm['dist_arg']:3d} "
              f"coord_before={cm['coord_before']} → after={cm['coord_after']} "
              f"dist_after={cm['dist_after']:4d} changed={changed_str}")

    zero_dist = [cm for cm in coordmoves if cm['dist_arg'] == 0]
    nonzero_unchanged = [cm for cm in coordmoves if cm['dist_arg'] > 0 and cm['coord_changed'] == 0]
    moved = [cm for cm in coordmoves if cm['coord_changed'] == 1]

    print(f"\nSummary:")
    print(f"  dist_arg=0 (zero speed → no movement): {len(zero_dist)}/{len(coordmoves)}")
    print(f"  dist_arg>0 but coord unchanged (Coord_Move broken?): {len(nonzero_unchanged)}/{len(coordmoves)}")
    print(f"  coord changed (movement OK): {len(moved)}/{len(coordmoves)}")

    print("\n=== Diagnosis ===")
    if len(zero_dist) == len(coordmoves):
        print("  ROOT CAUSE: dist_arg=0 always → speed computation yields 0")
        if coordmoves:
            ms = coordmoves[0]['maxspeed']
            mv = coordmoves[0]['movespeed']
            print(f"  maxspeed={ms}, movespeed={mv}")
            if ms == 0:
                print("  → Class->MaxSpeed is 0 (MPH_IMMOBILE)")
            elif mv == 0:
                print("  → Speed field is 0 (Set_Speed(0xFF) not being called)")
            else:
                print(f"  → fixed-point multiplication: {ms} * fixed({mv}, 256) = {(ms * mv * 256 + 32768) // 65536}")
    elif nonzero_unchanged:
        print("  ROOT CAUSE: Coord_Move called with non-zero dist but coord unchanged")
        print("  → Bug in Coord_Move / Move_Point / calcx / calcy")
    elif moved:
        print("  Coord_Move IS working. Movement occurs each frame.")
        print("  → Driving probe's 'dist' may be sampling from a different inf or IsDriving resets")
    else:
        print("  (insufficient data)")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 60s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
