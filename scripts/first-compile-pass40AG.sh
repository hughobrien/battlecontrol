#!/usr/bin/env bash
# TIM-126 measurement: pass 40AG (cluster-H __asm{} body-stub on IRANDOM.CPP).
#
# Direct successor to TIM-124/pass-40AF. After pass-40AF graduated COORD.CPP
# via Strategy B (per-TU body stub), this pass applies the same fix to the
# next smallest cluster-H TU per the TIM-104 pre-survey: WIN32LIB/IRANDOM.CPP.
#
# Sites in this commit (atomic, single TU):
#   * Random()           lines 72-87  -- one __asm{} body, label-free
#   * Get_Random_Mask()  lines 91-103 -- one __asm{} body, contains
#                                        `invalid:` label inside the block
#
# Both bodies are replaced in-place with
#   `{ /* __asm body removed for syntax-only build (TIM-124) */ }`
# turning the inner braces into a regular C++ compound statement so the
# parse-class first-error (`expected '(' before '{'` at :72:15) drains.
# Missing-return on int/unsigned char return paths is suppressed by the
# harness `-w` flag, same as the COORD.CPP pilot.
#
# Pre baseline (pass-40AF tip, commit 82c09c3):
#   292 OK / 9 FAIL / 301 Total.
#
# Realistic ceiling: 293 OK / 8 FAIL (+1) -- IRANDOM.CPP graduates.
# Realistic floor:   292 OK / 9 FAIL (+0) -- a fresh first-error of
#   different shape surfaces in IRANDOM.CPP. Per cascade stop-and-handback
#   rule (cluster H), revert the body-stub edit, comment with the new
#   first-error, and hand back; do not chain another fix on this TU.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AG.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AG.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AG.attribution.txt"

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
    echo "# TIM-126 first compile attempt -- pass 40AG (cluster-H __asm{} body-stub on IRANDOM.CPP)"
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
