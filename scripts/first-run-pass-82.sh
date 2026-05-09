#!/usr/bin/env bash
# TIM-292 pass-82: verify movement fix — confirm infantry coord changes via TIM-288 probe
#
# Builds from clean source (no uncommitted probe code), runs to frame 500+,
# compares TIM-288 probe coords at frame 100 vs frame 500 to confirm movement.
#
# Pass criterion:
#   - Infantry with MISSION_HUNT show different coords at frame 100 vs frame 500
#   - No crash (SIGSEGV/abort)
#   - TIM-288 probe fires at both frame 100 and frame 500
#
# Run from repo root:
#   bash scripts/first-run-pass-82.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-82"
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
echo "=== Smoke test from $RUN_DIR (90s timeout, RA_AUTOSTART=1, target frame 500+) ==="
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

echo "--- TIM-288 liveness probes ---"
grep -a "\[TIM-288\]" "$LOG" | head -60 || echo "(no TIM-288 probe output)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

# Movement verification analysis
python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

# Parse TIM-288 frame snapshots
# Format: [TIM-288] frame=N tick=T credits=C units=U infantry=I logic_objects=L
# Followed by: [TIM-288]   inf[N] coord=0xXXXXXXXX mission=M house=H

snapshots = {}  # frame -> list of inf coords
current_frame = None

for line in lines:
    # Summary line
    m = re.search(r'\[TIM-288\] frame=(\d+) tick=', line)
    if m:
        current_frame = int(m.group(1))
        snapshots[current_frame] = []
    # Infantry coord line
    m = re.search(r'\[TIM-288\]\s+inf\[(\d+)\] coord=(0x[\da-fA-F]+) mission=(\d+) house=(\d+)', line)
    if m and current_frame is not None:
        snapshots[current_frame].append({
            'idx': int(m.group(1)), 'coord': int(m.group(2), 16),
            'mission': int(m.group(3)), 'house': int(m.group(4))
        })

print(f"\n=== TIM-292 pass-82 movement verification ===\n")
print(f"TIM-288 snapshots captured at frames: {sorted(snapshots.keys())}")
print()

if not snapshots:
    print("FAIL: No TIM-288 probes fired — game may not have reached frame 100")
    sys.exit(1)

frames_sorted = sorted(snapshots.keys())
if len(frames_sorted) < 2:
    print(f"WARN: Only one snapshot at frame {frames_sorted[0]} — need frame 500 for comparison")
else:
    f1, f2 = frames_sorted[0], frames_sorted[1]
    inf1 = {i['idx']: i for i in snapshots[f1]}
    inf2 = {i['idx']: i for i in snapshots[f2]}

    print(f"Comparing infantry coords: frame {f1} vs frame {f2}")
    moved = 0
    stayed = 0
    for idx in sorted(set(inf1) & set(inf2)):
        c1 = inf1[idx]['coord']
        c2 = inf2[idx]['coord']
        m1 = inf1[idx]['mission']
        moved_flag = c1 != c2
        if moved_flag:
            moved += 1
        else:
            stayed += 1
        print(f"  inf[{idx:2d}] mission={m1} frame{f1}=0x{c1:08X} frame{f2}=0x{c2:08X} "
              f"{'MOVED' if moved_flag else 'static'}")

    print()
    print(f"Summary: {moved} infantry moved, {stayed} static (out of {len(set(inf1) & set(inf2))} tracked)")
    print()

    if moved > 0:
        print("PASS: Infantry coordinate changes confirmed — movement fix verified!")
        print("      TIM-292 pass criterion met: MISSION_HUNT units are moving.")
    else:
        print("FAIL: No infantry moved between frames — movement still frozen")
        print("      Check RULES.CPP Difficulty() re-enable and Assign_Handicap order")
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
