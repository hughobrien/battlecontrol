#!/usr/bin/env bash
# TIM-195 pass-48: Fix FileHeader struct padding + idx debug, then smoke-test.
#
# Delta vs pass-161 / 9abec0b:
#   MIXFILE.H: __attribute__((packed)) on FileHeader typedef (sizeof 8→6),
#     fixes DataSize reading (was -517340802, now 25,047,188 ≈ file size).
#   MIXFILE.CPP: print up to 8 index entries after index read.
#   PKSTRAW.CPP: print all BLOWFISH_KEY_SIZE key bytes (was first 16 only).
#
# Strategy: incremental — reuse pass-161 objects, recompile only changed TUs,
# relink. Smoke-test from the run-172 data directory (REDALERT.MIX + MAIN.MIX).
#
# Expected:
#   - sizeof(FileHeader)=6 in new binary
#   - idx[0..5] printed with valid CRC values
#   - LOCAL.MIX via CCFile=YES
#   - Bootstrap_Mix proceeds past LOCAL.MIX assert

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"

BASE_PASS="$REPO_ROOT/build/first-link-pass-161"
PASS_DIR="$REPO_ROOT/build/first-run-pass-48"
OBJ_DIR="$PASS_DIR/obj"

RUN_DIR="$REPO_ROOT/build/run-172"

mkdir -p "$PASS_DIR" "$OBJ_DIR"

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

# Compile only the changed TUs
echo "=== Recompiling changed TUs ==="
ok=0
fail=0
for src in \
    "$SRC_DIR/MIXFILE.CPP" \
    "$SRC_DIR/PKSTRAW.CPP"; do
    base="$(basename "$src" .cpp)"
    base="${base%.CPP}"
    obj="$OBJ_DIR/${base}.o"
    rel="${src#$REPO_ROOT/}"
    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" 2>&1; then
        echo "OK   $rel"
        ok=$((ok+1))
    else
        echo "FAIL $rel"
        fail=$((fail+1))
    fi
done
echo "compile ok=$ok fail=$fail"
if [[ $fail -gt 0 ]]; then
    echo "FAIL: compile errors, aborting"
    exit 1
fi

# Collect all objects: pass-161 objs minus changed TUs, plus new objs
echo "=== Collecting objects for link ==="
OBJECTS=()
for o in "$BASE_PASS/obj/REDALERT/"*.o "$BASE_PASS/obj/REDALERT/WIN32LIB/"*.o "$BASE_PASS/obj/STUBS/"*.o; do
    base="$(basename "$o" .o)"
    if [[ -f "$OBJ_DIR/${base}.o" ]]; then
        OBJECTS+=( "$OBJ_DIR/${base}.o" )
    else
        OBJECTS+=( "$o" )
    fi
done
echo "Total objects: ${#OBJECTS[@]}"

# Link
LINK_BIN="$PASS_DIR/redalert.elf"
echo "=== Linking → $LINK_BIN ==="
"$CXX" -no-pie -fuse-ld=bfd "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
LINK_RC=$?
echo "Link rc=$LINK_RC"
if [[ $LINK_RC -ne 0 ]]; then
    echo "FAIL: link failed"
    exit 1
fi

# Smoke test: run from the run-172 data dir
echo ""
echo "=== Smoke test from $RUN_DIR ==="
if [[ ! -d "$RUN_DIR" ]]; then
    echo "SKIP: $RUN_DIR not found — run manually"
    exit 0
fi

pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 12 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout, 134=abort)"
grep -E "\[MIX\] ctor: REDALERT.MIX fileheader sizeof|idx\[|LOCAL.MIX via CCFile|Bootstrap_Mix: LOCAL.MIX cache|ASSERT" "$LOG" | head -20
echo ""
echo "Full log: $LOG"

if grep -q "LOCAL.MIX via CCFile=YES" "$LOG"; then
    echo "PASS: LOCAL.MIX found inside REDALERT.MIX"
elif grep -q "LOCAL.MIX NOT available" "$LOG"; then
    echo "FAIL: LOCAL.MIX still not found — may not be inside REDALERT.MIX"
else
    echo "INFO: could not determine result — check $LOG"
fi
