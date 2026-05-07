#!/usr/bin/env bash
# TIM-131 measurement: pass 40AJ (SPRITE.CPP BITMAPCLASS guard fix).
#
# Root cause: SPRITE.CPP:28-49 defines class BitmapClass / TPoint2D under
# #ifndef WIN32.  Our build does NOT define WIN32 (only _WIN32, only inside
# gbuffer.h itself), so the block is entered.  But the file does not set the
# BITMAPCLASS preprocessor macro, so when #include <wwlib32.h> (line 57)
# transits gbuffer.h, its own #ifndef BITMAPCLASS guard (lines 146-147) is
# still true and gbuffer.h:148 re-emits class BitmapClass → redefinition.
#
# Fix: wrap the existing #ifndef WIN32 ... #endif (lines 28-49) with an inner
# #ifndef BITMAPCLASS / #define BITMAPCLASS / #endif so that the macro is set
# before wwlib32.h is included.  Mirrors REDALERT/FUNCTION.H:154-155.
# Two lines added, zero lines removed.
#
# Pre baseline (pass-40AI tip, commit 118b7a2):
#   295 OK / 6 FAIL / 301 total.
#
# Realistic ceiling: 296 OK / 5 FAIL (+1) -- SPRITE.CPP graduates.
# Realistic floor:   295 OK / 6 FAIL (+0) -- fresh in-file cascade in
#   SPRITE.CPP (different first-error line/shape).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AJ.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AJ.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AJ.attribution.txt"

mkdir -p "$LOG_DIR"

# Serialise pass-40AJ invocations end-to-end via flock.
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
    echo "# TIM-131 first compile attempt -- pass 40AJ (SPRITE.CPP BITMAPCLASS guard fix)"
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
