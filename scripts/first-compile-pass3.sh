#!/usr/bin/env bash
# TIM-5 measurement: pass 3.
#
# Pass 1 (no shim) showed 86% of files dying on the very first #include
# because of FS case-sensitivity. Pass 2 (lowercase symlink farm) lifted
# that to 85% still failing — but mostly on missing Win32 headers
# (windows.h, objbase.h, dos.h, ...). Pass 3 layers in:
#
#   1. The case-folding shim, regenerated from scratch by
#      scripts/generate-include-shim.py (relative symlinks, no longer
#      ad-hoc), and
#   2. linux/win32-stubs/ — declarations-only Win32/DOS stubs that catch
#      genuinely missing system headers AFTER the real header search has
#      failed.
#
# We do NOT modify any source under REDALERT/ or WIN32LIB/.
# We do NOT implement DirectDraw or COM — the stubs are empty so the
# parser advances past include resolution and hits real C++ errors that
# TIM-7 will measure.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass3.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass3.summary.txt"

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
: > "$SUMMARY_FILE"

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
)

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0

{
    echo "# TIM-5 first compile attempt -- pass 3 (shim + Win32 stubs)"
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
    {
        echo
        echo "===== [$i/$total] $rel ====="
    } >> "$LOG_FILE"

    if "$CXX" "${CXXFLAGS[@]}" "$src" >>"$LOG_FILE" 2>&1; then
        ok=$((ok + 1))
        echo "OK   $rel" >> "$SUMMARY_FILE"
    else
        fail=$((fail + 1))
        echo "FAIL $rel" >> "$SUMMARY_FILE"
    fi
done

# Tally include-not-found errors so we can verify the TIM-5 acceptance
# criterion ("< 10 include-not-found across all 301 files") at a glance.
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

echo "Log:     $LOG_FILE"
echo "Summary: $SUMMARY_FILE"
echo "ok=$ok fail=$fail total=$total include-misses=$include_misses"
