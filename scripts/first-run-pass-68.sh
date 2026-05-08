#!/usr/bin/env bash
# TIM-222 pass-68: Map.Render smoke test (display :98 to avoid Xvfb conflict)
#
# Root cause: GameInFocus initialized false (GLOBALS.CPP), never set on Linux.
# CONQUER.CPP Main_Loop #ifdef WIN32 path gates Map.Render/Input on GameInFocus.
#
# Fix (DDRAW.CPP):
#   - SDL_Process_Window_Events: set GameInFocus alongside Set_Surface_Focus
#   - First SDL_ShowWindow: set GameInFocus=true (no FOCUS_GAINED on Xvfb)
#
# Delta from pass-65: DDRAW.CPP only
#
# Run from repo root:
#   bash scripts/first-run-pass-68.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-68"
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
echo "=== Smoke test from $RUN_DIR (300s timeout) ==="
pkill -f "Xvfb :98" 2>/dev/null || true  # only kill :98, not :99 used by other agents
Xvfb :98 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 timeout 300 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- RA_AUTOSTART path ---"
grep -a "\[RA\] Select_Game" "$LOG" | head -5 || echo "(not fired)"
echo ""

echo "--- Start_Scenario result ---"
grep -a -E "Start_Scenario|in-game phase" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Post-launch SG probes ---"
grep -a -E "\[SG\] [A-M]:" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- CQ game loop ---"
grep -a -E "\[CQ\]" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- Map.Render / Map.Input firing ---"
grep -a -E "\[ML\] (before|after) Map\.(Render|Input)" "$LOG" | head -20 || echo "(not firing — GameInFocus still false?)"
echo ""

echo "--- Crash backtrace (from crash_handler) ---"
grep -a -E "CRASH signal|backtrace|\[[ 0-9]*\] " "$LOG" | head -40 || echo "(none)"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Segmentation|Illegal" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 40 lines ---"
tail -40 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

if [[ $RUN_RC -eq 124 ]]; then
    echo "PASS: game ran for 300s without crash — milestone reached!"
elif grep -qa "Start_Scenario OK" "$LOG" && ! grep -qa "CRASH signal\|Segmentation\|SIGSEGV" "$LOG"; then
    echo "PASS: in-game phase reached without crash — game loop running"
elif grep -qa "CRASH signal" "$LOG"; then
    echo "INFO: crashed — check backtrace above for next LP64 bug"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV (no backtrace captured — check build)"
else
    echo "INFO: rc=$RUN_RC"
fi

echo ""
echo "--- Frame500 BMP verification ---"
grep -a "frame500" "$PASS_DIR/run.log" | head -5 || echo "(frame500 not logged)"

if [[ -f /tmp/redalert-frame500.bmp ]]; then
    cp /tmp/redalert-frame500.bmp "$PASS_DIR/frame500.bmp"
    echo "Copied frame500.bmp to $PASS_DIR/"
    python3 -c "
import struct
with open('$PASS_DIR/frame500.bmp', 'rb') as f:
    data = f.read()
offset = struct.unpack('<I', data[10:14])[0]
width = struct.unpack('<i', data[18:22])[0]
height = struct.unpack('<i', data[22:26])[0]
pixels = data[offset:]
nz_rgb = sum(1 for i in range(0, min(len(pixels), 4*500000), 4) if pixels[i]|pixels[i+1]|pixels[i+2])
print(f'BMP {width}x{height}: nz_RGB_pixels={nz_rgb}')
if nz_rgb > 0:
    print('VISUAL MILESTONE: non-black pixels confirmed!')
else:
    print('INVESTIGATE: still all-black')
"
fi
