#!/usr/bin/env bash
# TIM-363: RA debug-cheat smoke test.
#
# Runs RedAlert under Xvfb with RA_AUTOSTART=1 RA_CHEAT=1 and verifies:
#   frame 30  → +10000 credits
#   frame 35  → Debug_Cheat=true (tech-level 98)
#   frame 40  → Debug_Unshroud=true (map revealed)
#   frame 200 → Flag_To_Win fired (debrief sequence)
#
# Prerequisites:
#   - build/include-shim/ (run generate-include-shim.py first)
#   - linux/win32-stubs/   (source tree — no build step needed)
#   - build/run-172/       (game data dir; run scripts/first-run-pass-94.sh or
#                           setup-run-ra-remastered.sh to populate it)
#   - Xvfb, xdpyinfo
#
# Run from repo root:
#   bash scripts/run-ra-cheat.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
BUILD_DIR="$REPO_ROOT/build/ra-cheat"
OBJ_DIR="$BUILD_DIR/obj"
RUN_DIR="$REPO_ROOT/build/run-172"
LINK_BIN="$BUILD_DIR/redalert.elf"
DISPLAY_NUM="${RA_DISPLAY:-:99}"
TIMEOUT_SECS=90
LOG="$BUILD_DIR/ra-cheat-run.log"

# ---- prerequisites ----
if [ ! -d "$SHIM_DIR/redalert" ]; then
    echo "ERROR: include-shim not found at $SHIM_DIR" >&2
    echo "  Run: python3 scripts/generate-include-shim.py --repo-root . --shim-root build/include-shim" >&2
    exit 1
fi

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: game data dir $RUN_DIR not found." >&2
    echo "  Run: bash scripts/first-run-pass-94.sh  (or setup-run-ra-remastered.sh)" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

# ---- compile ----
python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --quiet

CXX="${CXX:-g++}"

CXXFLAGS=(
    -std=c++17
    -c
    -fmax-errors=20
    -fno-strict-aliasing
    -w
    -O2
    -g
    -rdynamic
    -fno-omit-frame-pointer
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

echo "=== Linking → $LINK_BIN ==="
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic -fno-omit-frame-pointer \
    -O2 \
    "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
LINK_RC=$?
echo "Link rc=$LINK_RC"
if [[ $LINK_RC -ne 0 ]]; then
    echo "FAIL: link failed"
    exit 1
fi

# ---- Xvfb ----
DISP_NUM="${DISPLAY_NUM#:}"
if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
    echo "Starting Xvfb $DISPLAY_NUM ..."
    Xvfb "$DISPLAY_NUM" -screen 0 640x480x24 -ac &
    XVFB_PID=$!
    sleep 1
    if [ ! -e "/tmp/.X${DISP_NUM}-lock" ]; then
        echo "ERROR: Xvfb $DISPLAY_NUM did not start." >&2
        exit 1
    fi
else
    echo "Xvfb $DISPLAY_NUM already running."
    XVFB_PID=""
fi

# ---- run ----
echo "Running RA cheat smoke test (timeout ${TIMEOUT_SECS}s) ..."
(cd "$RUN_DIR" && DISPLAY="$DISPLAY_NUM" SDL_AUDIODRIVER=dummy \
    RA_AUTOSTART=1 RA_CHEAT=1 \
    timeout "$TIMEOUT_SECS" "$LINK_BIN") > "$LOG" 2>&1 || true

if [ -n "${XVFB_PID:-}" ]; then
    kill "$XVFB_PID" 2>/dev/null || true
fi

echo "--- run log (last 40 lines) ---"
tail -40 "$LOG"
echo "--- end log ---"
echo ""

# ---- verify ----
PASS=1

check() {
    local label="$1"; local pattern="$2"
    if grep -q "$pattern" "$LOG"; then
        echo "  PASS: $label"
    else
        echo "  FAIL: $label (pattern: '$pattern' not found)"
        PASS=0
    fi
}

check "smoke milestone (≥10 frames)"       "\[RA\] Main_Loop frame 10"
check "credits grant (frame 30)"           "\[RA-CHEAT\] frame 30: +10000 credits"
check "tech-level 98 (frame 35)"           "\[RA-CHEAT\] frame 35: Debug_Cheat=true"
check "map revealed (frame 40)"            "\[RA-CHEAT\] frame 40: Debug_Unshroud=true"
check "win sequence fired (frame 200)"     "\[RA-CHEAT\] frame 200: Flag_To_Win fired"

echo ""
if [ "$PASS" -eq 1 ]; then
    echo "RESULT: PASS — all cheat milestones reached."
    exit 0
else
    echo "RESULT: FAIL — one or more milestones missing (see log: $LOG)"
    exit 1
fi
