#!/usr/bin/env bash
# TIM-99 measurement: pass 40O.
#
# SCORE.CPP first-error drain at :1008 -- 'max' was not declared in this
# scope; did you mean 'std::max'?  MSVC's <windows.h> defines `min`/`max`
# as macros (unless NOMINMAX is defined), so engine sources call
# `max(a, b)` and `min(...)` unqualified in MSVC-style. SCORE.CPP has six
# unqualified call sites:
#     :571 / :580 / :584   -- min(...) in graph-clamp helpers
#     :1008 / :1064 / :1074 / :1177 / :1185
#                          -- max(...) in Do_Nod_Buildings_Graph and
#                             Do_GDI_Graph counterparts
# Most engine TUs work around this with a per-TU `#define min/max` block
# (TIM-54 / TIM-61: AIRCRAFT, ANIM, BUILDING, CCINI, SCENARIO, ... -- 39
# TUs). SCORE.CPP doesn't have one. The drain adds `#include <algorithm>`
# (already reaches transitively via list.h -> function.h on this TU, but
# the shim now owns the dependency) and two `using` declarations
# (`using std::min; using std::max;`) at file scope inside the existing
# `!_MSC_VER` C++ branch of msvc-compat.h. Per-TU `#define min/max` blocks
# in the 39 sibling TUs continue to override at preprocessor time at the
# call site, so no collision.
#
# Sibling-shape to TIM-91 _splitpath shim drain -- header-only addition to
# msvc-compat.h, no engine source edits, smallest fix that drains the
# first-error cluster.
#
# Pre baseline (post TIM-98, commit 34c5133):
#   279 OK / 22 Fail / 301 Total.
# Post-TIM-98 attribution confirmed SCORE.CPP first-error matches the
# issue claim:
#   REDALERT/SCORE.CPP:1008:13 -> 'max' was not declared in this scope;
#                                 did you mean 'std::max'?
# A standalone smoke compile of SCORE.CPP after the using-decl addition
# completed silently (no diagnostics) -- the entire TU now parses, so
# the realistic ceiling of +1 OK is in play.
#
# Realistic ceiling: 280 OK / 21 Fail (+1) -- SCORE.CPP fully clears
#   (smoke-confirmed pre-pass).
# Realistic floor:   279 OK / 22 Fail (+0) -- a deeper TU surfaces a new
#   first-error from the using-decls (no plausible mechanism, but stated
#   floor of the issue).
#
# Histogram diff target (SCORE only):
#   pre  -> SCORE.CPP:1008:13 -> 'max' was not declared in this scope
#   post -> SCORE.CPP         (no diagnostic; OK)
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
#   pass 40O (TIM-99, this run)           : ?
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# msvc-compat.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40O.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40O.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40O.attribution.txt"

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
    echo "# TIM-99 first compile attempt -- pass 40O (SCORE.CPP std::max msvc-compat drain)"
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
