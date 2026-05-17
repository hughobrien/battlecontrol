#!/usr/bin/env bash
# TIM-212 pass-59: fix _ShapeBuffer heap overlap — decompress directly into BigShapeBuffer
#
# Root cause (TIM-212): on LP64 Linux, new unsigned char[128KB] allocated at line 3535
#   of INIT.CPP (after Init_Heaps at line 373) lands at 0x5acc5c0 — the same heap address
#   as ClassHospital.PrimaryWeapon (BuildingTypes.Buffer + 12240).  Build_Frame() used
#   _ShapeBuffer as an intermediate decompression target; the very first Dialog_Box render
#   (DD-BKGND.SHP) via Apply_XOR_Delta wrote byte 0x81 to PrimaryWeapon, causing SIGSEGV
#   much later in TechnoTypeClass::Read_INI at [this+0x190].
#
# Fix (2KEYFRAM.CPP): precompute BigShapeBuffer/TheaterShapeBuffer destination
#   (effective_buffptr) before decompression. All LCW_Uncompress and Apply_Delta calls
#   now write directly to the final destination. The intermediate memcpy is removed.
#
# Run from repo root:
#   bash scripts/first-run-pass-59.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-59"
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
grep -a -E "Start_Scenario|in-game phase" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TechnoTypeClass / Read_INI progress ---"
grep -a -E "TechnoType|Read_INI|Objects\(\)|RulesClass|Read_Scenario" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- Crash/assert ---"
grep -a -E "assert|Assertion|SIGILL|SIGSEGV|abort|Abort" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 30 lines ---"
tail -30 "$LOG"
echo ""
echo "Full log: $LOG ($(wc -l < "$LOG" 2>/dev/null || echo '?') lines)"

if grep -qa "Start_Scenario OK" "$LOG"; then
    echo "PASS: in-game phase reached — TIM-212 fix verified!"
elif grep -qa "calling Start_Scenario" "$LOG"; then
    echo "INFO: Start_Scenario called — check for crash after"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV"
elif [[ $RUN_RC -eq 124 ]]; then
    echo "INFO: timeout — alive after 120s (check log for progress)"
else
    echo "INFO: rc=$RUN_RC"
fi
