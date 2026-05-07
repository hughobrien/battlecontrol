#!/usr/bin/env bash
# TIM-132 measurement: pass 40AK (SPRITE.CPP BITMAPCLASS guard + drop WWFILE_Hx pre-define).
#
# Root cause (two independent layers):
#
# Layer 1 — gbuffer.h:148 redefinition of class BitmapClass
#   SPRITE.CPP:28-49 defines class BitmapClass / TPoint2D under #ifndef WIN32.
#   Our build does NOT define WIN32, so the block is entered.  The file did not
#   set the BITMAPCLASS macro, so when #include <wwlib32.h> transits gbuffer.h,
#   its own #ifndef BITMAPCLASS guard (lines 146-147) is still true and
#   gbuffer.h:148 re-emits class BitmapClass → redefinition.
#
# Layer 2 — xpipe.h:75 FileClass undeclared
#   SPRITE.CPP:56 had #define WWFILE_Hx, pre-suppressing the body of
#   REDALERT/WWFILE.H (guard: WWFILE_Hx, RA convention).  Our shim build
#   transits xpipe.h via wwlib32.h → mouse.h → scroll.h → help.h → tab.h →
#   sidebar.h → function.h:227 → xpipe.h.  xpipe.h:39 includes "wwfile.h"
#   but the body was suppressed by the pre-define, so class FileClass was never
#   declared and xpipe.h:75 FilePipe(FileClass * file) failed to parse.
#
# Sibling proof (single-site classification):
#   REDALERT/ROTBMP.CPP:39-40 uses the same #define FILE_H / #define WWMEM_H
#   pattern but does NOT pre-define WWFILE_Hx → ROTBMP.CPP is OK in pass-40AJ.
#   The WWFILE_Hx pre-define was the extra footgun unique to SPRITE.CPP.
#   The other three pre-defines (FILE_H, RAWFILE_H, WWMEM_H — _H-suffixed,
#   win32lib guards) are load-bearing and left intact.
#
# Fix (both in REDALERT/SPRITE.CPP):
#   Edit 1: wrap existing #ifndef WIN32 block (lines 28-49) with
#     #ifndef BITMAPCLASS / #define BITMAPCLASS / matching #endif.
#     Mirrors REDALERT/FUNCTION.H:154-155.  Two lines added, zero removed.
#   Edit 2: remove the single line '#define WWFILE_Hx' (original line 56).
#     One line removed, zero added.
#
# Pre baseline (pass-40AJ tip, commit c8353f5):
#   295 OK / 6 FAIL / 301 total.
#
# Realistic ceiling: 296 OK / 5 FAIL (+1) -- SPRITE.CPP graduates clean.
# Realistic floor:   295 OK / 6 FAIL (+0) -- fresh in-file cascade in
#   SPRITE.CPP (different first-error line/shape).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AK.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AK.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AK.attribution.txt"

mkdir -p "$LOG_DIR"

# Serialise pass-40AK invocations end-to-end via flock.
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
    echo "# TIM-132 first compile attempt -- pass 40AK (SPRITE.CPP BITMAPCLASS guard + drop WWFILE_Hx pre-define)"
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
