#!/usr/bin/env bash
# TIM-289 pass-81e: distinguish IsFormationMove vs GroundspeedBias as root cause
#
# Incremental build: reuses pass-81b objects, recompiles only INFANTRY.CPP.
# New probe fields:
#   pre_form    — maxspeed BEFORE IsFormationMove override
#   IsFormMove  — IsFormationMove flag value (0 or 1)
#   FormMaxSpd  — FormationMaxSpeed value
#   maxspeed    — final effective maxspeed after any formation override
#   gspdbias    — House->GroundspeedBias as unsigned int (0 = zero bias bug)
#
# Run from repo root:
#   bash scripts/first-run-pass-81e.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_B_DIR="$REPO_ROOT/build/first-run-pass-81b"
PASS_DIR="$REPO_ROOT/build/first-run-pass-81e"
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

echo "=== Recompiling INFANTRY.CPP ==="
INF_OBJ="$OBJ_DIR/REDALERT/INFANTRY.o"
if "$CXX" "${CXXFLAGS[@]}" "$SRC_DIR/INFANTRY.CPP" -o "$INF_OBJ" 2>&1; then
    echo "INFANTRY.CPP: OK"
else
    echo "FAIL: INFANTRY.CPP compile failed"
    exit 1
fi

echo "=== Collecting objects from pass-81b (reuse unchanged) ==="
OBJECTS=()
for obj in "$PASS_B_DIR/obj/REDALERT/"*.o "$PASS_B_DIR/obj/REDALERT/WIN32LIB/"*.o "$PASS_B_DIR/obj/STUBS/"*.o; do
    [[ -f "$obj" ]] || continue
    base="$(basename "$obj")"
    if [[ "$base" == "INFANTRY.o" ]]; then
        continue
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

echo "--- CoordMove probes ---"
grep -a "CoordMove#" "$LOG" | head -15 || echo "(no CoordMove probe)"
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

probes = []
for line in lines:
    m = re.search(
        r'CoordMove#(\d+) frame=(\d+) house=(\d+) '
        r'pre_form=(\d+) IsFormMove=(\d+) FormMaxSpd=(\d+) maxspeed=(\d+) '
        r'class_maxspeed=(\d+) speedbias=(\d+) gspdbias=(\d+) '
        r'movespeed=(\d+) dist_arg=(\d+) name=(\S+)',
        line)
    if m:
        probes.append({
            'n': int(m.group(1)), 'frame': int(m.group(2)),
            'pre_form': int(m.group(4)), 'IsFormMove': int(m.group(5)),
            'FormMaxSpd': int(m.group(6)), 'maxspeed': int(m.group(7)),
            'class_maxspeed': int(m.group(8)), 'speedbias': int(m.group(9)),
            'gspdbias': int(m.group(10)), 'movespeed': int(m.group(11)),
            'dist_arg': int(m.group(12)), 'name': m.group(13),
        })

print(f"\n=== TIM-289 pass-81e analysis ===\n")
print(f"CoordMove probes logged: {len(probes)}")

if probes:
    for p in probes[:10]:
        print(f"  #{p['n']:2d} frame={p['frame']:4d} name={p['name']:10s} "
              f"pre_form={p['pre_form']:3d} IsFormMove={p['IsFormMove']} "
              f"FormMaxSpd={p['FormMaxSpd']:3d} maxspeed={p['maxspeed']:3d} "
              f"gspdbias={p['gspdbias']:6d} dist_arg={p['dist_arg']:3d}")

    print("\n=== Diagnosis ===")
    form_true = [p for p in probes if p['IsFormMove'] == 1]
    form_false = [p for p in probes if p['IsFormMove'] == 0]
    gbias_zero = [p for p in probes if p['gspdbias'] == 0]
    pre_form_zero = [p for p in probes if p['pre_form'] == 0]

    if form_true:
        fms_vals = set(p['FormMaxSpd'] for p in form_true)
        print(f"  IsFormationMove=true: {len(form_true)}/{len(probes)} probes")
        print(f"  FormMaxSpeed values when true: {fms_vals}")
        if all(p['FormMaxSpd'] == 0 for p in form_true):
            print("  ROOT CAUSE: IsFormationMove=true AND FormationMaxSpeed=0")
            print("  → Something set IsFormationMove=true but left FormationMaxSpeed=0")
            print("  → Fix: guard in Movement_AI: 'if (IsFormationMove && FormationMaxSpeed != MPH_IMMOBILE) maxspeed = FormationMaxSpeed;'")
        elif all(p['FormMaxSpd'] > 0 for p in form_true):
            print("  IsFormationMove=true but FormMaxSpeed is non-zero — not the cause")
    elif gbias_zero:
        print(f"  IsFormationMove=false, but GroundspeedBias=0: {len(gbias_zero)}/{len(probes)}")
        print("  ROOT CAUSE: House->GroundspeedBias=0 makes speed computation yield 0")
        print("  → Assign_Handicap called before Rule.Diff was initialized")
        print("  → Check initialization order of Rule.Diff vs HouseClass constructor")
    elif pre_form_zero:
        print(f"  pre_form=0 with IsFormMove=false: gspdbias issue or Class->MaxSpeed=0")
        for p in pre_form_zero[:3]:
            print(f"    class_maxspeed={p['class_maxspeed']} speedbias={p['speedbias']} gspdbias={p['gspdbias']}")
    else:
        print("  Cannot determine root cause from these probes")
        print("  Consider: SpeedBias or other multiplier is 0")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 60s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly"
else
    echo "INFO: rc=$RUN_RC"
fi
