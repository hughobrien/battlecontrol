#!/usr/bin/env bash
# TIM-289 pass-81f: verify GroundspeedBias fix — Difficulty_Get #if 0 removed
#
# Recompiles RULES.CPP + INFANTRY.CPP from pass-81b base.
# Expects: gspdbias > 0, dist_arg > 0, infantry coord changes between frames.
#
# Run from repo root:
#   bash scripts/first-run-pass-81f.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_B_DIR="$REPO_ROOT/build/first-run-pass-81b"
PASS_DIR="$REPO_ROOT/build/first-run-pass-81f"
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

echo "=== Recompiling RULES.CPP and INFANTRY.CPP ==="
fail=0
for src_name in RULES INFANTRY; do
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

echo "=== Collecting objects from pass-81b (reuse unchanged) ==="
OBJECTS=()
for obj in "$PASS_B_DIR/obj/REDALERT/"*.o "$PASS_B_DIR/obj/REDALERT/WIN32LIB/"*.o "$PASS_B_DIR/obj/STUBS/"*.o; do
    [[ -f "$obj" ]] || continue
    base="$(basename "$obj")"
    if [[ "$base" == "RULES.o" || "$base" == "INFANTRY.o" ]]; then
        continue
    fi
    OBJECTS+=("$obj")
done
OBJECTS+=("$OBJ_DIR/REDALERT/RULES.o")
OBJECTS+=("$OBJ_DIR/REDALERT/INFANTRY.o")
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

echo "--- TIM-288 liveness (last 5) ---"
grep -a "\[TIM-288\]" "$LOG" | tail -5 || echo "(none)"
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
        r'class_maxspeed=(\d+) speedbias=(-?\d+) gspdbias=(\d+) '
        r'movespeed=(\d+) dist_arg=(\d+) name=(\S+)',
        line)
    if m:
        probes.append({
            'n': int(m.group(1)), 'frame': int(m.group(2)),
            'pre_form': int(m.group(4)), 'maxspeed': int(m.group(7)),
            'gspdbias': int(m.group(10)), 'movespeed': int(m.group(11)),
            'dist_arg': int(m.group(12)), 'name': m.group(13),
        })

print(f"\n=== TIM-289 pass-81f analysis ===\n")
print(f"CoordMove probes: {len(probes)}")

if probes:
    for p in probes[:10]:
        print(f"  #{p['n']:2d} frame={p['frame']:4d} name={p['name']:10s} "
              f"gspdbias={p['gspdbias']:6d} maxspeed={p['maxspeed']:3d} "
              f"movespeed={p['movespeed']:3d} dist_arg={p['dist_arg']:3d}")

    nonzero_dist = [p for p in probes if p['dist_arg'] > 0]
    zero_dist = [p for p in probes if p['dist_arg'] == 0]
    gspdbias_ok = [p for p in probes if p['gspdbias'] > 0]

    print(f"\n  gspdbias > 0: {len(gspdbias_ok)}/{len(probes)}")
    print(f"  dist_arg > 0 (movement): {len(nonzero_dist)}/{len(probes)}")
    print(f"  dist_arg = 0 (no movement): {len(zero_dist)}/{len(probes)}")

    print("\n=== Diagnosis ===")
    if gspdbias_ok and nonzero_dist:
        print("  PASS: GroundspeedBias > 0 and dist_arg > 0 — infantry IS moving!")
        print("  TIM-289 root cause FIXED: Difficulty_Get #if 0 was blocking bias init")
    elif gspdbias_ok and not nonzero_dist:
        print("  GroundspeedBias OK but dist_arg still 0 — SpeedBias or maxspeed issue remains")
        for p in probes[:3]:
            print(f"    pre_form={p['pre_form']} maxspeed={p['maxspeed']} gspdbias={p['gspdbias']}")
    elif not gspdbias_ok:
        print("  FAIL: gspdbias still 0 — Difficulty_Get fix not taking effect")
        print("  → Check that RULES.CPP was recompiled and linked")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 60s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly"
else
    echo "INFO: rc=$RUN_RC"
fi
