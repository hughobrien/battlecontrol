#!/usr/bin/env bash
# TIM-310 pass-90: investigate post-win SIGSEGV in scenario restart path
#
# New in pass-90:
#   SCENARIO.CPP - g_tim310_restart_frame global; set to Frame after each Read_Scenario success
#   SCENARIO.CPP - Clear_Scenario(): [TIM-310] clear_scenario #N probe + disarm win trigger
#   SCENARIO.CPP - Do_Win(): [TIM-310] do_win #N probe
#   SCENARIO.CPP - Read_Scenario(): [TIM-310] read_scenario_ok cycle=N probe
#   CONQUER.CPP  - per-cycle win trigger: PlayerWins=true at Frame == g_tim310_restart_frame+5
#                  (replaces broken Frame==100 that didn't reset per cycle; bypasses BorrowedTime)
#
# Why pass-89 failed to win: Frame doesn't reset on scenario restart, so Frame==100 only fired
# in cycle 1. Also Flag_To_Win has ~27-frame BorrowedTime before PlayerWins fires.
#
# Retained from pass-85/86/88/89:
#   TECHNO.CPP   - Fire_At, Take_Damage, Take_Damage RESULT_DESTROYED probes  [TIM-301]
#   FOOT.CPP     - Death_Announcement probe                                    [TIM-301]
#   HOUSE.CPP    - IsBaseBuilding=true synthetic trigger                        [TIM-298]
#   HOUSE.CPP / FACTORY.CPP - factory pipeline probes                          [TIM-298]
#   SCENARIO.CPP - reinf_tank injection (5 Mammoth tanks)                      [TIM-308]
#
# Acceptance criteria:
#   1. Build ok=300+ rc=0 (ASAN build)
#   2. [PLAYER-WINS] fires in cycle 1
#   3. [TIM-310] do_win #2 and do_win #3 logged (3 win cycles)
#   4. Either: clean exit after 3+ cycles, OR crash identified by ASAN with stack trace
#
# Run from repo root:
#   bash scripts/first-run-pass-90.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-90"
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
"$CXX" -no-pie -fuse-ld=bfd -g -rdynamic -fno-omit-frame-pointer -fsanitize=address \
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
echo "=== Smoke test from $RUN_DIR (600s timeout, RA_AUTOSTART=1, ASAN) ==="
pkill -f "Xvfb :99" 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -ac &
XVFB_PID=$!
sleep 1

LOG="$PASS_DIR/run.log"

# ASAN options:
#   new_delete_type_mismatch=0 — suppress pre-existing GenericList::Delete() false positive in
#       INIClass startup code (INI.CPP:133,229); 88-byte INIEntry allocated, deleted as 16-byte
#       GenericList pointer. Pre-existing, not in restart path. Suppressed so game reaches loop.
#   detect_leaks=0 — leak detection is slow and not relevant for this pass
#   abort_on_error=0 — write ASAN report before exit
ASAN_OPTIONS="new_delete_type_mismatch=0:detect_leaks=0:abort_on_error=0:log_path=stderr"

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    ASAN_OPTIONS="$ASAN_OPTIONS" \
    timeout 600 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV, 1=ASAN)"
echo ""

echo "--- TIM-310 cycle probes ---"
grep -a "\[TIM-310\]" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- PLAYER-WINS / PLAYER-LOSES ---"
grep -a "\[PLAYER-WINS\]\|\[PLAYER-LOSES\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- TIM-308 do_win ---"
grep -a "\[TIM-308\] do_win" "$LOG" | head -5 || echo "(none)"
echo ""

echo "--- ASAN error summary ---"
grep -a "AddressSanitizer\|ERROR: AddressSanitizer\|SUMMARY: AddressSanitizer" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- ASAN stack trace (first 40 lines after ERROR) ---"
awk '/ERROR: AddressSanitizer/{found=1} found{print; if(++n>=40) exit}' "$LOG" || echo "(none)"
echo ""

echo "--- Crash / signal ---"
grep -a -E "CRASH signal|SIGSEGV|Segmentation|Illegal|signal 11|signal 6" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- Last 10 lines ---"
tail -10 "$LOG"
echo ""

python3 - "$LOG" <<'PYEOF'
import sys, re

log_path = sys.argv[1]
lines = open(log_path, errors='replace').readlines()

print("=== TIM-310 pass-90 restart-path analysis ===\n")

tim310 = [l for l in lines if '[TIM-310]' in l]
wins   = [l for l in lines if '[PLAYER-WINS]' in l]
loses  = [l for l in lines if '[PLAYER-LOSES]' in l]
dowin  = [l for l in lines if '[TIM-308] do_win' in l or '[TIM-310] do_win' in l]
asan_err = [l for l in lines if 'ERROR: AddressSanitizer' in l or 'AddressSanitizer: SEGV' in l]

print(f"[TIM-310] probes fired: {len(tim310)}")
for l in tim310:
    print(f"  {l.rstrip()}")
print()

print(f"[PLAYER-WINS] events: {len(wins)}")
for l in wins:
    print(f"  {l.rstrip()}")
print(f"[PLAYER-LOSES] events: {len(loses)}")
for l in loses[:3]:
    print(f"  {l.rstrip()}")
print()

print(f"Do_Win calls: {len(dowin)}")
for l in dowin:
    print(f"  {l.rstrip()}")
print()

crash = any(re.search(r'SIGSEGV|Segmentation|CRASH signal|signal 11', l) for l in lines)
asan  = len(asan_err) > 0

print(f"ASAN error detected: {asan}")
if asan:
    for l in asan_err[:3]:
        print(f"  {l.rstrip()}")
print(f"SIGSEGV/crash detected: {crash}")
print()

# Criteria
c1 = len(wins) >= 1
c2 = len(dowin) >= 2
c3 = len(dowin) >= 3
c4 = not crash and not asan

print(f"Criterion 1 (≥1 win cycle):    {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 (≥2 do_win calls): {'PASS' if c2 else 'FAIL'}")
print(f"Criterion 3 (≥3 do_win calls): {'PASS' if c3 else 'FAIL'}")
print(f"Criterion 4 (no crash/ASAN):   {'PASS — no crash found' if c4 else 'FAIL — crash present'}")
print()

if asan:
    print("=== ASAN crash detected — see log for full stack trace ===")
elif crash:
    print("=== SIGSEGV without ASAN trace — may need GDB follow-up ===")
elif c3:
    print("=== 3 win cycles completed without crash — crash may not be reproducible with ASAN ===")
else:
    print("=== NOTE: Fewer than 3 win cycles — win trigger may need adjustment ===")
PYEOF

if [[ $RUN_RC -eq 124 ]]; then
    echo "Game ran 600s without crash — ALIVE (TIMEOUT)"
elif [[ $RUN_RC -eq 0 ]]; then
    echo "Game exited cleanly (SDL_QUIT)"
elif [[ $RUN_RC -eq 139 ]]; then
    echo "FAIL: SIGSEGV — check log"
elif [[ $RUN_RC -eq 134 ]]; then
    echo "FAIL: abort/assert — check log (may be ASAN abort)"
elif [[ $RUN_RC -eq 1 ]]; then
    echo "FAIL: rc=1 — likely ASAN error, check log"
else
    echo "INFO: rc=$RUN_RC — check log"
fi
