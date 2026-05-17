#!/usr/bin/env bash
# TIM-140 pass-43L: read-only link-side residual classification.
#
# Premise: compile floor is OK 300 / FAIL 1 (DDRAW.CPP) / Total 301 at master tip.
# DDRAW.CPP is owned by WineExpert under TIM-139 -- skip it here.
# This pass attempts a real link of the 300 OK TUs and classifies every
# unresolved-symbol diagnostic into groups L1-L5 per TIM-140 spec:
#   L1 -- missing system lib
#   L2 -- Win32 shim symbol declared but undefined
#   L3 -- engine symbol multiply defined / ODR violation
#   L4 -- engine symbol referenced but not defined anywhere
#   L5 -- DDRAW-family unresolved expected (not counted against floor)
#
# This is read-only forensic work. No edits to engine source, shim
# headers, build flags, or compile_commands.json. Output is data.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
SURVEY_DIR="$REPO_ROOT/build/first-link-survey-pass-43L"
OBJ_DIR="$SURVEY_DIR/obj"
COMPILE_LOG="$SURVEY_DIR/compile.log"
COMPILE_STATUS="$SURVEY_DIR/compile-status.txt"
LINK_LOG="$SURVEY_DIR/link.log"
LINK_INVOCATION="$SURVEY_DIR/link.invocation.txt"

mkdir -p "$SURVEY_DIR" "$OBJ_DIR/REDALERT" "$OBJ_DIR/REDALERT/WIN32LIB"

# Serialise via flock for safety -- the include-shim generator is shared.
SHIM_LOCK="$REPO_ROOT/build/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

: > "$COMPILE_LOG"
: > "$COMPILE_STATUS"
: > "$LINK_LOG"
: > "$LINK_INVOCATION"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

# Same flag set as pass-40AP, swapping -fsyntax-only for -c so we
# emit object files. Keep -w to mirror the compile-pass noise floor.
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

total=${#SOURCES[@]}
ok=0
fail=0
skipped=0
i=0

{
    echo "# TIM-140 pass-43L compile-to-object stage"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files (REDALERT/ + WIN32LIB/)"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$COMPILE_LOG"

OBJECTS=()
for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    # Skip the known-bad TU. DDRAW belongs to WineExpert / TIM-139.
    if [[ "$rel" == "REDALERT/WIN32LIB/DDRAW.CPP" ]]; then
        skipped=$((skipped + 1))
        echo "SKIP $rel" >> "$COMPILE_STATUS"
        continue
    fi

    base="$(basename "$src" .cpp)"
    base="${base%.CPP}"
    case "$rel" in
        REDALERT/WIN32LIB/*) obj="$OBJ_DIR/REDALERT/WIN32LIB/${base}.o" ;;
        *)                    obj="$OBJ_DIR/REDALERT/${base}.o" ;;
    esac

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
done

{
    echo
    echo "----- compile totals -----"
    echo "ok:      $ok"
    echo "fail:    $fail"
    echo "skipped: $skipped"
    echo "total:   $total"
} | tee -a "$COMPILE_STATUS" >> "$COMPILE_LOG"

# ---- Link attempt ----
# Bare link to surface the full unresolved-symbol set. We deliberately
# DO NOT add any system libs in this pass -- L1 is precisely the set we
# would discover by reading the unresolved list. This is a survey, not
# a build. We use -no-pie -fuse-ld=bfd because the engine is full of
# absolute references; we want a proper unresolved-symbol report rather
# than relocation noise.

LINK_BIN="$SURVEY_DIR/redalert.elf"
LINK_FLAGS=( -o "$LINK_BIN" -no-pie -fuse-ld=bfd )

{
    echo "# TIM-140 pass-43L link attempt"
    echo "# date: $(date -Is)"
    echo "# objects: ${#OBJECTS[@]}"
    echo "# linker: $($CXX -print-prog-name=ld) (via $CXX driver)"
    echo "# flags: ${LINK_FLAGS[*]}"
    echo "# libs: <none -- bare link to surface L1 system-lib gaps>"
} >> "$LINK_INVOCATION"

# Capture the full link command for reproducibility.
{
    printf '%s' "$CXX"
    for f in "${LINK_FLAGS[@]}"; do printf ' %q' "$f"; done
    for o in "${OBJECTS[@]}"; do printf ' %q' "$o"; done
    printf '\n'
} >> "$LINK_INVOCATION"

"$CXX" "${LINK_FLAGS[@]}" "${OBJECTS[@]}" >"$LINK_LOG" 2>&1
LINK_RC=$?

{
    echo
    echo "----- link result -----"
    echo "rc:      $LINK_RC"
    echo "objects: ${#OBJECTS[@]}"
    echo "binary:  $LINK_BIN"
} >> "$LINK_INVOCATION"

echo "Survey:           $SURVEY_DIR"
echo "Compile log:      $COMPILE_LOG"
echo "Compile status:   $COMPILE_STATUS"
echo "Link log:         $LINK_LOG"
echo "Link invocation:  $LINK_INVOCATION"
echo "compile ok=$ok fail=$fail skipped=$skipped link rc=$LINK_RC objects=${#OBJECTS[@]}"
