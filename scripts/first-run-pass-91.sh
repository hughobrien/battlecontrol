#!/usr/bin/env bash
# TIM-310 pass-91: ASAN-enabled run to identify cycle-3 crash root cause
#
# New in pass-91:
#   READLINE.CPP - strtrimcpp: memmove instead of strcpy (fixes ASAN strcpy-overlap at startup)
#   ANIM.CPP     - AnimClass::operator new: [TIM-311] probe logs pool state on allocation failure
#
# Retained from pass-90:
#   SCENARIO.CPP - g_tim310_restart_frame + Clear_Scenario/Do_Win/Read_Scenario probes [TIM-310]
#   CONQUER.CPP  - per-cycle win trigger: PlayerWins=true at Frame >= g_tim310_restart_frame+200
#   TECHNO.CPP   - Fire_At, Take_Damage probes                                           [TIM-301]
#   FOOT.CPP     - Death_Announcement probe                                              [TIM-301]
#   HOUSE.CPP    - IsBaseBuilding=true synthetic trigger                                 [TIM-298]
#   SCENARIO.CPP - reinf_tank injection (5 Mammoth tanks)                               [TIM-308]
#
# Why pass-90 ASAN failed: strcpy-param-overlap in strtrimcpp (READLINE.CPP:41) crashed
# Init_Game before the game even reached the game loop. Fixed here.
#
# Known finding from pass-90 non-ASAN run:
#   - Cycles 1+2 complete (win at frame 200 and 400)
#   - Cycle 3 crashes at relative frame 80 (V19 explosion) — same frame where cycles 1+2 work
#   - Crash: SIGSEGV in AbstractClass::AbstractClass() → AnimClass ctor → BulletClass::Bullet_Explodes
#   - Pattern suggests use-after-free or memory corruption accumulating across cycles
#   - ASAN expected to identify exact bug
#
# Acceptance criteria:
#   1. Build ok=300+ rc=0 (ASAN build)
#   2. ASAN gets past Init_Game (no strcpy-overlap at startup)
#   3. Either: [PLAYER-WINS] fires with ASAN report identifying crash type + site
#      Or:     3 win cycles complete cleanly (crash not ASAN-detectable with default flags)
#
# Run from repo root:
#   bash scripts/first-run-pass-91.sh

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-run-pass-91"
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
#   new_delete_type_mismatch=0 — suppress pre-existing INIEntry 88-byte/16-byte mismatch
#   detect_leaks=0 — not relevant here, avoids spurious exits
#   abort_on_error=0 — write full report before exiting
#   strcpy-param-overlap is NOT suppressed — we fixed it in READLINE.CPP
ASAN_OPTIONS="new_delete_type_mismatch=0:detect_leaks=0:abort_on_error=0:log_path=stderr"

(cd "$RUN_DIR" && DISPLAY=:99 SDL_AUDIODRIVER=dummy RA_AUTOSTART=1 \
    ASAN_OPTIONS="$ASAN_OPTIONS" \
    timeout 600 "$LINK_BIN") > "$LOG" 2>&1
RUN_RC=$?
kill -9 "$XVFB_PID" 2>/dev/null || true

echo "Run rc=$RUN_RC (0=clean exit, 124=timeout=alive, 134=abort, 139=SIGSEGV, 1=ASAN)"
echo ""

echo "--- TIM-310 cycle probes ---"
grep -a "\[TIM-310\]" "$LOG" | head -30 || echo "(none)"
echo ""

echo "--- TIM-311 AnimClass pool probe ---"
grep -a "\[TIM-311\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- PLAYER-WINS / PLAYER-LOSES ---"
grep -a "\[PLAYER-WINS\]\|\[PLAYER-LOSES\]" "$LOG" | head -10 || echo "(none)"
echo ""

echo "--- ASAN error summary ---"
grep -a "ERROR: AddressSanitizer\|SUMMARY: AddressSanitizer" "$LOG" | head -20 || echo "(none)"
echo ""

echo "--- ASAN stack trace (first 50 lines after ERROR) ---"
awk '/ERROR: AddressSanitizer/{found=1} found{print; if(++n>=50) exit}' "$LOG" || echo "(none)"
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

print("=== TIM-310 pass-91 analysis ===\n")

tim310 = [l for l in lines if '[TIM-310]' in l]
tim311 = [l for l in lines if '[TIM-311]' in l]
wins   = [l for l in lines if '[PLAYER-WINS]' in l]
loses  = [l for l in lines if '[PLAYER-LOSES]' in l]
dowin  = [l for l in lines if '[TIM-308] do_win' in l or '[TIM-310] do_win' in l]
asan_err = [l for l in lines if 'ERROR: AddressSanitizer' in l or 'AddressSanitizer: SEGV' in l]

print(f"[TIM-310] probes fired: {len(tim310)}")
for l in tim310[:20]:
    print(f"  {l.rstrip()}")
print()

print(f"[TIM-311] pool probes: {len(tim311)}")
for l in tim311:
    print(f"  {l.rstrip()}")
print()

print(f"[PLAYER-WINS] events: {len(wins)}")
for l in wins:
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
c5 = len(tim311) == 0  # no pool failures

print(f"Criterion 1 (≥1 win cycle):         {'PASS' if c1 else 'FAIL'}")
print(f"Criterion 2 (≥2 do_win calls):       {'PASS' if c2 else 'FAIL'}")
print(f"Criterion 3 (≥3 do_win calls):       {'PASS' if c3 else 'FAIL'}")
print(f"Criterion 4 (no crash/ASAN):          {'PASS — no crash found' if c4 else 'FAIL — crash present'}")
print(f"Criterion 5 (Anims pool not full):    {'PASS' if c5 else 'FAIL — pool exhaustion seen'}")
print()

if asan:
    print("=== ASAN crash detected — see log for full stack trace ===")
elif crash:
    print("=== SIGSEGV without ASAN trace — check signal handler output ===")
elif c3:
    print("=== 3 win cycles completed without crash ===")
else:
    print("=== NOTE: fewer than 3 win cycles completed ===")
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
