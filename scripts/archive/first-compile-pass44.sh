#!/usr/bin/env bash
# TIM-83 measurement: pass 44.
#
# Win32 shim cluster drain (LPCTSTR + SYSTEMTIME + HBITMAP) targeted
# at linux/win32-stubs/windows.h.
#
# OUTCOME: SUPERSEDED by TIM-84/TIM-85's pass-40F bundle. The same
# cluster of symbols was being drained in parallel by TIM-85 in a
# wider-scope bundle (LPCTSTR + SYSTEMTIME + GetSystemTime +
# GetVolumeInformation + an `inline HBITMAP hBitmap = nullptr;`
# workaround for the BMP8.CPP engine-source typo). My initial TIM-83
# edit attempt (typedef LPCTSTR + struct SYSTEMTIME) collided with
# TIM-85's identical-shape SYSTEMTIME definition, producing a
# `redefinition of struct _SYSTEMTIME` cascade across 122 TUs. The
# TIM-83 edits were therefore reverted; TIM-85's broader bundle was
# left intact in the worktree pending its own commit.
#
# Pre-survey on master b8f7873 (post TIM-82) confirmed the three
# named first-errors:
#   REDALERT/WINSTUB.CPP:499 -> LPCTSTR not declared
#   REDALERT/MENUS.CPP:842   -> SYSTEMTIME not declared
#   REDALERT/BMP8.CPP:23     -> hBitmap not declared (engine
#                               member-name typo: BMP8.H declares
#                               hBMP, .CPP refs hBitmap; HBITMAP
#                               type is already shimmed at
#                               windows.h:88; the misdiagnosis is
#                               in the issue text itself)
#
# Pre baseline (pass-44 first run, post TIM-82 commit b8f7873 with
# TIM-79 DDRAW.H WIP applied): 274 OK / 27 Fail / 301 Total.
#
# Post-TIM85-bundle (pass-44 second run, with TIM-85's worktree
# windows.h additions applied): 275 OK / 26 Fail / 301 Total.
#
# Per-TU verdicts under the TIM-85 bundle:
#   WINSTUB.CPP : LPCTSTR cleared; advanced to DLGPROC @499:79
#                 (then SYSTEMTIME @735, GetLocalTime @746)
#   MENUS.CPP   : SYSTEMTIME cleared; *fully cleared to OK* (the
#                 +1 OK net-delta is this TU)
#   BMP8.CPP    : hBitmap workaround applied; advanced to
#                 DeleteObject @24 (Win32 GDI surface, follow-up)
#
# Pass progression (OK count) -- recent tail:
#   pass 41  (TIM-77)                     : 269
#   pass 42  (TIM-80, SendMessage)        : 271
#   pass 43  (TIM-82, CountDownTimerClass): 274
#   pass 44  (TIM-83, this run, SUPERSEDED): 274 -> 274 (no own delta)
#                                            (with TIM-85 worktree:
#                                             274 -> 275, +1, but
#                                             credit attaches to
#                                             TIM-85, not TIM-83)
#
# This script is preserved for the historical record of the
# parallel-pass collision and as a reproducible harness for the
# pass-44 measurement window. The actual shim work was performed by
# TIM-85; TIM-83 lands no engine or shim edits.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44.attribution.txt"

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
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.).
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
    echo "# TIM-83 first compile attempt -- pass 44 (Win32 shim cluster drain, SUPERSEDED by TIM-85)"
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
