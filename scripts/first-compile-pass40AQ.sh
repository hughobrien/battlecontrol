#!/usr/bin/env bash
# TIM-139 measurement: pass 40AQ (WIN32LIB/DDRAW.CPP graduation -- IDirectDrawPalette stub).
#
# Context (pass-40AP tip, commit 5b27958): OK 300 / FAIL 1 / Total 301.
# Sole residual FAIL: REDALERT/WIN32LIB/DDRAW.CPP, single error at
# DDRAW.CPP:752 -- PalettePtr->SetEntries(...) hits incomplete type
# IDirectDrawPalette (still a forward decl in REDALERT/WIN32LIB/DDRAW.H).
#
# This pass (TIM-139):
#   Edit A -- REDALERT/WIN32LIB/DDRAW.H: extend the TIM-15 _NO_COM stub
#             block with `struct IDirectDrawPalette { template SetEntries }`,
#             same variadic-template throwaway pattern as IDirectDraw{,Surface}.
#             Replaced when the SDL2 / Wine-path runtime port of DDRAW.CPP
#             lands (separate follow-up issue).
#
# Realistic ceiling: 301 OK / 0 FAIL (+1) -- DDRAW.CPP graduates,
#                    closing the 6-FAIL TIM-130 set.
# Realistic floor:   300 OK / 1 FAIL (+0) -- single-site shim does not bite.
#
# Cascade-stop rule:
#   DDRAW.CPP shifts to a fresh first-error outside line 752: revert
#   Edit A and hand back. (Live method-call audit shows SetEntries is
#   the only remaining unstubbed call on the live code path; lines
#   456-534 + 502-529 are #if(0) dead code.)
#   Any of the 300 currently-OK TUs regress: revert Edit A.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AQ.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AQ.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AQ.attribution.txt"

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
    echo "# TIM-139 first compile attempt -- pass 40AQ (WIN32LIB/DDRAW.CPP graduation: IDirectDrawPalette stub)"
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
