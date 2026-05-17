#!/usr/bin/env bash
# TIM-71 measurement: pass 38.
#
# Family-grouped Win32-input shim drain in linux/win32-stubs/windows.h:
# the message-pump cluster surfaced by the TIM-70 GetKeyState clear in
# KEY.CPP / KEYBOARD.CPP. All entries are trivially-additive (inert
# inline returns, opaque struct typedefs, integer/macro constants),
# matching the proven TIM-67 audio-symbol shape.
#
# Functions added:
#   MapVirtualKey(UINT,UINT)                          -> 0
#   GetAsyncKeyState(int)                             -> 0
#   ToAscii(UINT,UINT,const BYTE*,LPWORD,UINT)        -> 0
#   PeekMessage(LPMSG,HWND,UINT,UINT,UINT)            -> FALSE
#   GetMessage(LPMSG,HWND,UINT,UINT)                  -> FALSE
#   TranslateMessage(const MSG*)                      -> FALSE
#   DispatchMessage(const MSG*)                       -> 0
#
# Types added:
#   PBYTE (BYTE*), WPARAM (uintptr_t), LPARAM (intptr_t),
#   MSG { hwnd; message; wParam; lParam; time; pt; }, LPMSG
#
# Macros / constants added:
#   PM_NOREMOVE, PM_REMOVE,
#   WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP,
#   WM_MOUSEMOVE, WM_LBUTTONDOWN/UP/DBLCLK,
#   WM_RBUTTONDOWN/UP/DBLCLK, WM_MBUTTONDOWN/UP/DBLCLK,
#   LOWORD(l), HIWORD(l)
#
# (WM_MBUTTON*/WM_RBUTTONDBLCLK and PBYTE were not in the issue's
# initial in-scope list but are strict trivially-additive siblings of
# the requested cluster -- KEYBOARD.CPP:419/425/431/452 have active
# case labels for the middle-button + right-double-click messages, and
# (PBYTE)KeyState casts at KEY.CPP:321 / KEYBOARD.CPP:264 land once
# ToAscii is declared. Adding them is a single-line additive form per
# entry.)
#
# Pre baseline (post TIM-70, commit 9c4d35f):
#   pass 37 (TIM-70) : 264 OK / 37 Fail / 301 Total.
#
# Realistic ceiling for THIS pass: 268 OK / 33 Fail / 301 Total
#   (KEY.CPP + KEYBOARD.CPP clear; siblings depend on first-error
#    cascades).
# Realistic floor: +2 OK (KEY.CPP + KEYBOARD.CPP advance past the
#   input family but cascade into a deeper non-input bucket).
#
# Same harness as passes 7-37 -- same flags, same shim regen, same
# stubs. Difference relative to pass 37: one bundled additive edit in
# linux/win32-stubs/windows.h (TIM-71 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 30 (TIM-56)                      : 249
#   pass 31 (TIM-59 + TIM-61)             : 253
#   pass 31-rebaselined (post TIM-62/65)  : 254
#   pass 32 (TIM-63)                      : 254
#   pass 33 (TIM-66)                      : 254
#   pass 34 (TIM-67)                      : 259
#   pass 35 (TIM-68)                      : 260
#   pass 36 (TIM-69)                      : 264
#   pass 37 (TIM-70)                      : 264
#   pass 38 (TIM-71, this run)            : ???  (expected 266-268)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass38.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass38.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass38.attribution.txt"

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
    echo "# TIM-71 first compile attempt -- pass 38 (Win32-input cluster shim)"
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
