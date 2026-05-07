#!/usr/bin/env bash
# TIM-102 measurement: pass 40R.
#
# BMP8.CPP `bit8` typedef latent-bug. The drawBmp() out-of-class method
# at REDALERT/BMP8.CPP:142 has return type `bit8`, an upstream Westwood
# `wstypes.h` typedef (unsigned 8-bit) that no longer ships with the
# repo. Smallest fix: add a single-line `typedef unsigned char bit8;`
# directly above :142 inside BMP8.CPP itself. The typedef is local to
# the TU because `bit8` only appears at this one site in the entire
# repo (grep confirmed) -- not a header-side wstypes/wingdi cluster.
#
# Pre baseline (post TIM-101, commit 391e30f):
#   280 OK / 21 Fail / 301 Total.
#
# Standalone smoke compile after the typedef fix confirms:
#   - BMP8.CPP first-error advances to :145:6 'no declaration matches
#     bit8 BMP8::drawBmp()' -- a deeper engine-source bug. drawBmp() is
#     dead code: not declared on the BMP8 class (BMP8.H only declares
#     Init() and Draw()) and references stale fields WindowHandle_,
#     PalHandle_, BitmapHandle_ that don't exist on the class either.
#     This is a separate cluster from the typedef and is out-of-scope
#     for this pass per the issue's stop-and-hand-back criterion.
# BMP8.CPP stays FAIL with the deeper class-decl-mismatch first-error
# -- realistic floor of +0 OK is in play.
#
# Realistic ceiling: 281 OK / 20 Fail (+1) -- not in play; BMP8.CPP
#   surfaces a deeper engine-source dead-code bug immediately after
#   the typedef fix.
# Realistic floor:   280 OK / 21 Fail (+0) -- BMP8.CPP stays FAIL but
#   its first-error histogram entry shifts forward into deeper
#   class-decl-mismatch territory.
#
# Histogram diff target:
#   pre  -> BMP8.CPP:142:1 -> 'bit8' does not name a type
#   post -> BMP8.CPP:145:6 -> no declaration matches 'bit8 BMP8::drawBmp()'
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
#   pass 40J' (TIM-91, _splitpath shim)   : 278
#   pass 40K (TIM-94, kernel32 cluster)   : 277
#   pass 40K' (TIM-92, GetModuleFileName) : 277
#   pass 40L (TIM-96, BMP8 GDI dispatch)  : 277 (floor; histogram drain)
#   pass 40L' (TIM-95, PostMessage drain) : 278
#   pass 40M (TIM-97, TEXT_* alias)       : 278 (floor; histogram drain)
#   pass 40N (TIM-98, ExitProcess)        : 279
#   pass 40O (TIM-99, SCORE std::max)     : 280
#   pass 40P (TIM-100, LZWOTRAW typo)     : 280 (floor; histogram drain)
#   pass 40Q (TIM-101, DrawMisc+MiscAsm)  : 280 (floor; histogram drain)
#   pass 40R (TIM-102, this run)          : ?
#
# Measurement script -- the actual fix lives in REDALERT/BMP8.CPP:141
# (single-line typedef inserted just above the drawBmp definition).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40R.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40R.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40R.attribution.txt"

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
    echo "# TIM-101 first compile attempt -- pass 40R (LZWOTRAW.CPP staging_buffer typo)"
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
