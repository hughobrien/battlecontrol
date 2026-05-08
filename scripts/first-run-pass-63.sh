#!/usr/bin/env bash
# TIM-206 pass-63: IControl_Type LP64 fix — long → int32_t in tile iconset struct
#
# Root cause: IControl_Type in WIN32LIB/TILE.H used `long` for offset fields
# (Size, Icons, Palettes, Remaps, TransFlag, ColorMap, Map). On LP64, long=8 bytes
# but these are 4-byte file-format offsets. The struct layout was 72 bytes vs the
# on-disk 40-byte format, so ColorMap landed at struct offset 56 instead of 32,
# reading garbage → TemplateTypeClass::Land_Type crash in Control_Map().
#
# Fix: change all 7 offset fields to int32_t in TILE.H and COMPAT.H.
#
# Delta from pass-57:
#   TILE.H: long → int32_t for all offset fields; add #include <stdint.h>
#   COMPAT.H: same for #ifndef WIN32 path
#   (CONQUER.CPP Get_Radar_Icon fix was already in tree)
#
# Expected:
#   compile ok=307 fail=0
#   link rc=0
#   scenario loads past MapClass::Read_Binary / TemplateTypeClass::Land_Type

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-63"
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
"$CXX" -no-pie -fuse-ld=bfd "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
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
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- RA_AUTOSTART path ---"
grep -a "\[RA\] Select_Game" "$LOG" | head -5 || echo "(not fired)"
echo ""

echo "--- Start_Scenario result ---"
grep -a -E "Start_Scenario|in-game phase|Read_Scenario" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Land_Type / Read_Binary / Template ---"
grep -a -E "Land_Type|Read_Binary|TemplateType|Recalc|Map_Width|Map_Height" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Mission phase indicators ---"
grep -a -E "GameActive|scenario|CONQUER|TeamTypeClass|HouseClass|Init_Game" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Segmentation|Illegal" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 30 lines ---"
strings "$LOG" | tail -30
echo ""
echo "Full log: $LOG"

if grep -qa "Start_Scenario OK" "$LOG"; then
    echo "PASS: in-game phase reached — mission launched!"
elif grep -qa "calling Start_Scenario\|Start_Scenario" "$LOG" && ! grep -qa "SIGSEGV\|Segmentation" "$LOG"; then
    echo "INFO: Start_Scenario called — check for post-scenario crash"
elif grep -qa "RA_AUTOSTART active" "$LOG"; then
    echo "INFO: RA_AUTOSTART bypass triggered — Start_Scenario not reached"
else
    echo "INFO: No clear signal"
fi
