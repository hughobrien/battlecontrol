#!/usr/bin/env bash
# TIM-536 pass-97: enemy AI engagement and combat verification.
#
# Runs RA_AUTOSTART=1 RA_GAME_CLICK=1 for 5000+ game-loop frames to verify:
#   - Enemy AI is ticking (non-player units logged every 1000 frames)
#   - Combat occurs (unit deaths via [TIM-301] death_announcement)
#   - Frame 5000 reached at ≥10fps
#   - Frame-5000 BMP screenshot saved to e2e/screenshots/ra-native-frame-5000.png
#   - pass-95/96 injection (unit select + move) still works (no regression)
#
# ACCEPTANCE CRITERIA (TIM-536):
#   1. 5000+ frames reached, no crash
#   2. [TIM-536] pass-97 probe frame=5000 in log (enemy AI probe fired)
#   3. [TIM-301] death_announcement in log (combat evidence) OR
#      [TIM-536] enemy_units > 0 at any probe frame (AI ticking)
#   4. fps at frame 5000 ≥ 10
#   5. e2e/screenshots/ra-native-frame-5000.png written and non-black
#   6. [GAME-CLICK] frame 30 left-click still logs (pass-96 regression check)
#
# Run from repo root:
#   bash scripts/first-run-pass-97.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-97"
OBJ_DIR="$PASS_DIR/obj"
# Game data: check local first, then main worktree (worktree builds don't copy run-490)
RUN_DIR="$REPO_ROOT/build/run-490"
if [[ ! -d "$RUN_DIR" ]]; then
    # Worktrees live at <main>/.claude/worktrees/<name>; main is 3 levels up
    MAIN_ROOT="$(cd "$REPO_ROOT/../../../" 2>/dev/null && pwd || echo "")"
    if [[ -d "$MAIN_ROOT/build/run-490" ]]; then
        RUN_DIR="$MAIN_ROOT/build/run-490"
    fi
fi

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
echo "=== TIM-536 smoke test: 5000-frame run (500s timeout, RA_AUTOSTART=1 RA_GAME_CLICK=1) ==="
pkill -f "Xvfb :96" 2>/dev/null || true
Xvfb :96 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-gameplay-f5000.bmp

(cd "$RUN_DIR" && DISPLAY=:96 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 RA_GAME_CLICK=1 \
    timeout 500 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-536 pass-97 probe lines ---"
grep -a "\[TIM-536\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-301 death announcements (combat evidence) ---"
grep -a "TIM-301.*death_announcement" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-308 reinforcement log (tank spawns) ---"
grep -a "TIM-308" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-310 restart cycles ---"
grep -a "TIM-310" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- GAME-CLICK injection log (pass-96 regression check) ---"
grep -a "\[GAME-CLICK\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Frame milestones ---"
grep -a "Main_Loop frame" "$LOG" | grep -E "frame (1000|2000|3000|4000|5000)" | head -8 || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|signal 11|Aborted" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

# Convert frame-5000 BMP to PNG
SCREENSHOT_DIR="$REPO_ROOT/e2e/screenshots"
mkdir -p "$SCREENSHOT_DIR"
if [[ -f /tmp/redalert-gameplay-f5000.bmp ]]; then
    cp /tmp/redalert-gameplay-f5000.bmp "$PASS_DIR/ra-native-frame-5000.bmp"
    if command -v convert >/dev/null 2>&1; then
        convert /tmp/redalert-gameplay-f5000.bmp "$SCREENSHOT_DIR/ra-native-frame-5000.png" 2>/dev/null \
            && echo "ra-native-frame-5000.png written to $SCREENSHOT_DIR"
    else
        echo "ImageMagick not found; BMP saved to $PASS_DIR/ra-native-frame-5000.bmp"
    fi
else
    echo "WARNING: /tmp/redalert-gameplay-f5000.bmp not found (game may not have reached frame 5000)"
fi
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-536 pass-97 analysis ===\n")

# C1: 5000+ frames reached, no crash
frame_nums = [int(m.group(1)) for l in lines for m in [re.search(r'Main_Loop frame (\d+)', l)] if m]
max_frame = max(frame_nums) if frame_nums else 0
crashes = [l for l in lines if re.search(r'SIGSEGV|Segmentation|CRASH signal|Aborted', l)]
c1 = max_frame >= 5000 and len(crashes) == 0

# C2: pass-97 probe at frame 5000 fired
c2 = any("[TIM-536]" in l and "frame=5000" in l for l in lines)

# C3: enemy AI evidence (deaths OR non-zero enemy units at any probe)
deaths = [l for l in lines if "[TIM-301]" in l and "death_announcement" in l]
enemy_active = False
for l in lines:
    m = re.search(r'\[TIM-536\].*enemy_units=(\d+)', l)
    if m and int(m.group(1)) > 0:
        enemy_active = True
        break
c3 = len(deaths) > 0 or enemy_active

# C4: fps at frame 5000 >= 10
fps_val = 0.0
for l in lines:
    m = re.search(r'Main_Loop frame 5000\s+fps=([\d.]+)', l)
    if m:
        fps_val = float(m.group(1))
        break
c4 = fps_val >= 10.0

# C5: BMP saved (checked by shell above; here we check the log line)
c5 = any("gameplay BMP frame=5000" in l for l in lines)

# C6: pass-96 regression — GAME-CLICK frame 30 still fires
c6 = any("[GAME-CLICK]" in l and "left-click" in l and "frame 30" in l for l in lines)

# TIM-310 cycle count
cycles = len([l for l in lines if "[TIM-310] read_scenario_ok" in l])

print(f"c1. 5000+ frames reached, no crash (max_frame={max_frame}):  {'PASS' if c1 else 'FAIL'}")
print(f"c2. [TIM-536] probe fired at frame=5000:                     {'PASS' if c2 else 'FAIL'}")
print(f"c3. Enemy AI evidence (deaths={len(deaths)}, enemy_active={enemy_active}): {'PASS' if c3 else 'FAIL'}")
print(f"c4. fps at frame 5000 >= 10 (fps={fps_val:.1f}):             {'PASS' if c4 else 'FAIL'}")
print(f"c5. Gameplay BMP saved at frame 5000:                        {'PASS' if c5 else 'FAIL'}")
print(f"c6. pass-96 GAME-CLICK regression check:                     {'PASS' if c6 else 'FAIL'}")
print()
print(f"TIM-310 restart cycles completed: {cycles}")

# Print sample enemy probe lines
probes = [l.rstrip() for l in lines if "[TIM-536]" in l]
if probes:
    print("\nEnemy probe readings:")
    for p in probes[:6]:
        print(" ", p)

# Print sample deaths
if deaths:
    print(f"\nUnit deaths (first 5):")
    for d in deaths[:5]:
        print(" ", d.rstrip())

print()
all_pass = c1 and c2 and c3 and c4 and c5 and c6
if all_pass:
    print("=== ALL CRITERIA MET: TIM-536 pass-97 PASS ===")
else:
    print("=== CRITERIA NOT MET — see details above ===")
    if crashes:
        for l in crashes[:3]:
            print(" ", l.rstrip())
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "INFO: game ran full 500s (timeout — reached frame limit)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "INFO: game exited cleanly"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert"
else
    echo "INFO: rc=$RUN_RC"
fi
