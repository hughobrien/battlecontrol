#!/usr/bin/env bash
# TIM-296 pass-84: audit AI mission diversity and building/production pipeline
#
# Instruments:
#   MISSION.CPP   - MissionClass::AI: sample mission type per unit at frames 100-500
#   BUILDING.CPP  - BuildingClass::AI: log first 5 calls + frame-500 alive check
#   FACTORY.CPP   - FactoryClass::AI: log first 3 calls + completion event
#   HOUSE.CPP     - HouseClass::AI: log first 3 calls
#
# Pass criteria:
#   - At least 2 distinct unit mission types logged across frames 100-500
#   - At least one BuildingClass instance confirmed alive and its AI called
#   - No regression: run reaches frame 1000 without SIGSEGV
#
# Run from repo root:
#   bash scripts/first-run-pass-84.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-84"
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

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob
shopt -s nullglob
STUB_SOURCES=( "$STUB_DIR"/*.cpp )
shopt -u nullglob

ok=0; fail=0; skipped=0
OBJECTS=()

for src in "${SOURCES[@]}"; do
    rel="${src#$REPO_ROOT/}"
    case "$rel" in
        REDALERT/DTABLE.CPP|REDALERT/ITABLE.CPP)
            skipped=$((skipped+1)); continue ;;
        REDALERT/LZWOTRAW.CPP)
            skipped=$((skipped+1)); continue ;;
        REDALERT/STUB.CPP)
            skipped=$((skipped+1)); continue ;;
    esac

    base="$(basename "$src" .cpp)"; base="${base%.CPP}"
    case "$rel" in
        REDALERT/WIN32LIB/*) obj="$OBJ_DIR/REDALERT/WIN32LIB/${base}.o" ;;
        *)                    obj="$OBJ_DIR/REDALERT/${base}.o" ;;
    esac

    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" 2>&1; then
        ok=$((ok+1)); OBJECTS+=( "$obj" )
    else
        fail=$((fail+1))
        echo "FAIL $rel"
    fi
done

for src in "${STUB_SOURCES[@]}"; do
    base="$(basename "$src" .cpp)"
    obj="$OBJ_DIR/STUBS/${base}.o"
    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" 2>&1; then
        ok=$((ok+1)); OBJECTS+=( "$obj" )
    else
        fail=$((fail+1))
        echo "FAIL (stub) $(basename "$src")"
    fi
done

echo "=== Compile: ok=$ok fail=$fail skipped=$skipped ==="
if [[ $fail -gt 0 ]]; then
    echo "FAIL: compile errors, aborting"
    exit 1
fi

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
echo "=== Smoke test from $RUN_DIR (90s timeout, RA_AUTOSTART=1, target frame 1000+) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 90 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-296 mission probes (first 60) ---"
grep -a "\[TIM-296\] mission" "$LOG" | head -60 || echo "(no mission probe output)"
echo ""

echo "--- TIM-296 building_ai probes ---"
grep -a "\[TIM-296\] building_ai" "$LOG" | head -20 || echo "(no building_ai probe output)"
echo ""

echo "--- TIM-296 factory_ai probes ---"
grep -a "\[TIM-296\] factory_ai" "$LOG" | head -10 || echo "(no factory_ai probe output)"
echo ""

echo "--- TIM-296 factory_completed probes ---"
grep -a "\[TIM-296\] factory_completed" "$LOG" | head -5 || echo "(no factory_completed probe output)"
echo ""

echo "--- TIM-296 house_ai probes ---"
grep -a "\[TIM-296\] house_ai" "$LOG" | head -10 || echo "(no house_ai probe output)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

# Analysis
python3 - "$LOG" <<'PYEOF'
import sys, re
from collections import defaultdict

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-296 pass-84 analysis ===\n")

# --- Mission diversity analysis ---
# Format: [TIM-296] mission frame=N ptr=P rtti=R mission=M
mission_events = []
for line in lines:
    m = re.search(r'\[TIM-296\] mission frame=(\d+) ptr=(\S+) rtti=(\d+) mission=(\S+)', line)
    if m:
        mission_events.append({
            'frame': int(m.group(1)), 'ptr': m.group(2),
            'rtti': int(m.group(3)), 'mission': m.group(4)
        })

print(f"Mission probe events: {len(mission_events)}")

# Distinct missions seen
distinct_missions = set(e['mission'] for e in mission_events)
# Distinct RTTI types seen
rtti_map = {0: 'NONE', 1: 'AIRCRAFT', 2: 'ANIM', 3: 'BUILDING', 4: 'BULLET',
            5: 'FACTORY', 6: 'INFANTRY', 7: 'OVERLAY', 8: 'SMUDGE',
            9: 'SPECIAL', 10: 'TEAM', 11: 'TEAMTYPE', 12: 'TEMPLATE',
            13: 'TERRAIN', 14: 'TRIGGER', 15: 'TRIGGERTYPE', 16: 'UNIT',
            17: 'VESSEL', 18: 'WARHEAD', 19: 'WEAPON'}
distinct_rttis = set(e['rtti'] for e in mission_events)

print(f"Distinct mission types seen: {sorted(distinct_missions)}")
print(f"Distinct RTTI types seen: {[rtti_map.get(r, str(r)) for r in sorted(distinct_rttis)]}")
print()

# Per-frame mission breakdown
frame_missions = defaultdict(set)
for e in mission_events:
    frame_missions[e['frame']].add(e['mission'])
for f in sorted(frame_missions):
    print(f"  Frame {f}: missions={sorted(frame_missions[f])}")
print()

if len(distinct_missions) >= 2:
    print(f"PASS (mission diversity): {len(distinct_missions)} distinct mission types seen (>= 2 required)")
else:
    print(f"FAIL (mission diversity): only {len(distinct_missions)} distinct mission type(s) seen (need >= 2)")

print()

# --- Building AI analysis ---
bld_events = [l for l in lines if '[TIM-296] building_ai' in l]
print(f"Building AI probe events: {len(bld_events)}")
for e in bld_events[:5]:
    print(f"  {e.rstrip()}")
if bld_events:
    print("PASS (building AI): BuildingClass::AI confirmed called")
else:
    print("FAIL (building AI): no BuildingClass::AI probe output")
print()

# --- Factory AI analysis ---
fac_events = [l for l in lines if '[TIM-296] factory_ai' in l]
fac_done = [l for l in lines if '[TIM-296] factory_completed' in l]
print(f"Factory AI probe events: {len(fac_events)}")
for e in fac_events[:3]:
    print(f"  {e.rstrip()}")
if fac_done:
    print(f"  PRODUCTION COMPLETED: {fac_done[0].rstrip()}")
print()

# --- House AI analysis ---
house_events = [l for l in lines if '[TIM-296] house_ai' in l]
print(f"House AI probe events: {len(house_events)}")
for e in house_events[:3]:
    print(f"  {e.rstrip()}")
if house_events:
    print("PASS (house AI): HouseClass::AI confirmed called")
else:
    print("FAIL (house AI): no HouseClass::AI probe output")
print()

# --- Frame reach + crash check ---
last_frame = 0
for line in lines:
    m = re.search(r'frame=(\d+)', line)
    if m:
        last_frame = max(last_frame, int(m.group(1)))

crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal', l) for l in lines)
frame_pass = last_frame >= 1000 and not crash

print(f"Last probe frame: {last_frame}")
print(f"Frame 1000 reach: {'PASS' if frame_pass else 'FAIL'} (crash={'yes' if crash else 'no'})")
print()

mission_pass = len(distinct_missions) >= 2
building_pass = len(bld_events) > 0

print(f"=== OVERALL: mission_diversity={'PASS' if mission_pass else 'FAIL'}  building_ai={'PASS' if building_pass else 'FAIL'}  stability={'PASS' if frame_pass else 'FAIL'} ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 90s without crash — ALIVE"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
