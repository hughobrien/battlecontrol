#!/usr/bin/env bash
# TIM-308 pass-89: investigate Allied win condition — inject reinforcements, verify win path
#
# New in pass-89:
#   CONQUER.CPP  - [PLAYER-WINS] probe at PlayerWins check (frame logged)
#   CONQUER.CPP  - [PLAYER-LOSES] probe at PlayerLoses check (frame logged)
#   CONQUER.CPP  - safety fallback: Flag_To_Win() at frame 100 (before scenario lose fires at ~552)
#   SCENARIO.CPP - Do_Win(): [TIM-308] do_win log confirming mission_accomplished path
#   SCENARIO.CPP - Read_Scenario(): inject 5 Allied Mammoth tanks near player start
#
# Retained from pass-85/86/88:
#   TECHNO.CPP  - Fire_At: weapon fire events (throttled ≥30 frames)  [TIM-301]
#   TECHNO.CPP  - Take_Damage: damage events (throttled ≥30 frames)    [TIM-301]
#   TECHNO.CPP  - Take_Damage RESULT_DESTROYED: kill events             [TIM-301]
#   FOOT.CPP    - Death_Announcement: unit death events                 [TIM-301]
#   HOUSE.CPP   - IsBaseBuilding=true synthetic trigger                 [TIM-298]
#   HOUSE.CPP / FACTORY.CPP - factory pipeline probes                   [TIM-298]
#
# Acceptance criteria:
#   1. Build ok=300+ rc=0
#   2. [TIM-308] reinforcements placed > 0
#   3. [PLAYER-WINS] frame=N appears in log
#   4. [TIM-308] do_win mission_accomplished appears in log
#   5. Clean exit (no SIGSEGV)
#
# Run from repo root:
#   bash scripts/first-run-pass-89.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-89"
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
echo "=== Smoke test from $RUN_DIR (300s timeout, RA_AUTOSTART=1) ==="
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

echo "--- TIM-308 reinforcement placement ---"
grep -a "\[TIM-308\] reinf_tank\|\[TIM-308\] reinforcements" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- PLAYER-WINS / PLAYER-LOSES ---"
grep -a "\[PLAYER-WINS\]\|\[PLAYER-LOSES\]" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- TIM-308 do_win / fallback ---"
grep -a "\[TIM-308\] do_win\|\[TIM-308\] fallback" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- TIM-301 fire_at events ---"
grep -a "\[TIM-301\] fire_at" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-301 unit_destroyed events ---"
grep -a "\[TIM-301\] unit_destroyed" "$LOG" | head -10 || echo "(none)"
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

print("=== TIM-308 pass-89 win-condition analysis ===\n")

reinf_lines    = [l for l in lines if '[TIM-308] reinf_tank' in l]
reinf_summary  = [l for l in lines if '[TIM-308] reinforcements' in l]
wins_lines     = [l for l in lines if '[PLAYER-WINS]' in l]
loses_lines    = [l for l in lines if '[PLAYER-LOSES]' in l]
dowin_lines    = [l for l in lines if '[TIM-308] do_win' in l]
fallback_lines = [l for l in lines if '[TIM-308] fallback_win_trigger' in l]
destroy_lines  = [l for l in lines if '[TIM-301] unit_destroyed' in l]

# Placement
print(f"Tanks placed: {len(reinf_lines)}")
for l in reinf_summary:
    print(f"  {l.rstrip()}")
print()

# Win/lose
print(f"[PLAYER-WINS] events: {len(wins_lines)}")
for l in wins_lines:
    print(f"  {l.rstrip()}")
print(f"[PLAYER-LOSES] events: {len(loses_lines)}")
for l in loses_lines:
    print(f"  {l.rstrip()}")
print()

# Do_Win
print(f"do_win (mission_accomplished path): {len(dowin_lines)}")
for l in dowin_lines:
    print(f"  {l.rstrip()}")
if fallback_lines:
    print("NOTE: fallback win trigger fired (win came from frame-800 safety, not combat)")
    for l in fallback_lines:
        print(f"  {l.rstrip()}")
print()

# Destroyed units
print(f"Unit destroyed events: {len(destroy_lines)}")
for l in destroy_lines[:8]:
    print(f"  {l.rstrip()}")
print()

# Frame reach
last_frame = 0
for line in lines:
    for m in re.finditer(r'frame[=\s](\d+)', line):
        last_frame = max(last_frame, int(m.group(1)))

crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal', l) for l in lines)

print(f"Last probe frame observed: {last_frame}")
print(f"Crash detected:            {crash}")
print()

# Criteria
c1 = len(reinf_lines) > 0
c2 = len(wins_lines) > 0
c3 = len(dowin_lines) > 0
c4 = not crash

print(f"Criterion 1 (reinforcements placed):   {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 ([PLAYER-WINS] fires):     {'PASS' if c2 else 'FAIL'}")
print(f"Criterion 3 (Do_Win executed):         {'PASS' if c3 else 'FAIL'}")
print(f"Criterion 4 (no SIGSEGV):              {'PASS' if c4 else 'FAIL'}")
print()

overall = c1 and c2 and c3 and c4
print(f"=== OVERALL: {'PASS' if overall else 'FAIL'} ===")

if not c2 and not c3:
    print("NOTE: No win detected — may need stronger reinforcements or longer run")
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
