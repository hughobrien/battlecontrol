#!/usr/bin/env bash
# TIM-80 measurement: pass 42.
#
# Win32 window-message shim drain in linux/win32-stubs/windows.h. The
# cluster surfaced post TIM-77 in WSPROTO.CPP / WSPUDP.CPP as the next
# first-error (SendMessage) once the winsock cluster was drained. Single
# trivially-additive entry, matching the proven TIM-67 audio-symbol /
# TIM-71 input-symbol / TIM-74-77 GDI-/winsock-symbol shape.
#
# Functions added:
#   SendMessage(HWND, UINT, WPARAM, LPARAM)  -> 0
#
# Sibling window-message symbols (PostMessage, DispatchMessage,
# DefWindowProc) were checked against the post-TIM-77 first-error
# histogram and did NOT surface as first-error in any TU; DispatchMessage
# is already shimmed by TIM-71. Scope intentionally NOT widened beyond
# the survey-confirmed entry.
#
# Pre baseline (post TIM-77, commit 38baebb):
#   pass 41 (TIM-77) : 269 OK / 32 Fail / 301 Total.
#
# Realistic ceiling for THIS pass: 271 OK (+2) -- if WSPROTO and WSPUDP
#   both reach OK (cluster purely header-shaped).
# Realistic floor: 269 OK (+0) -- both advance to a deeper non-message
#   first-error.
#
# Pre-survey single-TU smoke (post-edit) confirmed:
#   WSPROTO.CPP -> exit 0 (cluster cleared).
#   WSPUDP.CPP  -> exit 0 (cluster cleared).
#
# Same harness as passes 7-41 -- same flags, same shim regen, same
# stubs. Difference relative to pass 41: one bundled additive edit in
# linux/win32-stubs/windows.h (TIM-80 SendMessage entry).
#
# Pass progression (OK count) -- recent tail:
#   pass 38 (TIM-71)                      : 266
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 41  (TIM-77)                     : 269
#   pass 42  (TIM-80, this run)           : ???  (expected 271)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass42.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass42.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass42.attribution.txt"

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
    echo "# TIM-80 first compile attempt -- pass 42 (Win32 window-message shim)"
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
