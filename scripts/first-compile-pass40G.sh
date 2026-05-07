#!/usr/bin/env bash
# TIM-87 measurement: pass 40G.
#
# Win32 type/API stub bundle in linux/win32-stubs/. Five additive
# entries to drain the CONQUER / MENUS / WINSTUB / RAWFILE / BMP8
# cluster (all five TUs whose first-error post-TIM-82 is a missing
# Win32-shaped symbol). Mirrors the TIM-71 / TIM-74 / TIM-75 bundled
# Win32-stub pattern.
#
# Bundle:
#   linux/win32-stubs/windows.h:
#     - LPCTSTR / LPTSTR typedef alias to LPCSTR / LPSTR (ANSI default)
#     - SYSTEMTIME struct + GetSystemTime inert decl
#     - GetVolumeInformation / GetVolumeInformationA variadic-template
#       inert stub (returns 0 / FALSE)
#     - inline HBITMAP hBitmap global (BMP8.CPP destructor typo --
#       BMP8.H declares hBMP, .CPP refs hBitmap; HBITMAP type already
#       shimmed at windows.h:88)
#   linux/win32-stubs/dos.h:
#     - _dos_open / _dos_creat / _dos_close / _dos_read / _dos_write /
#       _dos_getftime / _dos_setftime variadic-template inert stubs
#       (RAWFILE.CPP DOS file-API family inside its `#ifndef WIN32`
#       branch; all return 0 success-shaped)
#
# Pre-survey on master cc629d7 (post TIM-84) confirmed each TU's
# first-error matches the issue table:
#   REDALERT/CONQUER.CPP:4289 -> GetVolumeInformation
#   REDALERT/MENUS.CPP:842    -> SYSTEMTIME
#   REDALERT/WINSTUB.CPP:499  -> LPCTSTR
#   REDALERT/RAWFILE.CPP:259  -> _dos_open
#   REDALERT/BMP8.CPP:23      -> hBitmap
#
# Pre baseline (post TIM-82, commit b8f7873, with TIM-79 DDRAW.H WIP
# applied; TIM-84 commit cc629d7 was OK 274->274 +0):
#   274 OK / 27 Fail / 301 Total.
# (Note: TIM-79 IDirectDrawPalette stub is held in worktree as
#  uncommitted DDRAW.H WIP per parallel-pass coordination; the
#  baseline assumes that WIP is applied. This pass measurement holds
#  TIM-79 WIP applied for both pre and post counts.)
#
# Realistic ceiling: 279 OK / 22 Fail (+5) -- all five TUs advance to
# OK.
# Realistic floor:   274 OK / 27 Fail (+0) -- each TU advances to a
#   deeper non-listed first-error (cluster drained, no regressions).
# Smoke-confirmed per-TU after-stub first-error:
#   CONQUER -> GENERIC_READ @4300 (Win32 CreateFile constants)
#   MENUS   -> OK (cleared)
#   WINSTUB -> DLGPROC @499:79 (Win32 dialog-proc typedef)
#   RAWFILE -> filelength @881 (DOS file-size API)
#   BMP8    -> ::DeleteObject @24 (Win32 GDI cleanup function)
# Smoke-projected outcome: +1 OK (MENUS only), other 4 advance to
# deeper Win32-stub-shape first-errors (sized for pass-40G).
#
# Same harness as passes 7-43 -- same flags, same shim regen, same
# stubs. Difference relative to pass 43: one bundled additive edit
# spanning two stub headers (linux/win32-stubs/windows.h and
# linux/win32-stubs/dos.h, TIM-87 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, CountDownTimerClass): 274 (with TIM-79 WIP)
#   pass 45  (TIM-84, ENGLISH= pin)       : 274
#   pass 40G (TIM-87, this run)           : ???  (smoke +1 -> 275)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# windows.h and linux/win32-stubs/dos.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40G.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40G.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40G.attribution.txt"

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
    echo "# TIM-87 first compile attempt -- pass 40G (Win32 type/API stub bundle)"
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
