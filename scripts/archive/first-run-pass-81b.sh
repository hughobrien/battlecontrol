#!/usr/bin/env bash
# TIM-289 pass-81b: diagnose simulation freeze — target acquisition vs pathfinding
#
# Instruments CONQUER.CPP and FOOT.CPP with:
#   - Frame-100 dump of NavCom/TarCom/zone for each MISSION_HUNT infantry
#   - First-20 Mission_Hunt() call log: got_target, tarcom, navcom
#   - First-5 Basic_Path() success log: src/dst/zone/thresh
#   - First-20 Basic_Path() failure log: src/dst/zone/thresh
#
# Pass criterion:
#   - "[TIM-289]" lines appear, showing whether target acquisition ever succeeds
#   - If got_target=0 → target-acquisition failure (Greatest_Threat path)
#   - If got_target=1 but Basic_Path FAIL → pathfinding failure
#   - Zone values reveal whether zone connectivity is zeroed out
#
# Run from repo root:
#   bash scripts/first-run-pass-81b.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-81b"
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
echo "=== Smoke test from $RUN_DIR (120s timeout, RA_AUTOSTART=1) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
# RA_AUTOSTART=1: deliberately skips ~200s of VQA intro movies so gameplay is
# reached within the 60s window.  Without it SCG01EA.INI is never loaded in time.
# This is a legitimate e2e fast-path, not the default user-facing boot (TIM-665).
# Run to frame 200 — enough to see ~14 Mission_Hunt cycles for HUNT infantry
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 60 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-289 diagnostics ---"
grep -a "\[TIM-289\]" "$LOG" | head -80 || echo "(no TIM-289 probe output)"
echo ""

echo "--- TIM-288 simulation liveness ---"
grep -a "\[TIM-288\]" "$LOG" | head -40 || echo "(no TIM-288 probe output)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 10 lines ---"
tail -10 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
echo ""

# Analysis
python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

hunt_calls = []
bp_ok = []
bp_fail = []
frame100_inf = []

for line in lines:
    # Mission_Hunt call log
    m = re.search(r'Mission_Hunt#(\d+) frame=(\d+) house=(\d+) got_target=(\d+) tarcom=(0x[\da-fA-F]+) navcom=(0x[\da-fA-F]+)', line)
    if m:
        hunt_calls.append({
            'call': int(m.group(1)), 'frame': int(m.group(2)), 'house': int(m.group(3)),
            'got': int(m.group(4)), 'tarcom': m.group(5), 'navcom': m.group(6)
        })

    # Basic_Path success
    m = re.search(r'Basic_Path OK#(\d+) frame=(\d+) house=(\d+) src=(\d+) dst=(\d+) path\[0\]=(\d+) thresh=(\d+)', line)
    if m:
        bp_ok.append({
            'call': int(m.group(1)), 'frame': int(m.group(2)), 'house': int(m.group(3)),
            'src': int(m.group(4)), 'dst': int(m.group(5)),
            'path0': int(m.group(6)), 'thresh': int(m.group(7))
        })

    # Basic_Path failure
    m = re.search(r'Basic_Path FAIL#(\d+) frame=(\d+) house=(\d+) src=(\d+) dst=(\d+) srczone=(\d+) dstzone=(\d+) thresh=(\d+) navcom=(0x[\da-fA-F]+)', line)
    if m:
        bp_fail.append({
            'call': int(m.group(1)), 'frame': int(m.group(2)), 'house': int(m.group(3)),
            'src': int(m.group(4)), 'dst': int(m.group(5)),
            'srczone': int(m.group(6)), 'dstzone': int(m.group(7)),
            'thresh': int(m.group(8)), 'navcom': m.group(9)
        })

    # Frame-100 infantry probe
    m = re.search(r'inf\[(\d+)\] house=(\d+) coord=(0x[\da-fA-F]+) cell=(\d+) mzone=(\d+) myzone=(\d+) navcom=(0x[\da-fA-F]+) tarcom=(0x[\da-fA-F]+) pathdelay=(\d+)', line)
    if m and '[TIM-289]' in line:
        frame100_inf.append({
            'idx': int(m.group(1)), 'house': int(m.group(2)), 'coord': m.group(3),
            'cell': int(m.group(4)), 'mzone': int(m.group(5)), 'myzone': int(m.group(6)),
            'navcom': m.group(7), 'tarcom': m.group(8), 'pathdelay': int(m.group(9))
        })

print("\n=== TIM-289 pass-81b analysis ===\n")

print("Frame-100 HUNT infantry state:")
if frame100_inf:
    for inf in frame100_inf:
        print(f"  inf[{inf['idx']}] house={inf['house']} cell={inf['cell']} mzone={inf['mzone']} "
              f"myzone={inf['myzone']} navcom={inf['navcom']} tarcom={inf['tarcom']} "
              f"pathdelay={inf['pathdelay']}")
else:
    print("  (none — no HUNT infantry at frame 100, or probe not triggered)")

print(f"\nMission_Hunt calls logged: {len(hunt_calls)}")
if hunt_calls:
    got_count = sum(1 for c in hunt_calls if c['got'])
    print(f"  got_target=1 (target found): {got_count}/{len(hunt_calls)}")
    print(f"  got_target=0 (no target):    {len(hunt_calls)-got_count}/{len(hunt_calls)}")
    print("\n  Sample calls:")
    for c in hunt_calls[:10]:
        print(f"    call#{c['call']} frame={c['frame']} house={c['house']} "
              f"got={c['got']} tarcom={c['tarcom']} navcom={c['navcom']}")

print(f"\nBasic_Path successes: {len(bp_ok)}")
for b in bp_ok[:5]:
    print(f"  OK#{b['call']} frame={b['frame']} src={b['src']} dst={b['dst']} path0={b['path0']}")

print(f"\nBasic_Path failures: {len(bp_fail)}")
for b in bp_fail[:10]:
    print(f"  FAIL#{b['call']} frame={b['frame']} src={b['src']} dst={b['dst']} "
          f"srczone={b['srczone']} dstzone={b['dstzone']} thresh={b['thresh']} navcom={b['navcom']}")

# Diagnosis
print("\n=== Diagnosis ===")
if not hunt_calls and not frame100_inf:
    print("  WARNING: no TIM-289 probes fired — HUNT infantry may not exist in this scenario")
elif hunt_calls:
    got_any = any(c['got'] for c in hunt_calls)
    if not got_any:
        print("  ROOT CAUSE CANDIDATE: target acquisition always fails")
        print("  → Greatest_Threat() returns TARGET_NONE for all HUNT infantry")
        print("  → Check InfantryClass::Greatest_Threat / Is_Weapon_Equipped()")
    elif bp_fail and not bp_ok:
        print("  ROOT CAUSE CANDIDATE: pathfinding always fails (Basic_Path returns false)")
        zones = set((b['srczone'], b['dstzone']) for b in bp_fail)
        if any(sz == 0 and dz == 0 for sz, dz in zones):
            print("  → Both srczone and dstzone = 0: zone connectivity may not be initialized")
            print("  → Check DisplayClass::Zone_Reset() or place_objects init order")
        else:
            print(f"  → Zone pairs: {zones}")
            print("  → Can_Enter_Cell or Find_Path may be returning MOVE_NO for all cells")
    elif bp_ok:
        print("  PARTIAL: some paths succeeded — movement issue may be intermittent")
    else:
        print("  Target acquired but no Basic_Path calls logged — check Approach_Target / NavCom assignment")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran ${120}s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
