#!/usr/bin/env bash
# TIM-250 pass-69: classic 640×480 viewport — inspect rendered frame
#
# Changes from pass-68:
#   - GLOBALS.CPP: ScreenWidth=640, ScreenHeight=480 (#ifndef _MSC_VER guard)
#   - STARTUP.CPP: SeenBuff/HidPage Attach uses actual dims on Linux
#
# Pass criterion: frame500.bmp has non-black pixels in the 640×480 region
#   (not scattered at the bottom of a 3072×3072 canvas)
#
# Run from repo root:
#   bash scripts/first-run-pass-69.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-69"
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
echo "=== Smoke test from $RUN_DIR (120s timeout) ==="
pkill -f "Xvfb :98" 2>/dev/null || true
Xvfb :98 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame500.bmp  # clear stale capture from prior runs
(cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true
# copy BMP capture (fires at present #500) into the pass directory
[[ -f /tmp/redalert-frame500.bmp ]] && cp /tmp/redalert-frame500.bmp "$PASS_DIR/frame500.bmp"

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- BMP capture ---"
grep -a "\[RA\] frame500 BMP" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- ScreenWidth / SeenBuff size ---"
grep -a -E "\[RA\] STARTUP|ScreenWidth|SeenBuff|640|480" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Start_Scenario ---"
grep -a -E "Start_Scenario|in-game phase" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Crash backtrace ---"
grep -a -E "CRASH signal|backtrace|\[[ 0-9]*\] " "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 30 lines ---"
tail -30 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

# Analyze BMP if captured
BMP="$PASS_DIR/frame500.bmp"
if [[ -f "$BMP" ]]; then
    echo ""
    echo "--- BMP analysis ---"
    python3 - "$BMP" <<'PYEOF'
import struct, sys
fname = sys.argv[1]
with open(fname,'rb') as f:
    data = f.read()
bfOffBits = struct.unpack_from('<I', data, 10)[0]
W = struct.unpack_from('<i', data, 18)[0]
H = abs(struct.unpack_from('<i', data, 22)[0])
biBitCount = struct.unpack_from('<H', data, 28)[0]
print(f"BMP: {W}x{H} {biBitCount}bpp")
stride = W * (biBitCount // 8)
pixel_data = memoryview(data)[bfOffBits:]
nz = 0
col_min = W; col_max = 0; row_min = H; row_max = 0
for row in range(H):
    row_off = row * stride
    for col in range(W):
        p = col * (biBitCount // 8)
        if biBitCount == 32:
            b = pixel_data[row_off+p]; g = pixel_data[row_off+p+1]; r = pixel_data[row_off+p+2]
        else:
            # 8bpp indexed — any non-zero index counts as content
            r = pixel_data[row_off+p]; g = r; b = r
        if r > 10 or g > 10 or b > 10:
            nz += 1
            if col < col_min: col_min = col
            if col > col_max: col_max = col
            if row < row_min: row_min = row
            if row > row_max: row_max = row
print(f"Non-black pixels: {nz} / {W*H} ({100*nz//(W*H)}%)")
if nz:
    print(f"Content bbox: cols {col_min}..{col_max}, rows {row_min}..{row_max}")
    print(f"Content size: {col_max-col_min+1}x{row_max-row_min+1}px")
else:
    print("All black — surface not rendering")
PYEOF
fi

echo ""
if [[ $RUN_RC -eq 124 ]]; then
    echo "PASS: game ran for 120s without crash"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV"
elif grep -qa "CRASH signal" "$LOG"; then
    echo "INFO: crashed — check backtrace above"
else
    echo "INFO: rc=$RUN_RC"
fi
