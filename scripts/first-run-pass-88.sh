#!/usr/bin/env bash
# TIM-306 pass-88: natural gameplay baseline — probes removed, characterise mission end
#
# Removed from pass-87:
#   SCENARIO.CPP - Read_Scenario: 4x Strength boost  (TIM-303 probe)
#   CONQUER.CPP  - win/lose suppression until frame 1200 (TIM-303 probe)
#
# Retained from pass-85/86:
#   TECHNO.CPP  - Fire_At: weapon fire events (throttled ≥30 frames)  [TIM-301]
#   TECHNO.CPP  - Take_Damage: damage events (throttled ≥30 frames)    [TIM-301]
#   TECHNO.CPP  - Take_Damage RESULT_DESTROYED: kill events             [TIM-301]
#   FOOT.CPP    - Death_Announcement: unit death events                 [TIM-301]
#   HOUSE.CPP   - IsBaseBuilding=true synthetic trigger                 [TIM-298]
#   HOUSE.CPP / FACTORY.CPP - factory pipeline probes                   [TIM-298]
#
# Acceptance criteria:
#   1. SCENARIO.CPP strength-boost probe removed
#   2. CONQUER.CPP mission-end suppression removed
#   3. Build ok=300+ rc=0
#   4. Game runs and exits cleanly (no SIGSEGV)
#   5. Comment reports final frame, mission result, fire events, factory exits
#
# Run from repo root:
#   bash scripts/first-run-pass-88.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-88"
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
echo "=== Smoke test from $RUN_DIR (300s timeout, RA_AUTOSTART=1, natural gameplay) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 300 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-301 fire_at events ---"
grep -a "\[TIM-301\] fire_at" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-301 take_damage events ---"
grep -a "\[TIM-301\] take_damage" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-301 unit_destroyed events ---"
grep -a "\[TIM-301\] unit_destroyed" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-298 factory pipeline (exits after frame 500) ---"
grep -a "\[TIM-298\] factory_exit" "$LOG" | awk -F'frame=' '{split($2,a," "); if(a[1]+0 >= 500) print}' | head -10 || echo "(none)"
echo ""

echo "--- Mission result ---"
grep -a -E "Mission|PlayerWins|PlayerLoses|GAME_WIN|GAME_LOSE|scenario_end|Won|Lost|Victory|Defeat" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-306 pass-88 natural gameplay analysis ===\n")

fire_lines     = [l for l in lines if '[TIM-301] fire_at' in l]
damage_lines   = [l for l in lines if '[TIM-301] take_damage' in l]
destroy_lines  = [l for l in lines if '[TIM-301] unit_destroyed' in l]
death_lines    = [l for l in lines if '[TIM-301] death_announcement' in l]
factory_exit   = [l for l in lines if '[TIM-298] factory_exit' in l]
suppressed     = [l for l in lines if '[TIM-303] mission_end_suppressed' in l]
boost_lines    = [l for l in lines if '[TIM-303] strength_boost' in l]

print(f"TIM-303 strength_boost events:    {len(boost_lines)} (SHOULD BE 0)")
print(f"TIM-303 suppression events:       {len(suppressed)} (SHOULD BE 0)")
print()

fire_ussr = [l for l in fire_lines if 'USSR' in l or 'ussr' in l.lower()]
fire_ally = [l for l in fire_lines if 'USSR' not in l and 'ussr' not in l.lower()]
print(f"Fire events: {len(fire_lines)} total (USSR-tagged: {len(fire_ussr)}, other: {len(fire_ally)})")
for l in fire_lines[:5]:
    print(f"  {l.rstrip()}")
print()

print(f"Damage events: {len(damage_lines)}")
print(f"Unit destroyed events: {len(destroy_lines)}")
for l in destroy_lines[:5]:
    print(f"  {l.rstrip()}")
print()

print(f"Death announcement events: {len(death_lines)}")
print()

post500_exits = []
for l in factory_exit:
    m = re.search(r'frame=(\d+)', l)
    if m and int(m.group(1)) >= 500:
        post500_exits.append(l)
print(f"Factory exits total: {len(factory_exit)}  After frame 500: {len(post500_exits)}")
for l in post500_exits[:5]:
    print(f"  {l.rstrip()}")
print()

# Frame reach
last_frame = 0
for line in lines:
    for m in re.finditer(r'frame[=\s](\d+)', line):
        last_frame = max(last_frame, int(m.group(1)))

crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal', l) for l in lines)
mission_win = any(re.search(r'PlayerWins|Mission_Win|GAME_WIN|Passed|Victory', l) for l in lines)
mission_lose = any(re.search(r'PlayerLoses|Mission_Lose|GAME_LOSE|Failed|Defeat', l) for l in lines)

print(f"Last probe frame observed: {last_frame}")
print(f"Mission win detected:      {mission_win}")
print(f"Mission lose detected:     {mission_lose}")
print(f"Crash detected:            {crash}")
print()

probe_clean = len(boost_lines) == 0 and len(suppressed) == 0
build_ok = True  # checked above
run_clean = not crash

print(f"Criterion 1 (no strength-boost probe):     {'PASS' if len(boost_lines)==0 else 'FAIL'}")
print(f"Criterion 2 (no suppression probe):        {'PASS' if len(suppressed)==0 else 'FAIL'}")
print(f"Criterion 3 (no SIGSEGV):                  {'PASS' if run_clean else 'FAIL'}")
print()

if last_frame < 200:
    print("WARNING: game ended before frame 200 — regression flag, diagnose AI survivability")
elif last_frame < 500:
    print(f"NOTE: game ended at frame {last_frame} (before frame 500) — short mission, natural end")
else:
    print(f"NOTE: game ran to frame {last_frame} — healthy natural run")

if mission_win:
    print("Mission result: PLAYER WIN (AI defeated)")
elif mission_lose:
    print("Mission result: PLAYER LOSE (player units destroyed)")
else:
    print("Mission result: UNDETERMINED (neither PlayerWins nor PlayerLoses detected in log)")

print()
overall = probe_clean and run_clean
print(f"=== OVERALL: {'PASS' if overall else 'FAIL'} ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 300s without crash — ALIVE (TIMEOUT)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
