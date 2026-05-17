#!/usr/bin/env bash
# TIM-277 pass-77: fix sidebar bottom gap rendering at 640x480
#
# Changes from pass-76:
#   - REDALERT/SIDEBAR.CPP: Draw_It — Fill_Rect covers x=480-639, y=400-479
#     with LTGREY when screen_h > 400, closing the 640x400-vs-640x480 gap.
#   - REDALERT/DISPLAY.CPP: Redraw_Icons — one-shot diagnostic logging of
#     TacPixelX/Y, TacLeptonW/H, MapCellX/Y/W/H, WINDOW_TACTICAL, TacticalCoord.
#
# Pass criterion:
#   - Compile ok, link ok, smoke test runs 90s without SIGSEGV
#   - frame500 sidebar bottom (x>=480, y>=400): non-black pixel count >= 12000
#     (160px wide x 80px tall = 12800 total; fill at LTGREY → most non-black)
#   - Log shows TIM-277 diagnostic with TacLeptonH >= 4000
#
# Run from repo root:
#   bash scripts/first-run-pass-77.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-77"
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
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame500.bmp
# RA_AUTOSTART=1: deliberately skips ~200s of VQA intro movies (TIM-665).
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 90 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- TIM-277 diagnostic ---"
grep -a "TIM-277" "$LOG" | head -20 || echo "(no TIM-277 log)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
tail -20 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
echo ""

# Pixel analysis: corrected for 32bpp (skip alpha byte)
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

px_data = data[pixel_offset:]

def get_row(y_screen):
    if bottom_up:
        bmp_row = height - 1 - y_screen
    else:
        bmp_row = y_screen
    return bmp_row * row_stride

def is_nonblack(x, y):
    off = get_row(y) + x * bytes_per_pixel
    b = px_data[off:off+3]   # BGR only; skip alpha at off+3
    return any(v != 0 for v in b)

def zone(x0, x1, y0, y1, label):
    nz = 0; total = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            total += 1
            if is_nonblack(x, y): nz += 1
    pct = 100.0 * nz / total if total else 0
    print(f"  {label}: {nz:6d}/{total:6d} = {pct:5.1f}%")
    return nz

print("Zone analysis:")
zone(0, width,   0,  16, "Top bar    y=0-15  ")
zone(0, 480,    16, 400, "Tac map    x=0-479 y=16-399")
zone(0, 480,   400, 480, "Tac bottom x=0-479 y=400-479")
zone(480, 640,   0,  16, "Sidebar hd x=480+ y=0-15 ")
zone(480, 640,  16, 400, "Sidebar    x=480+ y=16-399")
sb_bottom = zone(480, 640, 400, 480, "Sidebar bt x=480+ y=400-479  ← TIM-277 target")
total_bottom = (640 * 80)
print(f"\nPass criterion: sidebar_bottom >= 12000 (got {sb_bottom}/{total_bottom} = {100.0*sb_bottom/total_bottom:.1f}%)")
if sb_bottom >= 12000:
    print("PASS: sidebar bottom gap is filled")
else:
    print("FAIL: sidebar bottom still mostly black")
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
