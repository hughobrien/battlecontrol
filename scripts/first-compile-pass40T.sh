#!/usr/bin/env bash
# TIM-105 measurement: pass 40T.
#
# LZWOTRAW.CPP deeper bug cluster (deferred from TIM-100). The
# LZWStraw::Get() function body had three surfaced bugs at :166-:173:
#   1. Undeclared `ptr` at :166 (canonical sibling LZOSTRAW.CPP uses
#      the local `staging_buffer` -- LZWOTRAW spells it `stageing_buffer`).
#   2. `lz01x_decompress` typo (digit `0`) -> `lzo1x_decompress`.
#   3. lzo_uint arg-type mismatches at both call sites: char* dst/src
#      need `(unsigned char*)` casts, and the in/out length param needs
#      to be a local `unsigned int length` rather than `sizeof(Buffer)`
#      (raw int) at :166 or `&BlockHeader.CompCount` (unsigned short*)
#      at :173. Sibling LZOSTRAW.CPP shows the canonical pattern:
#        unsigned int length = sizeof(Buffer);
#        lzo1x_decompress((unsigned char*)stageing_buffer, ..., &length, NULL);
#      and on the compress side a writeback:
#        BlockHeader.CompCount = (unsigned short)length;
#      to preserve the original side-effect.
#
# The fix is engine-source-only; no header/shim/flag changes. It
# matches the canonical sibling pattern exactly.
#
# Pre baseline (post TIM-102, commit 630762a):
#   280 OK / 21 Fail / 301 Total.
#
# Standalone smoke compile of LZWOTRAW.CPP after the cluster fix exits
# clean (no diagnostics) -- which means LZWOTRAW.CPP graduates from
# FAIL to OK in this pass. Realistic ceiling (+1 OK) is in play.
#
# Realistic ceiling: 281 OK / 20 Fail (+1) -- LZWOTRAW.CPP clears.
# Realistic floor:   280 OK / 21 Fail (+0) -- LZWOTRAW.CPP stays FAIL
#   with a deeper engine-source first-error post-cluster.
#
# Histogram diff target:
#   pre  -> LZWOTRAW.CPP:166:43 -> 'ptr' was not declared in this scope
#   post -> LZWOTRAW.CPP gone from FAIL list (ceiling), or
#           deeper first-error inside LZWStraw::Get (floor).
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
#   pass 40R (TIM-102, BMP8 bit8 typedef) : 280 (floor; histogram drain)
#   pass 40T (TIM-105, this run)          : ?
#
# Measurement script -- the actual fix lives in REDALERT/LZWOTRAW.CPP
# inside LZWStraw::Get() (the function body containing :166-:173).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40T.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40T.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40T.attribution.txt"

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
    echo "# TIM-105 first compile attempt -- pass 40T (Tier-A 1-line drain HEAP+PALETTE)"
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
