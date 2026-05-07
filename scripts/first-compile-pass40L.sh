#!/usr/bin/env bash
# TIM-96 measurement: pass 40L.
#
# BMP8 GDI-dispatch surface in linux/win32-stubs/windows.h. Drains the
# wingdi/winuser GDI-call family BMP8::Init and BMP8::drawBmp walk
# immediately after the TIM-94 kernel32 file/global-mem cluster.
# Mirrors TIM-87 / TIM-94 variadic-template inert-stub pattern -- no
# implementation, no real Win32 GDI; the GDI universe is dormant in
# headless mode, the eventual SDL2 + OpenGL/Vulkan port replaces.
#
# Bundle (added to linux/win32-stubs/windows.h, after the TIM-90 wingdi
# struct cluster, before the closing #endif):
#   - CreatePalette       (variadic; returns nullptr)
#   - GetDC               (variadic; returns nullptr)
#   - SelectPalette       (variadic; returns nullptr)
#   - RealizePalette      (variadic; returns 0)
#   - CreateDIBitmap      (variadic; returns nullptr)
#   - ReleaseDC           (variadic; returns 0)
#   - BeginPaint          (variadic; returns nullptr)
#   - EndPaint            (variadic; returns TRUE)
#   - CreateCompatibleDC  (variadic; returns nullptr)
#   - DeleteDC            (variadic; returns TRUE)
#   - SelectObject        (variadic; returns nullptr)
#   - GetObject(A)        (variadic; returns 0)
#   - GetClientRect       (variadic; returns TRUE)
#   - InvalidateRect      (variadic; returns TRUE)
#   - SetStretchBltMode   (variadic; returns 0)
#   - StretchBlt          (variadic; returns TRUE)
#   - BITMAP              (struct typedef; canonical wingdi shape)
#   - GDI_ERROR / CBM_INIT / DIB_RGB_COLORS / DIB_PAL_COLORS /
#     COLORONCOLOR / SRCCOPY (#define constants)
#
# Pre-survey on master c8126b3 (post TIM-94 commit) confirmed BMP8.CPP
# first-error matches the TIM-96 issue claim:
#   REDALERT/BMP8.CPP:107:11 -> '::CreatePalette' has not been declared
#
# Pre baseline (post TIM-94, commit c8126b3):
#   277 OK / 24 Fail / 301 Total.
#
# Realistic ceiling: 278 OK / 23 Fail (+1) -- BMP8.CPP fully clears
#   on Init() side; drawBmp dead-code at line 142 onwards (out-of-class
#   method, undeclared `bit8` return type) is a latent upstream bug.
# Realistic floor: 277 OK / 24 Fail (+0) -- BMP8.CPP advances past the
#   GDI surface but trips the latent `bit8`/drawBmp out-of-class bug at
#   line 142, which is engine-source territory and out-of-scope here.
#
# Histogram diff target (BMP8 only):
#   pre  -> BMP8.CPP:107:11 -> '::CreatePalette' has not been declared
#   post -> BMP8.CPP:142    -> 'bit8' does not name a type
#                              (latent upstream bug; out-of-scope)
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
#   pass 40I (TIM-89, WINSTUB mmio)       : 277
#   pass 40J (TIM-90, BMP8 wingdi structs): 278 (floor; histogram drain)
#   pass 40J' (TIM-91, _splitpath shim)   : 278 (pre-baseline tip)
#   pass 40K (TIM-94, kernel32 cluster)   : 277 (pre-baseline tip)
#   pass 40L (TIM-96, this run)           : ?
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40L.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40L.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40L.attribution.txt"

mkdir -p "$LOG_DIR"
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
    echo "# TIM-96 first compile attempt -- pass 40L (BMP8 kernel32 file/global-mem cluster)"
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
