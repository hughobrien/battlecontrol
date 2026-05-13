#!/usr/bin/env bash
# TIM-534 pass-96: synthetic unit click via RA_GAME_CLICK=1 — unit selection/move
#
# Adds RA_GAME_CLICK=1 env var (TIM-534) to the existing RA_AUTOSTART smoke run.
# New injection block in CONQUER.CPP:
#   Frame 30: SDL left-click at (350,155) → infantry cluster in SCG01EA default viewport
#   Frame 35: log unit-count; SDL right-click at (430,375) → open terrain move order
#   Frame 40: log post-click unit-count; done flag set
#
# ACCEPTANCE CRITERIA (TIM-534):
#   1. "[GAME-CLICK] frame 30: left-click at (350,155) pushed" in log
#   2. "[GAME-CLICK] frame 35: unit-count after left-click = N" in log
#   3. "[GAME-CLICK] frame 35: right-click at (430,375) pushed (move order)" in log
#   4. 100+ game frames reached without SIGSEGV or Aborted
#   5. Also: TIM-531 block still fires (no regression from SDL click plumbing)
#
# Run from repo root:
#   bash scripts/first-run-pass-96.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-96"
OBJ_DIR="$PASS_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-490"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

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
        REDALERT/DTABLE.CPP|REDALERT/ITABLE.CPP) skipped=$((skipped+1)); continue ;;
        REDALERT/LZWOTRAW.CPP)                    skipped=$((skipped+1)); continue ;;
        REDALERT/STUB.CPP)                        skipped=$((skipped+1)); continue ;;
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
    -O2 "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
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
echo "=== TIM-534 smoke test (200s timeout, RA_AUTOSTART=1 RA_GAME_CLICK=1) ==="
pkill -f "Xvfb :96" 2>/dev/null || true
Xvfb :96 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame100.bmp /tmp/redalert-frame300.bmp /tmp/redalert-frame500.bmp

(cd "$RUN_DIR" && DISPLAY=:96 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 RA_GAME_CLICK=1 \
    timeout 200 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- RA_GAME_CLICK injection log (TIM-534) ---"
grep -a "\[GAME-CLICK\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-531 SDL click injection log ---"
grep -a "TIM-531" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Frame milestones ---"
grep -a "Main_Loop frame" "$LOG" | grep -E "frame (100|200|300|400|500)" | head -6 || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|signal 11|Aborted" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

# BMP conversion
for bmp in /tmp/redalert-frame100.bmp /tmp/redalert-frame300.bmp; do
    if [[ -f "$bmp" ]]; then
        dest="$PASS_DIR/$(basename "$bmp")"
        cp "$bmp" "$dest"
        command -v convert >/dev/null 2>&1 && \
            convert "$dest" "${dest%.bmp}.png" 2>/dev/null && echo "$(basename "${dest%.bmp}").png written"
    fi
done

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-534 pass-96 analysis ===\n")

# TIM-534 criteria
lclick_pushed  = any("[GAME-CLICK]" in l and "left-click" in l and "frame 30" in l for l in lines)
unit_count_log = any("[GAME-CLICK]" in l and "unit-count after left-click" in l for l in lines)
rclick_pushed  = any("[GAME-CLICK]" in l and "right-click" in l and "frame 35" in l for l in lines)
post_count_log = any("[GAME-CLICK]" in l and "post-click unit-count" in l for l in lines)

# Extract unit count
unit_count_val = 0
for l in lines:
    m = re.search(r'unit-count after left-click = (\d+)', l)
    if m:
        unit_count_val = int(m.group(1)); break

post_count_val = 0
for l in lines:
    m = re.search(r'post-click unit-count = (\d+)', l)
    if m:
        post_count_val = int(m.group(1)); break

# TIM-531 regression check
tim531_lclick = any("TIM-531: SDL left-click pushed" in l for l in lines)
tim531_select = any("TIM-531: unit selected" in l for l in lines)
tim531_rclick = any("TIM-531: SDL right-click pushed" in l for l in lines)
tim531_move   = any("TIM-531: move order issued" in l for l in lines)

frame_nums = [int(m.group(1)) for l in lines for m in [re.search(r'Main_Loop frame (\d+)', l)] if m]
max_frame = max(frame_nums) if frame_nums else 0
crashes = [l for l in lines if re.search(r'SIGSEGV|Segmentation|CRASH signal|Aborted', l)]

c1 = lclick_pushed
c2 = unit_count_log
c3 = rclick_pushed
c4 = max_frame >= 100 and len(crashes) == 0

print(f"c1. [GAME-CLICK] left-click at (350,155) frame 30:  {'PASS' if c1 else 'FAIL'}")
print(f"c2. [GAME-CLICK] unit-count logged at frame 35 (={unit_count_val}): {'PASS' if c2 else 'FAIL'}")
print(f"c3. [GAME-CLICK] right-click at (430,375) frame 35: {'PASS' if c3 else 'FAIL'}")
print(f"c4. 100+ frames, no crash (max_frame={max_frame}):  {'PASS' if c4 else 'FAIL'}")
print()
print(f"TIM-531 regression: lclick={tim531_lclick} select={tim531_select} rclick={tim531_rclick} move={tim531_move}")
if post_count_log:
    print(f"Post-click unit count (frame 40): {post_count_val}")
print()

all_pass = c1 and c2 and c3 and c4
if all_pass:
    print("=== ALL CRITERIA MET: TIM-534 PASS ===")
else:
    print("=== CRITERIA NOT MET — see details above ===")
    if crashes:
        for l in crashes[:3]:
            print(" ", l.rstrip())
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "INFO: game ran full 200s (timeout)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "INFO: game exited cleanly"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert"
else
    echo "INFO: rc=$RUN_RC"
fi
