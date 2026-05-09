#!/usr/bin/env bash
# TIM-288 pass-80: verify game simulation is live — unit motion and AI tick
#
# Instruments CONQUER.CPP Main_Loop with:
#   - GameActive iteration counter (printed at Frame=500 and Frame=1000)
#   - Unit/infantry position + credits probe at Frame=100,500,1000,2000
#
# Pass criterion:
#   - [TIM-288] lines appear in stderr at each probe frame
#   - GameActive-iters ≈ Frame (1:1 ratio confirms no skipping)
#   - At least one unit/infantry coord differs between frame 100 and frame 2000
#     (or credits differ), proving game logic is advancing
#
# Run from repo root:
#   bash scripts/first-run-pass-80.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-80"
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
echo "=== Smoke test from $RUN_DIR (250s timeout, RA_AUTOSTART=1) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame500.bmp /tmp/redalert-frame1000.bmp
# Run long enough to reach frame 2000 (game runs ~10fps under Xvfb → ~200s needed)
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 250 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- Simulation liveness probes ([TIM-288] lines) ---"
grep -a "\[TIM-288\]" "$LOG" || echo "(no TIM-288 probe output — check compile)"
echo ""

echo "--- GameActive iteration counts ---"
grep -a "GameActive-iters" "$LOG" || echo "(none)"
echo ""

echo "--- Frame-probe samples (credits, units, coords) ---"
grep -a "frame=" "$LOG" | grep "\[TIM-288\]" || echo "(none)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 10 lines ---"
tail -10 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
echo ""

# ---- Simulation analysis ----
python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

probes = {}
iters = {}
for line in lines:
    # GameActive-iters
    m = re.search(r'GameActive-iters=(\d+) at Frame=(\d+)', line)
    if m:
        iters[int(m.group(2))] = int(m.group(1))

    # per-frame probe
    m = re.search(
        r'\[TIM-288\] frame=(\d+) credits=(-?\d+) units=(\d+) infantry=(\d+) '
        r'u\[(-?\d+)\]\.coord=(0x[0-9A-Fa-f]+) inf\[(-?\d+)\]\.coord=(0x[0-9A-Fa-f]+)',
        line)
    if m:
        f = int(m.group(1))
        probes[f] = {
            'credits': int(m.group(2)),
            'units': int(m.group(3)),
            'infantry': int(m.group(4)),
            'u_idx': int(m.group(5)),
            'u_coord': m.group(6),
            'inf_idx': int(m.group(7)),
            'inf_coord': m.group(8),
        }

if not probes and not iters:
    print("No TIM-288 probe data found — instrumentation may not have compiled in.")
    sys.exit(0)

print("\n=== Simulation liveness analysis ===\n")

print("GameActive iterations vs Frame (should match 1:1 if loop runs every frame):")
for frame in sorted(iters):
    itr = iters[frame]
    ratio = itr / frame if frame else 0
    ok = "OK" if 0.95 <= ratio <= 1.05 else "MISMATCH"
    print(f"  Frame={frame:5d}  iters={itr:5d}  ratio={ratio:.3f}  [{ok}]")

print("\nPer-frame probe data:")
for frame in sorted(probes):
    p = probes[frame]
    print(f"  frame={frame:5d}  credits={p['credits']:6d}  units={p['units']:3d}  "
          f"infantry={p['infantry']:3d}  "
          f"u[{p['u_idx']}]={p['u_coord']}  inf[{p['inf_idx']}]={p['inf_coord']}")

if len(probes) >= 2:
    frames = sorted(probes)
    early = probes[frames[0]]
    late  = probes[frames[-1]]
    print(f"\nDelta between frame {frames[0]} and frame {frames[-1]}:")
    print(f"  credits:  {early['credits']} → {late['credits']}  (delta={late['credits']-early['credits']})")
    print(f"  units:    {early['units']} → {late['units']}")
    print(f"  infantry: {early['infantry']} → {late['infantry']}")
    print(f"  u_coord:  {early['u_coord']} → {late['u_coord']}  "
          f"({'CHANGED' if early['u_coord'] != late['u_coord'] else 'UNCHANGED'})")
    print(f"  inf_coord:{early['inf_coord']} → {late['inf_coord']}  "
          f"({'CHANGED' if early['inf_coord'] != late['inf_coord'] else 'UNCHANGED'})")

    coord_changed = (early['u_coord'] != late['u_coord'] or early['inf_coord'] != late['inf_coord'])
    credits_changed = (early['credits'] != late['credits'])
    if coord_changed or credits_changed:
        print("\n  PASS: game state changed between probe frames — simulation is live!")
    else:
        print("\n  WARN: no state change detected — simulation may be frozen")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran $((250))s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
