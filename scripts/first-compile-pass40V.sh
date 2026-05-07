#!/usr/bin/env bash
# TIM-106 measurement: pass 40V (paired step-2: shim + INIT.CPP :3584 hoist).
#
# Step-2 of the paired INIT.CPP drain. The registry shim landed in
# pass-40U (commit bbdbc48); the engine-source change in this pass is
# the canonical lvalue hoist at INIT.CPP:3584:
#
#   before:  ini.Load(CCFileClass("TUTORIAL.INI"));
#   after:   CCFileClass tutorial_file("TUTORIAL.INI");
#            ini.Load(tutorial_file);
#
# FileClass::Load takes a non-const reference, so the temporary form
# was an rvalue-bind error under modern g++. Naming the temporary is
# the canonical fix.
#
# With the registry cluster in scope (pass-40U) the downstream
# Is_DVD_Installed() block at :3741-:3757 also parses cleanly, so
# INIT.CPP graduates FAIL -> OK in this pass.
#
# Standalone smoke compile of INIT.CPP (against the pass-40U-tip
# windows.h shim) exits with no diagnostics, confirming the cascade
# from TIM-105 is fully drained for this TU.
#
# Pre baseline (pass-40U tip, commit bbdbc48):
#   284 OK / 17 Fail / 301 Total.
#
# Realistic ceiling: 285 OK / 16 Fail (+1) -- INIT.CPP graduates.
# Realistic floor:   284 OK / 17 Fail (+0) -- a third hidden error
#   inside INIT.CPP surfaces post-hoist (cascade rule per TIM-105 /
#   TIM-106 stop-and-hand-back contract).
#
# Histogram diff target:
#   pre  -> INIT.CPP:3584 cannot bind FileClass& to rvalue
#   post -> INIT.CPP gone from FAIL list (ceiling), or
#           a third hidden error inside INIT.CPP (floor).
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
#   pass 40S (TIM-103, LZWOTRAW deeper)   : 281
#   pass 40T (TIM-105, HEAP+PALETTE)      : 283 (+2 vs 40S)
#   post-40T (TIM-107, MIXFILE Unlink)    : 284 (drift commit, no pass)
#   pass 40U (TIM-106, registry shim)     : 284 (paired step-1, +0 floor)
#   pass 40V (TIM-106, INIT hoist)        : ? (paired step-2)
#
# Measurement script -- the engine-source change lives in
# REDALERT/INIT.CPP at :3584-:3585 (lvalue hoist for ini.Load).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40V.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40V.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40V.attribution.txt"

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
    echo "# TIM-106 first compile attempt -- pass 40V (shim + INIT.CPP :3584 hoist, paired step-2)"
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
