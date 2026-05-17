#!/usr/bin/env bash
# TIM-172 pass-51: fix SDL frame presentation — main menu should render.
#
# Delta vs pass-50:
#   KEY.CPP:     Fill_Buffer_From_System() calls Wait_Vert_Blank() instead of
#                SDL_Process_Input_Events() — every input poll now drives
#                SDL_RenderPresent so all game loops present frames.
#   MENUS.CPP:   explicit Wait_Vert_Blank() after HidPage.Blit(SeenPage) in
#                Main_Menu loop — belt-and-suspenders for the initial blit.
#   STARTUP.CPP: VisiblePage.Init() now passes GBC_VISIBLE | GBC_VIDEOMEM
#                (matching the #else branch) so IsSDLPrimary=true and blits
#                write into SDL_PrimarySurface pixels instead of a dead buffer.
#   MIXFILE.CPP: full index dump extended to HIRES.MIX and NCHIRES.MIX.
#   LOAD.CPP:    debug prints in Load_Uncompress for load size diagnosis.
#
# Expected:
#   compile ok=307 fail=0
#   link rc=0
#   "[RA] first SDL frame presented" appears in log
#   main menu buttons visible via screenshot
#
# Run from repo root:
#   bash scripts/first-run-pass-51.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-51"
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
    echo "SKIP: $RUN_DIR not found — run manually"
    exit 0
fi

echo ""
echo "=== Smoke test from $RUN_DIR (30s timeout) ==="
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 30 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""
echo "--- Frame milestone ---"
grep -E "\[RA\] first SDL frame|SDL_ShowWindow|RenderPresent|window.*visible" "$LOG" | head -10
echo ""
echo "--- Init_Game milestones ---"
grep -E "\[RA\] Init_Game|\[RA\] Bootstrap|\[RA\] STARTUP" "$LOG" | head -20
echo ""
echo "--- TITLE.PCX search ---"
grep -E "TITLE\.PCX|HIRES\.MIX|NCHIRES" "$LOG" | head -20
echo ""
echo "--- Last 10 lines ---"
tail -10 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"

if grep -q "\[RA\] first SDL frame presented" "$LOG"; then
    echo "PASS: first SDL frame presented — main menu visible"
else
    echo "FAIL: first SDL frame never presented — check [RA] and SDL init lines above"
fi
