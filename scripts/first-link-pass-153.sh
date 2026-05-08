#!/usr/bin/env bash
# TIM-153 verification: first-link-pass-153 — umbrella-A NOP stubs.
#
# Closes 11 umbrella-A undef sites (INTERNET.CPP / STATS.CPP globals + fns
# whose bodies are elided because those TUs open with `#ifdef WIN32` before
# any includes, so WIN32 is undefined when the guard fires).
#   new internet-stub.cpp:
#     bool GameStatisticsPacketSent, ConnectionLost, SpawnedFromWChat
#     bool PlanetWestwoodIsHost
#     long PlanetWestwoodPortNumber
#     char PlanetWestwoodIPAddress[40]
#     void *PacketLater
#     void Check_From_WChat(char*)
#     void Send_Statistics_Packet()
#     void Register_Game_Start_Time(), Register_Game_End_Time()
#
# Mirrors first-link-pass-146.sh shape exactly.
# Remaining undefs after this pass are:
#   L5  — SDL2 family (TIM-141 track)
#   Umbrella A residue — CCDDE.CPP, TCPIP.CPP (require struct infrastructure)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-link-pass-153"
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
    echo "# TIM-153 first-link-pass-153 compile-to-object stage"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: ${#SOURCES[@]} engine + ${#STUB_SOURCES[@]} stub .cpp files"
    echo "# dedup skips: LZWOTRAW.CPP (renamed), DTABLE.CPP, ITABLE.CPP"
    echo "# cascade-stops: KEYBOARD.CPP, TIMERINI.CPP"
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
    echo "(skipped: DTABLE.CPP, ITABLE.CPP, LZWOTRAW.CPP)"
    echo "stub objects: ${#STUB_SOURCES[@]}"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

# ---- Link attempt ----
LINK_BIN="$PASS_DIR/redalert.elf"
LINK_FLAGS=( -o "$LINK_BIN" -no-pie -fuse-ld=bfd )

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" >"$LINK_LOG" 2>&1
LINK_RC=$?

multidef_count=$(grep -c "multiple definition" "$LINK_LOG" 2>/dev/null || echo 0)
undef_count=$(grep -c "undefined reference" "$LINK_LOG" 2>/dev/null || echo 0)

# Closed-symbol diff vs pass-146 baseline.
PASS146_LOG="$REPO_ROOT/build/first-link-pass-146/link.log"
if [[ -f "$PASS146_LOG" ]]; then
    pass146_undef=$(grep -c "undefined reference" "$PASS146_LOG" 2>/dev/null || echo 0)
    delta=$(( pass146_undef - undef_count ))
else
    pass146_undef="(missing)"
    delta="(n/a)"
fi

{
    echo "# TIM-153 first-link-pass-153 link summary"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]} (engine + ${#STUB_SOURCES[@]} stub TUs)"
    echo "# link rc: $LINK_RC"
    echo "#"
    echo "# Baselines:"
    echo "#   pass-43L (pre-CCDDE/STATS): 184 undef"
    echo "#   pass-146 (post-L4 C-stubs):  $pass146_undef undef"
    echo "#   pass-151 (post-Stop_Exec/MPath/NetDlg stubs): 155 undef"
    echo "#"
    echo "# Results:"
    echo "multidef:        $multidef_count"
    echo "undef:           $undef_count"
    echo "delta vs pass-146: $delta (closed)"
    echo "delta vs pass-151: $(( 155 - undef_count )) (closed by TIM-153)"
    echo "#"
    grep "multiple definition" "$LINK_LOG" | sort -u
} > "$LINK_SUMMARY"

echo "Pass dir:       $PASS_DIR"
echo "Compile status: $COMPILE_STATUS"
echo "Link log:       $LINK_LOG"
echo "Link summary:   $LINK_SUMMARY"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC multidef=$multidef_count undef=$undef_count delta=$delta"
