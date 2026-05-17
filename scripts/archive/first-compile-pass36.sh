#!/usr/bin/env bash
# TIM-69 measurement: pass 36.
#
# LP64 audit on the largest remaining single-root-cause cluster
# surfaced by pass-35: "cast from <ptr>* to unsigned int loses
# precision" in 4 TUs.
#
# TUs in scope:
#   1) REDALERT/2KEYFRAM.CPP -- 17 sites (BigShape/TheaterShape buffer
#                               offset rebasing + alignment masks).
#                               Class (a)/(b) opaque-handle marshaling.
#                               Fix: (unsigned) -> (uintptr_t); for
#                               alignment masks, also 0xfffffffc ->
#                               ~(uintptr_t)3 so the upper 32 bits of
#                               LP64 pointers are not nuked.
#   2) REDALERT/LCW.CPP      -- 1 site (alignment fingerprint via low
#                               2-bit mask). Class (b). (unsigned) ->
#                               (uintptr_t).
#   3) REDALERT/LCWUNCMP.CPP -- 1 site, identical to LCW.CPP.
#   4) REDALERT/MAP.CPP      -- 4 sites in MapClass::Validate() (the
#                               obj/obj->Next 0xff000000 sanity check).
#                               Class (b). (unsigned int) ->
#                               (uintptr_t). Note: the 0xff000000 mask
#                               was an LP32 "top byte set => corrupt
#                               user-space pointer" sanity check; on
#                               LP64 it now examines bits 24-31 of a
#                               64-bit address, which is weaker but
#                               matches the pre-port behaviour. Flagged
#                               in the TIM-69 thread as a pre-existing
#                               LP64 semantic limitation, not a new bug.
#
# Pre baseline (post TIM-68, commit 3f97c4b):
#   pass 35 (TIM-68) : 260 OK / 41 Fail / 301 Total.
#
# Target ceiling: 264 OK / 37 Fail / 301 Total (+4 if all four clear
# cleanly).
#
# Same harness as passes 7-35 -- same flags, same shim regen, same
# stubs. Difference relative to pass 35: per-site type widening in
# REDALERT/{2KEYFRAM,LCW,LCWUNCMP,MAP}.CPP. No flag changes, no shim
# restructuring, no header changes.
#
# Pass progression (OK count) -- recent tail:
#   pass 30 (TIM-56)                      : 249
#   pass 31 (TIM-59 + TIM-61)             : 253
#   pass 31-rebaselined (post TIM-62/65)  : 254
#   pass 32 (TIM-63)                      : 254
#   pass 33 (TIM-66)                      : 254
#   pass 34 (TIM-67)                      : 259
#   pass 35 (TIM-68)                      : 260
#   pass 36 (TIM-69, this run)            : ???  (target ceiling 264)
#
# Measurement script -- the actual fixes live in the source files
# named above.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass36.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass36.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass36.attribution.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"

CXX="${CXX:-g++}"

# Regenerate the case-folding shim every run so this script is
# self-contained and reproducible.
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
    # Order matters: case-folding shim first so re-cased headers win
    # over the on-disk uppercase originals; then the real source dirs
    # (catches anything we missed); then the stubs LAST so they only
    # fire for genuinely absent headers (windows.h, objbase.h, ...).
    -I "$SHIM_DIR/redalert"
    -I "$SHIM_DIR/win32lib"
    -I "$SRC_DIR"
    -I "$SRC_DIR/WIN32LIB"
    -I "$STUB_DIR"
    # Force-include the MSVC-extension shim (calling-convention macros,
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.). See pass 35
    # script header for the cross-cutting MSVC-isms covered here.
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
    echo "# TIM-69 first compile attempt -- pass 36 (LP64 audit: 4 TUs)"
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
