#!/usr/bin/env bash
# TIM-90 measurement: pass 40J.
#
# BMP8 wingdi struct cluster in linux/win32-stubs/windows.h. Drains
# the small POD-typedef family the BMP loader declares on the stack
# (BITMAPFILEHEADER and siblings). Mirrors the TIM-71/TIM-74/TIM-75/
# TIM-85/TIM-87 bundled Win32-shim pattern -- declarations only, no
# implementations, smallest shape that lets the parser advance.
#
# Bundle (added to linux/win32-stubs/windows.h, after the TIM-87 block):
#   - HGLOBAL                         (typedef HANDLE; opaque global-mem handle)
#   - SECURITY_ATTRIBUTES + LP/P aliases (CreateFile lpSecurity arg)
#   - BITMAPFILEHEADER + LP/P aliases (5-field BMP file header)
#   - BITMAPINFOHEADER + LP/P aliases (11-field DIB header)
#   - RGBQUAD + LP alias              (4-byte BGRA palette entry)
#   - BITMAPINFO + LP/P aliases       (BITMAPINFOHEADER + RGBQUAD[1])
#   - LOGPALETTE + LP/P/NP aliases    (WORD,WORD + PALETTEENTRY[1])
#   - PAINTSTRUCT + LP/P/NP aliases   (BeginPaint context)
#
# All field names + layouts match the canonical Win32 SDK (wingdi.h /
# minwinbase.h / winuser.h) so any sizeof / pointer-cast through engine
# code stays well-defined. No field is read at runtime because the GDI
# universe (palette, blit, paint cycle) is dormant under the stub --
# real CreatePalette / GetDC / SelectPalette / BitBlt land in a later
# SDL2 / OpenGL port.
#
# PALETTEENTRY (TIM-55), HPALETTE (~line 94), LPVOID (~line 119),
# HBITMAP (~line 88), HDC (~line 87), RECT/POINT/SIZE (~line 137) are
# already shimmed and reused as field types.
#
# Pre-survey on master 132ff63 (post TIM-89) confirmed BMP8.CPP first-
# error still matches the TIM-90 issue claim:
#   REDALERT/BMP8.CPP:35 -> 'BITMAPFILEHEADER' was not declared in this scope
#
# (Note: TIM-88 [346e2ab, RAWFILE lseek] and TIM-89 [132ff63, WINSTUB
# GetLocalTime + mmio cluster] both landed concurrently with TIM-90
# work. TIM-88/89 are disjoint from BMP8.CPP and the wingdi cluster.
# TIM-91 [_splitpath in msvc-compat.h] is in-progress and not yet
# committed; both pre and post measurements include it as ambient
# workspace state, so the delta is clean.)
#
# Pre baseline (post TIM-89, commit 132ff63, with TIM-91 in-flight):
#   278 OK / 23 Fail / 301 Total.
#
# Realistic ceiling: 279 OK / 22 Fail (+1) -- BMP8.CPP fully clears
#   (would require draining several Win32 kernel/GDI dispatch surfaces
#   that are out of TIM-90 scope: ReadFile, GlobalAlloc/Lock/Unlock,
#   GHND, CreatePalette, GetDC, SelectPalette, RealizePalette,
#   ReleaseDC, GDI_ERROR, CreateDIBitmap, CBM_INIT, DIB_RGB_COLORS,
#   BeginPaint, EndPaint, GetClientRect, InvalidateRect,
#   CreateCompatibleDC, SelectObject, GetObject, SetStretchBltMode,
#   COLORONCOLOR, StretchBlt, SRCCOPY, DeleteDC, BITMAP). Not
#   achievable without expanding scope beyond "wingdi struct cluster".
# Realistic floor: 278 OK / 23 Fail (+0) -- BMP8.CPP advances to a
#   deeper first-error in BMP8 itself; cluster drained.
# Measured post pass-40J: 278 OK / 23 Fail (floor case; histogram
#   drain on BMP8 only, no other TU touched).
# Post first-error in BMP8.CPP:
#   BMP8 -> ::ReadFile @65 (Win32 kernel32 file API, NOT GDI).
#
# Per the issue's stop criterion ("BMP8 advances to a real GDI-dispatch
# first-error -- close out as +1 OK and queue the new surface
# separately"), the post-cluster surface is kernel32 (ReadFile,
# GlobalAlloc, GlobalLock) before any GDI-dispatch surface -- a
# follow-up issue should bundle the kernel32 file/global-mem cluster
# (or stub them with the same variadic-template pattern as TIM-87
# CreateFile/CloseHandle/DeleteObject) before the GDI dispatch family.
#
# Histogram diff (BMP8 only):
#   pre  -> BMP8.CPP:35 -> 'BITMAPFILEHEADER' was not declared
#   post -> BMP8.CPP:65 -> '::ReadFile' has not been declared
# (Cluster drained; advanced 30 lines into Init() body.)
#
# Pass timeline so far:
#   pass 39  (TIM-74)                     : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, CountDownTimerClass): 274 (with TIM-79 WIP)
#   pass 45  (TIM-84, ENGLISH= pin)       : 274
#   pass 40F (TIM-85, Win32 stub bundle)  : 275
#   pass 40G (TIM-87, Win32 shape bundle) : 276
#   pass 40H (TIM-88, RAWFILE lseek)      : 277
#   pass 40I (TIM-89, WINSTUB mmio)       : 277 (RAWFILE re-checked, no net)
#   pass 40J (TIM-90, this run)           : 278 (floor; histogram drain on BMP8)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40J.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40J.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40J.attribution.txt"

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
    echo "# TIM-90 first compile attempt -- pass 40J (BMP8 wingdi struct cluster)"
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
