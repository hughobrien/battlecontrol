#!/usr/bin/env bash
# TIM-275 pass-76: fix HidPage.Lock() — enable radar minimap cell rendering
#
# Changes from pass-74:
#   - REDALERT/WIN32LIB/GBUFFER.CPP: DD_Init — non-MSVC non-visible path now
#     allocates a heap buffer and sets IsDirectDraw=FALSE so Lock() succeeds.
#   - REDALERT/RADAR.CPP: Plot_Radar_Pixel — one-shot diagnostic: Lock result
#     and IsMapped cell count logged on first call.
#
# Pass criterion:
#   - Compile ok, link ok, smoke test runs 90s without SIGSEGV
#   - Log shows "TIM-275 Plot_Radar_Pixel diag: Lock=1"
#   - frame500 radar area (x>=560, y=0-79) non-black pixel count >> 132
#
# Run from repo root:
#   bash scripts/first-run-pass-76.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-76"
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
echo "=== Smoke test from $RUN_DIR (90s timeout, RA_AUTOSTART=1) ==="
pkill -f "Xvfb :98" 2>/dev/null || true
Xvfb :98 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame500.bmp
(cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 90 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-275 Lock diagnostic ---"
grep -a "TIM-275" "$LOG" | head -5 || echo "(no TIM-275 log)"
echo ""

echo "--- Radar shape pointer state ---"
grep -a "\[RADAR\]" "$LOG" | head -5 || echo "(no radar log)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
tail -20 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
echo ""

# Pixel analysis: count non-black pixels in the radar area (x>=560, y=0-79)
if [[ -f /tmp/redalert-frame500.bmp ]]; then
    cp /tmp/redalert-frame500.bmp "$PASS_DIR/frame500.bmp"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$PASS_DIR/frame500.bmp" <<'PYEOF'
import struct, sys

path = sys.argv[1]
data = open(path, 'rb').read()

pixel_offset = struct.unpack_from('<I', data, 10)[0]
width        = struct.unpack_from('<i', data, 18)[0]
height_raw   = struct.unpack_from('<i', data, 22)[0]
bpp          = struct.unpack_from('<H', data, 28)[0]
height       = abs(height_raw)
bottom_up    = (height_raw > 0)

print(f"BMP: {width}x{height} {bpp}bpp pixel_offset={pixel_offset}")

bytes_per_pixel = bpp // 8
row_stride = ((width * bytes_per_pixel + 3) & ~3)

px = data[pixel_offset:]

def get_pixel(x, y_screen):
    """Return True if pixel at screen (x, y_screen) is non-black."""
    if bottom_up:
        bmp_row = height - 1 - y_screen
    else:
        bmp_row = y_screen
    off = bmp_row * row_stride + x * bytes_per_pixel
    pixel_bytes = px[off:off+bytes_per_pixel]
    return any(b != 0 for b in pixel_bytes)

# Radar area: x >= 560, y = 0..79
radar_nz = 0
radar_total = 0
for y in range(0, 80):
    for x in range(560, width):
        radar_total += 1
        if get_pixel(x, y):
            radar_nz += 1

# Full frame
full_nz = sum(1 for b in px if b != 0)

print(f"frame500 radar area (x>=560, y=0-79): non-black pixels = {radar_nz} / {radar_total}")
print(f"frame500 full-frame nz_bytes = {full_nz}")
print("PASS criterion: radar_nz >> 132 (pass-74 baseline was 132)")
PYEOF
    fi
    if command -v convert >/dev/null 2>&1; then
        convert "$PASS_DIR/frame500.bmp" "$PASS_DIR/frame500.png" 2>/dev/null && echo "frame500.png written"
    fi
fi

if [[ $RUN_RC -eq 124 ]]; then
    echo "PASS: game ran 90s without crash"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "PASS: game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
