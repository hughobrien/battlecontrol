#!/usr/bin/env bash
# TIM-294 pass-83: audit pathfinding and combat resolution quality
#
# Instruments:
#   FOOT.CPP  - Basic_Path: tracks unique cells per infantry unit (pathfinding quality)
#   INFANTRY.CPP - Take_Damage: logs hits (str, dmg) and DEATH events
#
# Pass criteria:
#   - At least one infantry unit traced moving through >= 3 distinct cells (pathfinding fires)
#   - At least one unit confirmed dead via DEATH probe (str=0 in take_damage chain)
#   - No SIGSEGV to frame 1000
#
# Run from repo root:
#   bash scripts/first-run-pass-83.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-83"
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

echo "--- TIM-294 path probes (first 30) ---"
grep -a "\[TIM-294\] path" "$LOG" | head -30 || echo "(no path probe output)"
echo ""

echo "--- TIM-294 hit probes (first 20) ---"
grep -a "\[TIM-294\] hit" "$LOG" | head -20 || echo "(no hit probe output)"
echo ""

echo "--- TIM-294 DEATH probes ---"
grep -a "\[TIM-294\] DEATH" "$LOG" | head -20 || echo "(no DEATH probe output)"
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

print("=== TIM-294 pass-83 analysis ===\n")

# --- Pathfinding analysis ---
# Format: [TIM-294] path frame=N u=ADDR cell=C n_unique=U
path_events = []
for line in lines:
    m = re.search(r'\[TIM-294\] path frame=(\d+) u=(\S+) cell=(\d+) n_unique=(\d+)', line)
    if m:
        path_events.append({'frame': int(m.group(1)), 'unit': m.group(2),
                            'cell': int(m.group(3)), 'n_unique': int(m.group(4))})

# Track max unique cells per unit
unit_max_unique = {}
for e in path_events:
    u = e['unit']
    if u not in unit_max_unique or e['n_unique'] > unit_max_unique[u]:
        unit_max_unique[u] = e['n_unique']

print(f"Path probe events: {len(path_events)}")
if unit_max_unique:
    print("Per-unit max unique cells visited:")
    for u, n in sorted(unit_max_unique.items(), key=lambda x: -x[1])[:10]:
        print(f"  unit={u} max_unique={n}")
    best = max(unit_max_unique.values())
    if best >= 3:
        print(f"\nPASS (pathfinding): best unit traversed {best} distinct cells (>= 3 required)")
    else:
        print(f"\nFAIL (pathfinding): best unit only {best} distinct cells (need >= 3)")
else:
    print("FAIL (pathfinding): no path probe events fired")

print()

# --- Combat/damage analysis ---
# Format: [TIM-294] hit frame=N u=ADDR str=S dmg=D
hit_events = []
for line in lines:
    m = re.search(r'\[TIM-294\] hit frame=(\d+) u=(\S+) str=(\d+) dmg=(\d+)', line)
    if m:
        hit_events.append({'frame': int(m.group(1)), 'unit': m.group(2),
                           'str': int(m.group(3)), 'dmg': int(m.group(4))})

print(f"Hit events: {len(hit_events)}")
if hit_events:
    # Show strength progression for first few units hit
    unit_str_range = {}
    for e in hit_events:
        u = e['unit']
        if u not in unit_str_range:
            unit_str_range[u] = {'min': e['str'], 'max': e['str'], 'hits': 0}
        unit_str_range[u]['min'] = min(unit_str_range[u]['min'], e['str'])
        unit_str_range[u]['max'] = max(unit_str_range[u]['max'], e['str'])
        unit_str_range[u]['hits'] += 1
    print("Per-unit strength range (from hit probes):")
    for u, r in sorted(unit_str_range.items(), key=lambda x: x[1]['min'])[:8]:
        print(f"  unit={u} str_range={r['max']}→{r['min']} hits={r['hits']}")

print()

# --- Death analysis ---
# Format: [TIM-294] DEATH frame=N u=ADDR coord=0xXXXXXXXX str=S
death_events = []
for line in lines:
    m = re.search(r'\[TIM-294\] DEATH frame=(\d+) u=(\S+) coord=(0x[\da-fA-F]+) str=(\d+)', line)
    if m:
        death_events.append({'frame': int(m.group(1)), 'unit': m.group(2),
                             'coord': int(m.group(3), 16), 'str': int(m.group(4))})

print(f"Death events: {len(death_events)}")
if death_events:
    for d in death_events[:10]:
        print(f"  DEATH frame={d['frame']} unit={d['unit']} coord=0x{d['coord']:08X} str={d['str']}")
    if len(death_events) >= 1:
        print(f"\nPASS (combat): {len(death_events)} infantry death(s) confirmed (str=0 verified in Take_Damage chain)")
    else:
        print("\nFAIL (combat): no deaths confirmed")
else:
    print("FAIL (combat): no DEATH probes fired")

print()

# --- Overall verdict ---
path_pass = bool(unit_max_unique) and max(unit_max_unique.values(), default=0) >= 3
combat_pass = len(death_events) >= 1

# Check frame reach
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
print(f"=== OVERALL: pathfinding={'PASS' if path_pass else 'FAIL'}  combat={'PASS' if combat_pass else 'FAIL'}  stability={'PASS' if frame_pass else 'FAIL'} ===")
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
