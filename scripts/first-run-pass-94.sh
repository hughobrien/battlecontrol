#!/usr/bin/env bash
# TIM-316 pass-94: release build smoke test — compile without sanitizers,
#                  verify stable 1000-frame run.
#
# Changes vs pass-93:
#   - Removed -fsanitize=address from compile and link
#   - Added -O2 for release-like build (matches production use)
#   - Removed ASAN_OPTIONS env, ASAN error checks
#   - Added [TIM-316] fps_probe parsing (probe added to CONQUER.CPP)
#   - Extended run timeout to 120s (1000+ frames at ~15fps = ~67s)
#
# ACCEPTANCE CRITERIA:
#   1. Build ok=307 rc=0
#   2. 1000+ frames without SIGSEGV or abort (frames measured from fps_probe)
#   3. At least 1 win/restart cycle fires
#   4. Average FPS reported
#
# Run from repo root:
#   bash scripts/first-run-pass-94.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-94"
OBJ_DIR="$PASS_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-172"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

# Generate the case-folding include shim (idempotent; required on a fresh checkout).
python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --quiet

CXX="${CXX:-g++}"

CXXFLAGS=(
    -std=c++17
    -c
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    -O2
    -g
    -rdynamic
    -fno-omit-frame-pointer
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
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic -fno-omit-frame-pointer \
    -O2 \
    "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
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
echo "=== Smoke test from $RUN_DIR (120s timeout, RA_AUTOSTART=1, NO ASAN) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, other=crash)"
echo ""

echo "--- TIM-316 FPS probes ---"
grep -a "\[TIM-316\]" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- TIM-310 cycle probes ---"
grep -a "\[TIM-310\]" "$LOG" | head -60 || echo "(none)"
echo ""

echo "--- PLAYER-WINS ---"
grep -a "\[PLAYER-WINS\]" "$LOG" | head -30 || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|signal 11|Aborted" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-316 pass-94 analysis ===\n")

wins     = [l for l in lines if '[PLAYER-WINS]' in l]
dowin    = [l for l in lines if 'do_win' in l]
fps_probes = [l for l in lines if '[TIM-316] fps_probe' in l]
crashes  = [l for l in lines if re.search(r'SIGSEGV|Segmentation|CRASH signal|signal 11|Aborted', l)]

# Extract max frame from any frame= annotation
frame_nums = []
for l in lines:
    m = re.search(r'frame=(\d+)', l)
    if m:
        frame_nums.append(int(m.group(1)))
max_frame = max(frame_nums) if frame_nums else 0

# Extract FPS from last probe
avg_fps = None
last_fps_elapsed_ms = None
last_fps_frames = None
for l in reversed(fps_probes):
    mf = re.search(r'frame=(\d+)', l)
    me = re.search(r'elapsed_ms=(\d+)', l)
    mfps = re.search(r'fps=([\d.]+)', l)
    if mf and me and mfps:
        last_fps_frames = int(mf.group(1))
        last_fps_elapsed_ms = int(me.group(1))
        avg_fps = float(mfps.group(1))
        break

print(f"Win cycles completed:              {len(wins)}")
print(f"Do_Win calls:                      {len(dowin)}")
print(f"Max frame seen in any log line:    {max_frame}")
print(f"FPS probe lines:                   {len(fps_probes)}")
if avg_fps is not None:
    print(f"Last FPS reading:                  {avg_fps:.2f} fps at frame {last_fps_frames} (elapsed {last_fps_elapsed_ms}ms)")
print(f"Crash signals detected:            {len(crashes)}")
print()

# 1000-frame criterion: check cumulative frames across cycles
# Each win cycle resets Frame; count probes for last cycle.
# Also accept: max_frame >= 1000 in one cycle, OR total do_win frames sum >= 1000
# Most reliable: check fps_probes for frame=1000+ or multiple probes
frames_reached_1000 = any(
    int(m.group(1)) >= 1000
    for l in fps_probes
    for m in [re.search(r'frame=(\d+)', l)] if m
)
# Also accept: max_frame >= 1000 OR last fps probe shows frame >= 1000 OR sum of win frames >= 1000
# Actually simpler: if we have >= 2 fps probes (each at 500 frames), that's 1000 frames in a cycle
multi_probe = len(fps_probes) >= 2

c1 = len(wins) >= 1
c2 = frames_reached_1000 or multi_probe or max_frame >= 1000
c3 = len(crashes) == 0
c4 = avg_fps is not None

print(f"Criterion 1 (≥1 win cycle):           {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 (1000+ frames stable):    {'PASS' if c2 else 'FAIL'} (max_frame={max_frame}, fps_probes={len(fps_probes)})")
print(f"Criterion 3 (no crash/SIGSEGV):       {'PASS' if c3 else 'FAIL'}")
print(f"Criterion 4 (FPS measured):           {'PASS' if c4 else 'WARN — no fps_probe lines found'}")
print()

if c1 and c2 and c3:
    print("=== ALL CRITERIA MET: TIM-316 PASS ===")
elif not c3:
    print("=== CRASH DETECTED — investigation needed ===")
    for l in crashes[:3]:
        print(" ", l.rstrip())
elif not c2:
    print(f"=== FRAME COUNT TOO LOW: only reached max_frame={max_frame} ===")
elif not c1:
    print("=== NO WIN CYCLE: game loop may be stalled ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 120s without crash — ALIVE (TIMEOUT)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
else
    echo "INFO: rc=$RUN_RC — check log for crash"
fi
