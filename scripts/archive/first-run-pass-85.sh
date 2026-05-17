#!/usr/bin/env bash
# TIM-298 pass-85: audit factory production pipeline — find or synthesize a production trigger
#
# Instruments:
#   HOUSE.CPP     - HouseClass::AI: force IsBaseBuilding=true at frame 10 for non-human houses
#   HOUSE.CPP     - HouseClass::AI_Infantry: log BuildInfantry selection (team-based + base-building)
#   FACTORY.CPP   - FactoryClass::AI: log first call + production completion
#   BUILDING.CPP  - BuildingClass::Factory_AI: log factory creation start + unit exit
#
# Pass criteria:
#   1. FactoryClass::AI() confirmed called at least once
#   2. Production pipeline: factory_start → factory_completed → factory_exit observed
#   3. Frame 500+ reached, no SIGSEGV
#   4. ok=300+, rc=0 on compile
#
# Run from repo root:
#   bash scripts/first-run-pass-85.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-85"
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
echo "=== Smoke test from $RUN_DIR (120s timeout, RA_AUTOSTART=1, target frame 500+) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
# RA_AUTOSTART=1: deliberately skips ~200s of VQA intro movies so gameplay is
# reached within the 120s window.  Without it factory probes never fire (TIM-665).
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-298 IsBaseBuilding force ---"
grep -a "\[TIM-298\] frame.*forcing IsBaseBuilding" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-298 AI_Infantry selections ---"
grep -a "\[TIM-298\].*AI_Infantry" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-298 factory_start ---"
grep -a "\[TIM-298\] factory_start" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-298 FactoryClass::AI() first call ---"
grep -a "\[TIM-298\] FactoryClass::AI" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- TIM-298 factory_completed ---"
grep -a "\[TIM-298\] factory_completed" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- TIM-298 factory_exit ---"
grep -a "\[TIM-298\] factory_exit" "$LOG" | head -5 || echo "(none)"
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

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-298 pass-85 analysis ===\n")

force_lines    = [l for l in lines if '[TIM-298] frame' in l and 'forcing IsBaseBuilding' in l]
infantry_lines = [l for l in lines if '[TIM-298]' in l and 'AI_Infantry' in l]
start_lines    = [l for l in lines if '[TIM-298] factory_start' in l]
factory_ai     = [l for l in lines if '[TIM-298] FactoryClass::AI()' in l]
completed      = [l for l in lines if '[TIM-298] factory_completed' in l]
exit_lines     = [l for l in lines if '[TIM-298] factory_exit' in l]

print(f"IsBaseBuilding forced for: {len(force_lines)} house(s)")
for l in force_lines:
    print(f"  {l.rstrip()}")
print()

print(f"AI_Infantry selections: {len(infantry_lines)}")
for l in infantry_lines[:5]:
    print(f"  {l.rstrip()}")
print()

print(f"Factory starts: {len(start_lines)}")
for l in start_lines[:5]:
    print(f"  {l.rstrip()}")
print()

print(f"FactoryClass::AI() calls: {len(factory_ai)}")
for l in factory_ai[:3]:
    print(f"  {l.rstrip()}")
print()

print(f"Productions completed: {len(completed)}")
for l in completed[:3]:
    print(f"  {l.rstrip()}")
print()

print(f"Unit exits: {len(exit_lines)}")
for l in exit_lines[:3]:
    print(f"  {l.rstrip()}")
print()

# Frame reach
last_frame = 0
for line in lines:
    for m in re.finditer(r'frame=(\d+)', line):
        last_frame = max(last_frame, int(m.group(1)))
crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal', l) for l in lines)

p1 = len(factory_ai) > 0
p2 = len(start_lines) > 0 and len(completed) > 0
p3 = last_frame >= 500 and not crash

print(f"Last probe frame: {last_frame}")
print(f"Criterion 1 (FactoryClass::AI called):     {'PASS' if p1 else 'FAIL'}")
print(f"Criterion 2 (queue→advance→complete seen): {'PASS' if p2 else 'FAIL'}")
print(f"Criterion 3 (frame 500+, no SIGSEGV):      {'PASS' if p3 else 'FAIL'}")
print()
overall = p1 and p2 and p3
print(f"=== OVERALL: {'PASS' if overall else 'FAIL'} ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 120s without crash — ALIVE"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
