#!/usr/bin/env bash
# TIM-138 measurement: pass 40AP (DLLInterface.cpp graduation -- Edit B re-apply + 4 file-local fixes).
#
# Context (pass-40AO tip, commit beb9f4b): OK 299 / FAIL 2 / Total 301.
# Two residual FAILs: DLLInterface.cpp, WIN32LIB/DDRAW.CPP.
# DDRAW stays out of scope (WineExpert / link-time).
#
# TIM-137 (pass-40AO) landed Edit C (timeGetTime shim in mmsystem.h).
# Edit B (atomic typedef-enum at lines 76-91 of DLLInterface.cpp) was
# reverted per cascade-stop rule because it unmasked 4 post-line-1011
# errors. Those 4 are now visible in pass40AO.log and are bundled here.
#
# This pass (TIM-138):
#   Edit B -- REDALERT/DLLInterface.cpp lines 76-91: atomic typedef-enum
#             reorder so ContextType is defined before use
#   Edit D -- DLLInterface.cpp line 3235: min(size_t, int) -> (size_t) cast
#   Edit E -- DLLInterface.cpp line 3793: ternary FactoryClass*/CCPtr unification
#   Edit F -- linux/win32-stubs/msvc-compat.h: UNREFERENCED_PARAMETER shim
#   Edit G -- DLLInterface.cpp line 8820: reinterpret_cast<uintptr_t> LP64 fix
#
# Realistic ceiling: 300 OK / 1 FAIL (+1) -- DLLInterface.cpp graduates.
# Realistic floor:   299 OK / 2 FAIL (+0) -- cascade-stop triggered.
#
# Cascade-stop rule:
#   DLLInterface.cpp shifts to a fresh first-error outside
#   {77, 1011, 3235, 3793, 6192, 8820}: revert Edits B+D+E+G (keep F),
#   commit Edit F + Edit S, set in_review.
#   Any of the 299 currently-OK TUs regress: revert Edit F as well.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AP.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AP.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AP.attribution.txt"

mkdir -p "$LOG_DIR"

# Serialise pass-40AP invocations end-to-end via flock.
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
    echo "# TIM-138 first compile attempt -- pass 40AP (DLLInterface.cpp graduation: Edit B re-apply + 4 file-local fixes)"
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
