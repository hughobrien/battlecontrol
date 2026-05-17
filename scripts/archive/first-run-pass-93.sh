#!/usr/bin/env bash
# TIM-313 pass-93: fix MissionControl[-1] OOB reads in TECHNO.CPP / FOOT.CPP
#
# FIXES IN THIS PASS:
#
#   FOOT.CPP  - Added SafeMC(MissionType) helper that returns a zero-initialized
#               sentinel MissionControlClass when Mission < 0 or >= MISSION_COUNT.
#               Replaced all 12 direct MissionControl[Mission] accesses with SafeMC().
#
#   TECHNO.CPP - Same SafeMC() helper added. Replaced 4 direct accesses:
#               - MissionControl[object->Mission].IsNoThreat
#               - MissionControl[infantry->Mission].IsRecruitable
#               - MissionControl[unit->Mission].IsRecruitable
#               - MissionControl[Mission].IsRetaliate
#
#   Semantics preserved: zero-initialized MissionControlClass has all bool flags
#   false and Rate=0 (Normal_Delay()=0), matching the BSS-zero reads that were
#   previously (incorrectly) happening via the OOB access.
#
# BUILD FLAGS:
#   -fsanitize=address  (NO -fsanitize-recover=address — halt on first error)
#
# ACCEPTANCE CRITERIA:
#   1. Build ok=307 rc=0
#   2. 3+ complete win cycles ([TIM-310] do_win #1, #2, #3)
#   3. Zero ASAN error lines in log
#   4. No heap-use-after-free, no SIGSEGV
#   5. TIM-311 never fires (Anims pool never exhausted)
#
# Run from repo root:
#   bash scripts/first-run-pass-93.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-93"
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
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic -fno-omit-frame-pointer \
    -fsanitize=address \
    "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 2>&1
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
echo "=== Smoke test from $RUN_DIR (300s timeout, RA_AUTOSTART=1, ASAN strict) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"

# ASAN options: no halt_on_error=0 / abort_on_error=0 — we want hard stops on real errors.
# Keep new_delete_type_mismatch=0 (pre-existing INIEntry mismatch, separate issue).
# Keep alloc_dealloc_mismatch=0 (pre-existing, separate from MissionControl OOBs).
ASAN_OPTIONS="new_delete_type_mismatch=0:alloc_dealloc_mismatch=0:detect_leaks=0:log_path=stderr"

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    ASAN_OPTIONS="$ASAN_OPTIONS" \
    timeout 300 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, other=crash/ASAN-abort)"
echo ""

echo "--- TIM-310 cycle probes ---"
grep -a "\[TIM-310\]" "$LOG" | head -60 || echo "(none)"
echo ""

echo "--- PLAYER-WINS ---"
grep -a "\[PLAYER-WINS\]" "$LOG" | head -30 || echo "(none)"
echo ""

echo "--- TIM-311 AnimClass pool probe ---"
grep -a "\[TIM-311\]" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- ASAN error summary ---"
grep -a "ERROR: AddressSanitizer\|SUMMARY: AddressSanitizer" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- heap-use-after-free ---"
grep -a "heap-use-after-free" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- global-buffer-overflow (MissionControl OOB) ---"
grep -a "global-buffer-overflow" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|signal 11" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 5 lines ---"
tail -5 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-313 pass-93 analysis ===\n")

wins   = [l for l in lines if '[PLAYER-WINS]' in l]
dowin  = [l for l in lines if 'do_win' in l]
tim311 = [l for l in lines if '[TIM-311]' in l]
asan_uaf = [l for l in lines if 'heap-use-after-free' in l]
asan_oob = [l for l in lines if 'global-buffer-overflow' in l]
asan_err = [l for l in lines if 'ERROR: AddressSanitizer' in l]
mc_oob   = [l for l in lines if 'MissionControl' in l and 'global-buffer-overflow' in l]

print(f"Win cycles completed:              {len(wins)}")
print(f"Do_Win calls:                      {len(dowin)}")
print(f"[TIM-311] pool failures:           {len(tim311)}")
print(f"ASAN heap-use-after-free:          {len(asan_uaf)}")
print(f"ASAN global-buffer-overflow:       {len(asan_oob)}")
print(f"  of which MissionControl OOB:     {len(mc_oob)}")
print(f"ASAN errors total:                 {len(asan_err)}")
print()

crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal|signal 11', l) for l in lines)

c1 = len(wins) >= 3
c2 = len(dowin) >= 3
c3 = len(asan_err) == 0
c4 = not crash and len(asan_uaf) == 0
c5 = len(tim311) == 0

print(f"Criterion 1 (≥3 win cycles):          {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 (≥3 do_win calls):        {'PASS' if c2 else 'FAIL'}")
print(f"Criterion 3 (zero ASAN errors):       {'PASS' if c3 else 'FAIL'}")
print(f"Criterion 4 (no SIGSEGV/UAF):         {'PASS' if c4 else 'FAIL'}")
print(f"Criterion 5 (Anims pool not full):    {'PASS' if c5 else 'FAIL'}")
print()

if c1 and c2 and c3 and c4 and c5:
    print("=== ALL CRITERIA MET: TIM-313 DONE ===")
elif not c3:
    print("=== ASAN ERRORS REMAIN — investigation needed ===")
    for l in asan_err[:5]:
        print(" ", l.rstrip())
elif crash or asan_uaf:
    print("=== CRASH DETECTED — investigation ongoing ===")
elif not c1:
    print(f"=== PARTIAL: only {len(wins)} win cycles completed ===")
else:
    print("=== NOTE: partial completion ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 300s without crash — ALIVE (TIMEOUT)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
else
    echo "INFO: rc=$RUN_RC — check log for ASAN abort or crash"
fi
