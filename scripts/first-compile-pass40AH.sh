#!/usr/bin/env bash
# TIM-127 measurement: pass 40AH (cluster-H __asm{} body-stub on MiscAsm.cpp).
#
# Direct successor to TIM-126/pass-40AG. After pass-40AG graduated IRANDOM.CPP
# via Strategy B (per-TU body stub), this pass applies the same fix to the
# next cluster-H TU per the TIM-104 pre-survey: REDALERT/MiscAsm.cpp.
#
# Sites in this commit (atomic, single TU): 17 active __asm{} bodies in
# REDALERT/MiscAsm.cpp (post-stub line numbers in parens):
#   * Distance_Coord                 (line 56)
#   * Desired_Facing16               (line 94)
#   * Desired_Facing256              (line 137)
#   * Desired_Facing8                (line 224)
#   * Cardinal_To_Fixed              (line 465)
#   * Fixed_To_Cardinal              (line 518)
#   * Set_Bit                        (line 558)
#   * Get_Bit                        (line 564)
#   * First_True_Bit                 (line 569)
#   * First_False_Bit                (line 575)
#   * Bound                          (line 580)
#   * Conquer_Build_Fading_Table     (line 831)
#   * Reverse_Long                   (line 841)
#   * Reverse_Short                  (line 847)
#   * Swap_Long                      (line 854)
#   * strtrim                        (line 893)
#   * Fat_Put_Pixel                  (line 935)
#
# Three further __asm{} occurrences remain in source but are inactive --
# one inside a `#if (0)` block (the second Desired_Facing16 stub), and
# two inside `/* ... */` block comments (Coord_Cell sketch, Calculate_CRC).
#
# All 17 active bodies are replaced in-place with
#   `{ /* __asm body removed for syntax-only build (TIM-124) */ }`
# turning the inner braces into a regular C++ compound statement so the
# parse-class first-error (`expected '(' before '{'` at :56:15) drains.
# Missing-return on int/unsigned/long return paths is suppressed by the
# harness `-w` flag, same as the COORD.CPP pilot and IRANDOM.CPP follow-on.
#
# Pre baseline (pass-40AG tip, commit 4de7be2):
#   293 OK / 8 FAIL / 301 Total.
#
# Realistic ceiling: 294 OK / 7 FAIL (+1) -- MiscAsm.cpp graduates.
# Realistic floor:   293 OK / 8 FAIL (+0) -- a fresh first-error of
#   different shape surfaces in MiscAsm.cpp. Per cascade stop-and-handback
#   rule (cluster H), revert the body-stub edit, comment with the new
#   first-error, and hand back; do not chain another fix on this TU.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AH.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AH.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AH.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass invocations end-to-end via flock.
SHIM_LOCK="$LOG_DIR/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

CXXFLAGS=(
    -std=c++17
    -fsyntax-only
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
i=0

{
    echo "# TIM-127 first compile attempt -- pass 40AH (cluster-H __asm{} body-stub on MiscAsm.cpp)"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files (REDALERT/ + WIN32LIB/)"
    echo "# flags: ${CXXFLAGS[*]}"
    echo
} >> "$LOG_FILE"

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    tu_log="$(mktemp)"

    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$LOG_FILE"

    if "$CXX" "${CXXFLAGS[@]}" "$src" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$SUMMARY_FILE"
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$SUMMARY_FILE"
        primary=$(grep -m1 -E ': (fatal error|error):' "$tu_log" || true)
        if [[ -n "$primary" ]]; then
            echo "$rel -> $primary" >> "$ATTRIB_FILE"
        else
            echo "$rel -> (no diagnostic captured)" >> "$ATTRIB_FILE"
        fi
    fi

    cat "$tu_log" >> "$LOG_FILE"
    rm -f "$tu_log"
done

include_misses=$(grep -cE "fatal error: .*: No such file or directory" \
    "$LOG_FILE" || true)

{
    echo
    echo "----- totals -----"
    echo "ok:                  $ok"
    echo "fail:                $fail"
    echo "total:               $total"
    echo "include-not-found:   $include_misses"
} | tee -a "$SUMMARY_FILE" >> "$LOG_FILE"

echo "Log:        $LOG_FILE"
echo "Summary:    $SUMMARY_FILE"
echo "Attribution: $ATTRIB_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
