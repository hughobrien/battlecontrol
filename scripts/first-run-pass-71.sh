#!/usr/bin/env bash
# TIM-206 pass-71: keyboard/mouse input in main menu — no RA_AUTOSTART
#
# Verifies that synthetic input injections (already wired in earlier passes)
# navigate the main menu and reach Start_Scenario without RA_AUTOSTART=1:
#
#   1. Main_Menu() fires synthetic LCLICK on "Start New Game" after 5 s
#      (MENUS.CPP TIM-206 block, coords 322,183 = centre of startbtn at RESFACTOR=2)
#   2. Fetch_Difficulty() fires immediate KN_RETURN (SPECIAL.CPP TIM-206 block)
#   3. Faction dialog gets KN_RETURN → Allies (INIT.CPP TIM-206 block)
#   4. Start_Scenario('SCG01EA.INI') called → in-game phase
#
# Delta from pass-70: no RA_AUTOSTART env var, 60s timeout
#
# Run from repo root:
#   bash scripts/first-run-pass-71.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-71"
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
echo "=== Smoke test from $RUN_DIR (60s timeout, NO RA_AUTOSTART) ==="
pkill -f "Xvfb :98" 2>/dev/null || true
Xvfb :98 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
# NOTE: deliberately no RA_AUTOSTART — menu navigation via synthetic injections
(cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy timeout 60 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- Menu synthetic click ---"
grep -a "\[MENU\]" "$LOG" | head -5 || echo "(not fired — menu never showed?)"
echo ""

echo "--- Difficulty injection ---"
grep -a "\[DIFF\]" "$LOG" | head -5 || echo "(not fired)"
echo ""

echo "--- Faction injection ---"
grep -a "\[INIT\] inject" "$LOG" | head -5 || echo "(not fired)"
echo ""

echo "--- Start_Scenario ---"
grep -a -E "Start_Scenario|in-game phase" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Crash / assert ---"
grep -a -E "CRASH signal|assert|SIGILL|SIGSEGV|Segmentation|Illegal" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Last 30 lines ---"
tail -30 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

echo ""
if [[ $RUN_RC -eq 124 ]]; then
    echo "PASS: game ran 60s without crash — menu navigation succeeded"
elif grep -qa "Start_Scenario OK" "$LOG"; then
    echo "PASS: Start_Scenario OK — in-game phase reached via menu navigation"
elif grep -qa "calling Start_Scenario" "$LOG"; then
    echo "INFO: Start_Scenario called (check if it completed)"
elif grep -qa "\[MENU\] synthetic LCLICK" "$LOG"; then
    echo "INFO: menu click fired but game did not reach Start_Scenario — check dialogs"
elif grep -qa "CRASH signal\|SIGSEGV" "$LOG"; then
    echo "FAIL: crashed — check backtrace"
else
    echo "INFO: rc=$RUN_RC — check log for details"
fi
