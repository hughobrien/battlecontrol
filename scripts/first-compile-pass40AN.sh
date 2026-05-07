#!/usr/bin/env bash
# TIM-135 measurement: pass 40AN (DLLInterface bundle v2 --
# atomic typedef-enum + OLE Automation stubs in msvc-compat.h +
# ContextType typedef-enum fix in DLLInterface.cpp).
# Cascade-stop diagnosis from TIM-134 (pass-40AM) informed this v2 spec.
#
# Pre baseline (pass-40AL tip, commit 2f93370):
#   298 OK / 3 FAIL / 301 Total.
#
# Realistic ceiling: 300 OK / 1 FAIL (+2) -- both DLLInterface.cpp and
#   DLLInterfaceEditor.cpp graduate.
# Realistic floor:   299 OK / 2 FAIL (+1) -- only one TU graduates.
#   On either floor outcome, cascade-stop rule applies: if a TU shifts
#   to a fresh first-error, revert that TU's edit and hand back to
#   FoundingEngineer; do not chain.
#
# Histogram diff targets:
#   pre  -> DLLInterfaceEditor.cpp:28:..: expected constructor ...
#           DLLInterface.cpp:77:..: use of enum 'ContextType' ...
#   post -> both gone from FAIL list (ceiling), or
#           one or both: <new-line>: <new-shape> (floor / cascade stop).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AN.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AN.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AN.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass-40AN invocations end-to-end via flock.
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
    echo "# TIM-135 first compile attempt -- pass 40AN (__declspec stub + OLE Automation + ContextType typedef-enum)"
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
