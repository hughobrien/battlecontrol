#!/usr/bin/env bash
# TIM-101 measurement: pass 40Q.
#
# DrawMisc + MiscAsm inline-asm latent-bug bundle. Two engine-source
# one-line lex-time fixes inside __asm { ... } comment text:
#   1. REDALERT/WIN32LIB/DrawMisc.cpp:1440 -- ;"...Hughes opens an
#      unterminated string literal that the original asm-comment closed
#      on line 1441. Smallest fix: append `\` line-continuation at end
#      of :1440 so the preprocessor splices :1440 + :1441 into one
#      logical line containing a complete string literal. (Closing the
#      `"` on :1440 alone would shift the lex error to :1441's stray
#      `"`. The sibling occurrence at :4636 is out of scope for this
#      pass -- one line per TU.)
#   2. REDALERT/MiscAsm.cpp:1147 -- '(1..255)' lexes as a malformed
#      numeric literal. Smallest fix: '..' -> '-' to read '(1-255)'.
#
# Pre baseline (post TIM-100, commit e03603e):
#   280 OK / 21 Fail / 301 Total.
#
# Standalone smoke compiles after both fixes confirm:
#   - MiscAsm.cpp first-error advances to :56:15 'expected (' before
#     '{' token' -- parse-time __asm{} block syntax (asm artefact).
#   - DrawMisc.cpp first-error advances to :2698:22 'missing
#     terminating \\' character' -- apostrophe in "Don't" inside an
#     asm comment (asm artefact). The :4636 sibling lex-error is
#     masked by the earlier :2698 lex-error.
# Both TUs stay FAIL with deeper asm-artefact first-errors -- realistic
# floor of +0 OK is in play.
#
# Realistic ceiling: 282 OK / 19 Fail (+2) -- not in play; both TUs
#   surface deeper asm-artefacts immediately after the lex fix.
# Realistic floor:   280 OK / 21 Fail (+0) -- both TUs stay FAIL but
#   their first-error histogram entries shift forward into deeper
#   asm-artefact territory.
#
# Histogram diff target:
#   pre  -> MiscAsm.cpp:1147:64 -> too many decimal points in number
#   post -> MiscAsm.cpp:56:15   -> expected '(' before '{' (asm{} parse)
#   pre  -> DrawMisc.cpp:1440:18 -> missing terminating " character
#   post -> DrawMisc.cpp:2698:22 -> missing terminating ' character (Don't)
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
#   pass 40Q (TIM-101, this run)          : ?
#
# Measurement script -- the actual fixes live in
# REDALERT/WIN32LIB/DrawMisc.cpp:1440 and REDALERT/MiscAsm.cpp:1147.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40Q.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40Q.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40Q.attribution.txt"

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
    echo "# TIM-101 first compile attempt -- pass 40Q (LZWOTRAW.CPP staging_buffer typo)"
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
