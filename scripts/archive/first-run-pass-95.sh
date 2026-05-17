#!/usr/bin/env bash
# TIM-531 pass-95: SDL_PushEvent in-game click injection smoke test.
#
# Verifies TIM-528 criterion 5 (unit click interaction) via the full SDL
# event path:
#   SDL_PushEvent → SDL_Process_Input_Events → _Kbd ring → GadgetClass
#   → Selection_At_Mouse / Command_Object
#
# ACCEPTANCE CRITERIA:
#   1. Build ok=307 rc=0 (all TUs compile cleanly)
#   2. "[RA] TIM-531: SDL left-click pushed at (350,135)"  appears in log
#   3. "[RA] TIM-531: unit selected count=N" where N >= 1  appears in log
#   4. "[RA] TIM-531: SDL right-click pushed at (290,215)" appears in log
#   5. "[RA] TIM-531: move order issued" appears in log
#   6. 500+ frames reached without SIGSEGV or Aborted
#
# Run from repo root:
#   bash scripts/first-run-pass-95.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-95"
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
echo "=== TIM-531 smoke test (500 frames, SDL click injection) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"

# RA_AUTOSTART=1: deliberately skips ~200s of VQA intro movies (TIM-665).
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, other=crash)"
echo ""

echo "--- TIM-531 injection markers ---"
grep -a "TIM-531" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- TIM-529 injection markers ---"
grep -a "TIM-529\|unit selected\|move order" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Frame milestones ---"
grep -a "Main_Loop frame" "$LOG" | grep -E "frame (100|200|300|400|500)" | head -10 || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|signal 11|Aborted" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-531 pass-95 analysis ===\n")

# Criterion markers
lclick_pushed   = any("TIM-531: SDL left-click pushed"  in l for l in lines)
unit_selected   = any("TIM-531: unit selected"           in l for l in lines)
rclick_pushed   = any("TIM-531: SDL right-click pushed"  in l for l in lines)
move_issued     = any("TIM-531: move order issued"       in l for l in lines)

# Extract unit count from selection log
sel_count = 0
for l in lines:
    m = re.search(r'TIM-531: unit selected count=(\d+)', l)
    if m:
        sel_count = int(m.group(1))
        break

# Max frame reached
frame_nums = [int(m.group(1)) for l in lines for m in [re.search(r'Main_Loop frame (\d+)', l)] if m]
max_frame = max(frame_nums) if frame_nums else 0

crashes = [l for l in lines if re.search(r'SIGSEGV|Segmentation|CRASH signal|Aborted', l)]

c1 = lclick_pushed
c2 = unit_selected and sel_count >= 1
c3 = rclick_pushed
c4 = move_issued
c5 = max_frame >= 500 and len(crashes) == 0

print(f"c1. SDL left-click pushed at (350,135):   {'PASS' if c1 else 'FAIL'}")
print(f"c2. Unit selected (count={sel_count}>=1): {'PASS' if c2 else 'FAIL'}")
print(f"c3. SDL right-click pushed at (290,215):  {'PASS' if c3 else 'FAIL'}")
print(f"c4. Move order issued:                    {'PASS' if c4 else 'FAIL'}")
print(f"c5. 500+ frames, no crash (max={max_frame}): {'PASS' if c5 else 'FAIL'}")
print()

all_pass = c1 and c2 and c3 and c4 and c5
if all_pass:
    print("=== ALL CRITERIA MET: TIM-531 PASS ===")
else:
    print("=== CRITERIA NOT MET — see details above ===")
    if crashes:
        for l in crashes[:3]:
            print(" ", l.rstrip())
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 120s without crash — ALIVE (TIMEOUT)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
else
    echo "INFO: rc=$RUN_RC — check log for crash"
fi
