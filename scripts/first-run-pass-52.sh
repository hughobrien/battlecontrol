#!/usr/bin/env bash
# TIM-206 pass-52: keyboard/mouse input diagnostics + synthetic VK_RETURN test
#
# Probes active in this pass (all #ifndef _MSC_VER):
#   INIT.CPP:   dump ColorRemaps[PCOLOR_DIALOG_BLUE] after Init_Color_Remaps
#   DIALOG.CPP: log first 20 Simple_Text_Print calls ([STP])
#   MENUS.CPP:  inject VK_RETURN after 5s, log non-zero input events ([MENU])
#   DDRAW.CPP:  SDL event log (from pass-51)
#
# Expected:
#   compile ok=307+ fail=0
#   link rc=0
#   [RA] DIALOG_BLUE: Color/BrightColor/FontRemap visible
#   [STP] lines showing button text + remap color
#   [MENU] synthetic VK_RETURN injected at tick ~300
#   [MENU] input=... line after injection (menu transition)
#
# Run from repo root:
#   bash scripts/first-run-pass-52.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim-pass-52"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-52"
OBJ_DIR="$PASS_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-172"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --quiet

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
echo "=== Smoke test from $RUN_DIR (30s timeout — 5s for LCLICK injection) ==="
pkill Xvfb 2>/dev/null || true
rm -f /tmp/.X99-lock
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 30 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- Simple_Text_Print calls ([STP]) ---"
grep -a "\[STP\]" "$LOG" | head -30 || echo "(none)"
echo ""

echo "--- Menu input / synthetic mouse click ([MENU]) ---"
grep -a "\[MENU\]" "$LOG" || echo "(none — LCLICK injection may not have fired)"
echo ""

echo "--- Difficulty dialog ([DIFF]) ---"
grep -a "\[DIFF\]" "$LOG" || echo "(none)"
echo ""

echo "--- Init_Game / mission launch milestones ---"
grep -aE "\[RA\] Init_Game|\[RA\] Bootstrap|\[RA\] STARTUP|\[RA\] first SDL frame|Scenario|Load_Scenario|Init_Scenario|Game_Main|Map.*init|Alloc.*Heap" "$LOG" | head -25
echo ""

echo "--- Crash/assert indicators ---"
grep -aE "assert|Assertion|SIGILL|SIGSEGV|abort|core dump" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
tail -20 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

# Grade the run
if grep -qa "\[DIFF\] injecting" "$LOG"; then
    echo "PASS-A: difficulty dialog injection fired"
    if grep -qa "Load_Scenario\|Init_Scenario\|Scenario\|Map.*init\|mission" "$LOG"; then
        echo "PASS-B: mission loading detected — in-game!"
    else
        echo "INFO: difficulty injected but mission not detected yet (run longer or more passes needed)"
    fi
elif grep -qa "\[MENU\] input=" "$LOG"; then
    echo "PARTIAL: START button clicked and registered, but difficulty dialog not reached in time"
    echo "  → increase timeout or reduce debug verbosity"
elif grep -qa "\[MENU\] synthetic LCLICK" "$LOG"; then
    echo "PARTIAL: LCLICK injected but no input= event seen"
else
    echo "INFO: LCLICK not injected (run too short?) or menu loop not reached"
fi
