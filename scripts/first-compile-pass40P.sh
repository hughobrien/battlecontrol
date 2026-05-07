#!/usr/bin/env bash
# TIM-100 measurement: pass 40P.
#
# LZWOTRAW.CPP first-error drain at :163 -- 'staging_buffer' was not
# declared in this scope; did you mean 'stageing_buffer'? Engine-source
# one-line typo correction: rename the lone outlier use at :163 to match
# the in-scope declaration at :162 ('stageing_buffer'). The sibling TU
# LZOSTRAW.CPP uses the canonical spelling 'staging_buffer' four times,
# but normalizing across the misspelled-typo TU is explicitly out of
# scope for this pass (smallest-fix rule).
#
# Pre baseline (post TIM-99, commit cd56df9):
#   280 OK / 21 Fail / 301 Total.
# Post-TIM-99 attribution confirmed LZWOTRAW.CPP first-error matches the
# issue claim:
#   REDALERT/LZWOTRAW.CPP:163:46 -> 'staging_buffer' was not declared in
#                                   this scope; did you mean
#                                   'stageing_buffer'?
# A standalone smoke compile of LZWOTRAW.CPP after the rename advanced
# the first-error to :166 ('ptr' was not declared in this scope, plus
# 'lz01x_decompress' typo and lzo1x_1_compress arg-type mismatches) --
# all deeper engine-source bugs strictly out of scope for this pass.
# That puts the realistic floor of +0 OK in play (LZWOTRAW.CPP stays
# FAIL with a different first-error).
#
# Realistic ceiling: 281 OK / 20 Fail (+1) -- not in play; deeper
#   LZWOTRAW.CPP bugs surface immediately after the rename.
# Realistic floor:   280 OK / 21 Fail (+0) -- LZWOTRAW.CPP stays FAIL
#   but its first-error histogram entry shifts from :163 staging_buffer
#   to :166 ptr/lz01x_decompress (deeper engine-source bug cluster).
#
# Histogram diff target (LZWOTRAW only):
#   pre  -> LZWOTRAW.CPP:163:46 -> 'staging_buffer' was not declared
#   post -> LZWOTRAW.CPP:166:43 -> 'ptr' was not declared (deeper)
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
#   pass 40P (TIM-100, this run)          : ?
#
# Measurement script -- the actual fix lives in REDALERT/LZWOTRAW.CPP:163.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40P.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40P.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40P.attribution.txt"

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
    echo "# TIM-100 first compile attempt -- pass 40P (LZWOTRAW.CPP staging_buffer typo)"
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
