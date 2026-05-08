#!/usr/bin/env bash
# TIM-150 verification: first-link-pass-150 — KEY/KEYBOARD dedup.
#
# Closes the KEYBOARD.CPP vs KEY.CPP cascade-stop catalogued in
# TIM-144 / pass-146 (18 multidef errors). KEY.CPP is the canonical
# WWKeyboardClass TU and already carries the TIM-145 SDL pump
# (SDL_Process_Input_Events, SDL_Keysym_To_VK, _Kbd global) plus
# the more complete class body (Put_Mouse_Message,
# Available_Buffer_Room, bool Message_Handler).
#
# KEYBOARD.CPP body is wrapped `#if 0 ... #endif` at source level so
# the file still appears in the SOURCES glob and compiles, but emits
# a near-empty .o. This survives a checkout round-trip (unlike a
# rename to .disabled — see TIM-146 note on LZWOTRAW).
#
# Mirrors first-link-pass-146.sh; the only delta is the KEYBOARD
# cascade-stop is gone from the comments and from the 20-multidef
# baseline.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
PASS_DIR="$REPO_ROOT/build/first-link-pass-150"
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
    echo "# TIM-150 first-link-pass-150 compile-to-object stage"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: ${#SOURCES[@]} engine + ${#STUB_SOURCES[@]} stub .cpp files"
    echo "# dedup skips: LZWOTRAW.CPP, DTABLE.CPP, ITABLE.CPP"
    echo "# cascade-stops: TIMERINI.CPP (KEYBOARD.CPP closed by TIM-150)"
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
    echo "(L3 cascade-stops: TIMERINI.CPP still linked)"
    echo "(KEYBOARD.CPP body retired by TIM-150 — file compiles to empty .o)"
    echo "stub objects: ${#STUB_SOURCES[@]}"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

# ---- Link attempt ----
LINK_BIN="$PASS_DIR/redalert.elf"
LINK_FLAGS=( -o "$LINK_BIN" -no-pie -fuse-ld=bfd )

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" >"$LINK_LOG" 2>&1
LINK_RC=$?

# grep -c prints the count and exits 1 on zero matches; swallow that
# exit code so we get a single "0", not the "0\n0" the previous shape
# (`grep -c ... || echo 0`) produced.
multidef_count=$(grep -c "multiple definition" "$LINK_LOG" 2>/dev/null || true)
undef_count=$(grep -c "undefined reference" "$LINK_LOG" 2>/dev/null || true)

# Closed-symbol diff vs pass-146 baseline.
PASS146_LOG="$REPO_ROOT/build/first-link-pass-146/link.log"
if [[ -f "$PASS146_LOG" ]]; then
    pass146_multi=$(grep -c "multiple definition" "$PASS146_LOG" 2>/dev/null || true)
    pass146_undef=$(grep -c "undefined reference" "$PASS146_LOG" 2>/dev/null || true)
    multi_delta=$(( pass146_multi - multidef_count ))
    undef_delta=$(( pass146_undef - undef_count ))
else
    pass146_multi="(missing)"
    pass146_undef="(missing)"
    multi_delta="(n/a)"
    undef_delta="(n/a)"
fi

{
    echo "# TIM-150 first-link-pass-150 link summary"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]} (engine + ${#STUB_SOURCES[@]} stub TUs)"
    echo "# link rc: $LINK_RC"
    echo "#"
    echo "# Baseline (pass-146):"
    echo "#   multidef: $pass146_multi"
    echo "#   undef:    $pass146_undef"
    echo "#"
    echo "# Results:"
    echo "multidef:        $multidef_count"
    echo "undef:           $undef_count"
    echo "multidef delta:  $multi_delta (closed)"
    echo "undef delta:     $undef_delta (closed; negative = new undefs)"
    echo "#"
    echo "# Remaining multidef sites:"
    grep "multiple definition" "$LINK_LOG" | sort -u
} > "$LINK_SUMMARY"

echo "Pass dir:       $PASS_DIR"
echo "Compile status: $COMPILE_STATUS"
echo "Link log:       $LINK_LOG"
echo "Link summary:   $LINK_SUMMARY"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC multidef=$multidef_count undef=$undef_count multi_delta=$multi_delta undef_delta=$undef_delta"
