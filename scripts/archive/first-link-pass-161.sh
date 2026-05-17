#!/usr/bin/env bash
# TIM-149 pass-45F verification: first-link-pass-161 — WinTimerClass Linux timer fix.
#
# Delta vs first-link-pass-157:
#   REDALERT/WIN32LIB/TIMERINI.CPP: WinTimerClass constructor bypasses
#   timeSetEvent (stub returns 0) and sets TimerSystemOn+WindowsTimer
#   directly; Get_System/User_Tick_Count() return
#   timeGetTime()*Frequency/1000 (60Hz monotonic clock) instead of SysTicks.
#
# Expected: link rc=0, multidef=0, undef=0 (same as pass-157).
# Binary should run with TickCount advancing at 60Hz.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-link-pass-161"
OBJ_DIR="$PASS_DIR/obj"
COMPILE_LOG="$PASS_DIR/compile.log"
COMPILE_STATUS="$PASS_DIR/compile-status.txt"
LINK_LOG="$PASS_DIR/link.log"
LINK_SUMMARY="$PASS_DIR/link-summary.txt"

mkdir -p "$PASS_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB" "$OBJ_DIR/STUBS"

: > "$COMPILE_LOG"
: > "$COMPILE_STATUS"
: > "$LINK_LOG"
: > "$LINK_SUMMARY"

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

total=$(( ${#SOURCES[@]} + ${#STUB_SOURCES[@]} ))
ok=0
fail=0
skipped=0
i=0

{
    echo "# TIM-149 first-link-pass-161 compile-to-object stage (pass-45F: WinTimerClass Linux timer)"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: ${#SOURCES[@]} engine + ${#STUB_SOURCES[@]} stub .cpp files"
    echo "# dedup skips: LZWOTRAW.CPP (renamed), DTABLE.CPP, ITABLE.CPP, STUB.CPP"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$COMPILE_LOG"

OBJECTS=()

compile_one() {
    local src="$1"
    local obj="$2"
    local rel="${src#$REPO_ROOT/}"
    local tu_log
    tu_log="$(mktemp)"
    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$COMPILE_LOG"
    if "$CXX" "${CXXFLAGS[@]}" "$src" -o "$obj" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$COMPILE_STATUS"
        OBJECTS+=( "$obj" )
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$COMPILE_STATUS"
    fi
    cat "$tu_log" >> "$COMPILE_LOG"
    rm -f "$tu_log"
}

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    if [[ "$rel" == "REDALERT/DTABLE.CPP" || "$rel" == "REDALERT/ITABLE.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel  # L3 dedup: included by ADPCM.CPP" >> "$COMPILE_STATUS"
        continue
    fi
    if [[ "$rel" == "REDALERT/LZWOTRAW.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel  # L3 dedup: LZWStraw duplicate (canonical = LZWSTRAW.CPP)" >> "$COMPILE_STATUS"
        continue
    fi
    if [[ "$rel" == "REDALERT/STUB.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel  # TIM-159: DOS-era placeholder main(); STARTUP.CPP owns main() on Linux" >> "$COMPILE_STATUS"
        continue
    fi

    base="$(basename "$src" .cpp)"
    base="${base%.CPP}"
    case "$rel" in
        REDALERT/WIN32LIB/*) obj="$OBJ_DIR/REDALERT/WIN32LIB/${base}.o" ;;
        *)                    obj="$OBJ_DIR/REDALERT/${base}.o" ;;
    esac
    compile_one "$src" "$obj"
done

for src in "${STUB_SOURCES[@]}"; do
    i=$((i + 1))
    base="$(basename "$src" .cpp)"
    obj="$OBJ_DIR/STUBS/${base}.o"
    compile_one "$src" "$obj"
done

{
    echo
    echo "----- compile totals -----"
    echo "ok:      $ok"
    echo "fail:    $fail"
    echo "skipped: $skipped"
    echo "total:   $total"
    echo "(skipped: DTABLE.CPP, ITABLE.CPP, LZWOTRAW.CPP, STUB.CPP)"
    echo "stub objects: ${#STUB_SOURCES[@]}"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

LINK_BIN="$PASS_DIR/redalert.elf"
LINK_FLAGS=( -no-pie -fuse-ld=bfd )

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" -o "$LINK_BIN" -lSDL2 >"$LINK_LOG" 2>&1
LINK_RC=$?

multidef_count=$(grep "multiple definition" "$LINK_LOG" 2>/dev/null | wc -l)
undef_count=$(grep "undefined reference" "$LINK_LOG" 2>/dev/null | wc -l)

PASS157_LOG="$REPO_ROOT/build/first-link-pass-157/link.log"
if [[ -f "$PASS157_LOG" ]]; then
    pass157_undef=$(grep "undefined reference" "$PASS157_LOG" 2>/dev/null | wc -l)
    delta=$(( pass157_undef - undef_count ))
else
    pass157_undef="(missing)"
    delta="(n/a)"
fi

{
    echo "# TIM-149 first-link-pass-161 (pass-45F) link summary"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]} (engine + ${#STUB_SOURCES[@]} stub TUs)"
    echo "# link rc: $LINK_RC"
    echo "# delta: TIMERINI.CPP timer bypass (WinTimerClass Linux path)"
    echo "#"
    echo "# Baseline: pass-157 undef=$pass157_undef"
    echo "# Results:"
    echo "multidef:           $multidef_count"
    echo "undef:              $undef_count"
    echo "delta vs pass-157:  $delta"
    echo "#"
    if [[ $undef_count -gt 0 ]]; then
        echo "# Undefined references:"
        grep "undefined reference" "$LINK_LOG" | \
            sed "s/.*undefined reference to \`\([^']*\)'.*/\1/" | sort -u | \
            sed 's/^/#   /'
    fi
    if [[ $multidef_count -gt 0 ]]; then
        echo "# Multiple definitions:"
        grep "multiple definition" "$LINK_LOG" | sort -u | sed 's/^/#   /'
    fi
} > "$LINK_SUMMARY"

echo "Pass dir:       $PASS_DIR"
echo "Compile status: $COMPILE_STATUS"
echo "Link log:       $LINK_LOG"
echo "Link summary:   $LINK_SUMMARY"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC multidef=$multidef_count undef=$undef_count delta=$delta"
