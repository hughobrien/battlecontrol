#!/usr/bin/env bash
# TIM-206 pass-54: RA_AUTOSTART bypass → first mission launch
#
# Delta from pass-53:
#   INIT.CPP: RA_AUTOSTART env var bypass in SEL_START_NEW_GAME — skips
#             Fetch_Difficulty() and WWMessageBox faction choice; sets
#             EASY difficulty, picks SCG01EA.INI (Allies mission 1).
#   INIT.CPP: probe logging around Start_Scenario() call.
#   Uses dedicated shim dir (build/include-shim-pass-54) to avoid race.
#
# Expected:
#   compile ok=307 fail=0
#   link rc=0
#   [RA] Select_Game: RA_AUTOSTART active → SCG01EA.INI (EASY)
#   [RA] Select_Game: calling Start_Scenario('SCG01EA.INI')
#   [RA] Select_Game: Start_Scenario OK — in-game phase
#
# Run from repo root:
#   bash scripts/first-run-pass-54.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim-pass-54"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-54"
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
echo "=== Smoke test from $RUN_DIR (90s timeout) ==="
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 timeout 90 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV)"
echo ""

echo "--- RA_AUTOSTART path ([RA] Select_Game) ---"
grep -a "\[RA\] Select_Game" "$LOG" | head -10 || echo "(not fired)"
echo ""

echo "--- Menu navigation ([MENU]) ---"
grep -a "\[MENU\]" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Mission-phase indicators ---"
grep -a -E "Start_Scenario|in-game phase|scenario.*load|CONQUER|map.*load|MainLoop" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Traceback" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 20 lines ---"
strings "$LOG" | tail -20
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG" 2>/dev/null || echo '?') lines)"

if grep -qa "Start_Scenario OK" "$LOG"; then
    echo "PASS: in-game phase reached — mission launched"
elif grep -qa "calling Start_Scenario" "$LOG"; then
    echo "INFO: Start_Scenario called — check for crash after"
elif grep -qa "RA_AUTOSTART active" "$LOG"; then
    echo "INFO: RA_AUTOSTART bypass triggered — Start_Scenario not reached yet"
else
    echo "INFO: RA_AUTOSTART bypass not triggered — check [MENU] lines"
fi
