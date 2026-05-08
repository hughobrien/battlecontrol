#!/usr/bin/env bash
# TIM-206 pass-53: button text + synthetic LCLICK input path
#
# Delta vs pass-52:
#   MIXFILE.CPP: removed verbose FULL index dump — Init_Bulk_Data now <5s
#   GADGET.CPP:  (key&0xFF)==VK_LBUTTON/VK_RBUTTON/VK_MBUTTON instead of broken
#                byte-mask compare against KN_LMOUSE (0x1001 never fits in a byte)
#   KEY.CPP:     vk |= WWKEY_VK_BIT for both keyboard and mouse SDL events
#   KEYBOARD.H:  Is_Mouse_Key() moved to public (was private — accessible from GADGET)
#   MENUS.CPP:   synthetic LCLICK at (322,183) after 5 s instead of VK_RETURN
#
# Expected:
#   compile ok=307+ fail=0
#   link rc=0
#   [MENU] synthetic LCLICK at (322,183) at tick ~300
#   [RA] first SDL frame presented
#   Menu transition after click (new [STP] calls or scenario start)
#
# Run from repo root:
#   bash scripts/first-run-pass-53.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-53"
OBJ_DIR="$PASS_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-172"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
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
echo "=== Smoke test from $RUN_DIR (60s timeout) ==="
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 60 "$LINK_BIN") > "$LOG" 2>&1 &
GAME_PID=$!

# Screenshot timeline: t=8s (should show loading/title), t=20s (menu expected), t=45s (after click)
sleep 8;  DISPLAY=:99 import -window root "$PASS_DIR/screen_t08.png" 2>/dev/null || true
sleep 12; DISPLAY=:99 import -window root "$PASS_DIR/screen_t20.png" 2>/dev/null || true
sleep 25; DISPLAY=:99 import -window root "$PASS_DIR/screen_t45.png" 2>/dev/null || true

wait "$GAME_PID"
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- Frame milestone ---"
grep -E "\[RA\] first SDL frame|SDL_ShowWindow" "$LOG" | head -5
echo ""

echo "--- DIALOG_BLUE remap ---"
grep "\[RA\] DIALOG_BLUE" "$LOG" | head -3
echo ""

echo "--- Simple_Text_Print calls ([STP]) ---"
grep "\[STP\]" "$LOG" | head -30
echo ""

echo "--- Menu input / synthetic LCLICK ([MENU]) ---"
grep "\[MENU\]" "$LOG" | head -20
echo ""

echo "--- Init milestones ---"
grep -E "\[RA\] Init_Game|\[RA\] Bootstrap|\[RA\] STARTUP|\[RA\] Main_Menu|Enter_Main_Menu" "$LOG" | head -20
echo ""

echo "--- Crash/assert indicators ---"
grep -E "assert|Assertion|SIGILL|SIGSEGV|abort|Segmentation" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
tail -20 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

# Screenshots
for f in "$PASS_DIR"/screen_t*.png; do
    [[ -f "$f" ]] || continue
    colors=$(identify -format "%k" "$f" 2>/dev/null || echo "?")
    size=$(wc -c < "$f")
    echo "Screenshot $(basename "$f"): ${size}B, ${colors} colors"
done

echo ""
if grep -q "\[MENU\] synthetic LCLICK" "$LOG"; then
    echo "PASS: synthetic LCLICK injected"
    if grep -q "\[STP\].*New.*Game\|scenario\|SCEN\|select" "$LOG" -i; then
        echo "PASS: scenario selection UI reached"
    else
        echo "INFO: click injected — check screenshots for menu transition"
    fi
else
    echo "INFO: LCLICK not yet injected (run too short or menu loop not reached)"
fi
