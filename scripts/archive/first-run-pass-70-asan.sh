#!/usr/bin/env bash
# TIM-255 pass-70 ASAN: catch OOB write that causes SIGSEGV at frame ~91
#
# Same source as pass-69 but compiled with AddressSanitizer to get the exact
# OOB write site. Run this first to identify the bug, then fix it in the
# clean pass-70 build.
#
# Run from repo root:
#   bash scripts/first-run-pass-70-asan.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-70-asan"
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
    -fno-omit-frame-pointer
    -fsanitize=address
    -fsanitize-recover=address
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
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic -fsanitize=address "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
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
echo "=== ASAN smoke test from $RUN_DIR (60s timeout) ==="
pkill -f "Xvfb :98" 2>/dev/null || true
Xvfb :98 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"
# ASAN options: continue past errors, symbolize for READ/WRITE classification.
# alloc_dealloc_mismatch=0: suppress new[]/delete mismatch (pre-existing LP64 issue in BufferClass)
# max_errors=500: allow enough errors to get through scenario loading to the game loop
export ASAN_OPTIONS="detect_leaks=0:halt_on_error=0:new_delete_type_mismatch=0:alloc_dealloc_mismatch=0:symbolize=1:print_stacktrace=1:max_errors=500"
export ASAN_SYMBOLIZER_PATH="$(which llvm-symbolizer 2>/dev/null || which addr2line 2>/dev/null || true)"

(cd "$RUN_DIR" && DISPLAY=:98 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    timeout 60 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean, 124=timeout=alive, 134=abort=ASAN, 139=SIGSEGV)"
echo ""

echo "--- ASAN report ---"
grep -a "ERROR: AddressSanitizer\|heap-buffer-overflow\|stack-buffer-overflow\|WRITE of size\|READ of size\|#[0-9]" "$LOG" | head -60 || echo "(none)"
echo ""

echo "--- Last 40 lines ---"
tail -40 "$LOG"

echo ""
echo "Full log: $LOG ($(wc -l < "$LOG") lines)"
