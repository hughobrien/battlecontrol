#!/usr/bin/env bash
# TIM-195 pass-49: full rebuild + Cache debug — diagnose LOCAL.MIX cache=FAIL.
#
# Delta vs pass-161 objects:
#   MIXFILE.H:   __attribute__((packed)) on FileHeader (sizeof 8→6)
#   MIXFILE.CPP: idx[0..7] debug prints, Cache Is_Open/DataStart/DataSize/actual,
#                Offset list-count + per-mixfile debug
#   PKSTRAW.CPP: print all BLOWFISH_KEY_SIZE key bytes
#   WINSTUB.CPP: Assert_Failure → stderr + abort (already committed)
#
# Why full rebuild (not incremental):
#   MIXFILE.H is a template header; any TU including it needs recompilation.
#   Mixing new MIXFILE.o with old instantiation objects causes undefined-reference
#   link errors for Retrieve/Cache/Free_All.
#
# Expected:
#   compile ok=301 fail=0
#   link rc=0
#   [MIX] Cache(LOCAL.MIX): DataStart=... DataSize=... actual=... printed
#   Either actual==DataSize (cache ok, assert shouldn't fire) or actual!=DataSize
#   (read failure — investigate bias/size)
#
# Run from repo root:
#   bash scripts/first-run-pass-49.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-49"
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
echo "=== Smoke test from $RUN_DIR ==="
pkill Xvfb 2>/dev/null || true
Xvfb :99 -screen 0 1024x768x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy timeout 15 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout, 134=abort)"
echo ""
echo "--- Key output ---"
grep -E "\[MIX\]|\[PKS\]|\[RA\]|\[ASSERT\]|Bootstrap_Mix|LOCAL.MIX|REDALERT.MIX|sizeof" "$LOG" | head -60
echo ""
echo "Full log: $LOG"

if grep -q "LOCAL.MIX via CCFile=YES" "$LOG"; then
    echo "PASS: LOCAL.MIX found inside REDALERT.MIX"
fi
if grep -q "Bootstrap_Mix.*cache=FAIL" "$LOG" || grep -q "assert.*ok.*failed" "$LOG"; then
    echo "FAIL: LOCAL.MIX Cache still failing — check [MIX] Cache lines above"
elif grep -q "Cache.*actual=" "$LOG"; then
    echo "INFO: Cache result visible — check [MIX] Cache lines above"
fi
