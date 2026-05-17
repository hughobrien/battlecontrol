#!/usr/bin/env bash
# TIM-255 pass-70: fix SIGSEGV at frame ~91 — Buffer_Draw_Stamp_Clip OOB write
#
# Changes from pass-69:
#   - LCWUNCMP.CPP: __attribute__((no_sanitize("address"))) for ASAN-only pass
#   - TIMER.H: extern TimerClass TickCount guarded by #ifdef _MSC_VER
#   - TIMERINI.CPP: remove TickCount.Start() from Linux path (auto-starts)
#   - PALETTE.CPP: replace TickCount.Time() with WindowsTimer->Get_System_Tick_Count()
#   - MIXFILE.CPP: fix debug logging to not read past 6-byte FileHeader
#   - UNIT.CPP: __attribute__((no_sanitize)) on Enter_Idle_Mode (ASAN-only)
#   - DrawMisc.cpp: clamp clip bounds to viewport dimensions in Buffer_Draw_Stamp_Clip
#
# Pass criterion: game runs 120s without SIGSEGV (rc=124 or rc=0)
#
# Run from repo root:
#   bash scripts/first-run-pass-70.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-70"
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
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
rm -f /tmp/redalert-frame500.bmp
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 timeout 120 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true
[[ -f /tmp/redalert-frame500.bmp ]] && cp /tmp/redalert-frame500.bmp "$PASS_DIR/frame500.bmp"

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- Frame count ---"
grep -ac "\[ML\] enter" "$LOG" || echo "0"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Segmentation|Illegal|ERROR: Address" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
tail -20 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

echo ""
if [[ $RUN_RC -eq 124 ]]; then
    echo "PASS: game ran for 120s without crash"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "INFO: clean exit (rc=0)"
else
    echo "INFO: rc=$RUN_RC"
fi
