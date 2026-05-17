#!/usr/bin/env bash
# TIM-68 measurement: pass 35.
#
# Bundled Group C source-level pass on the five remaining sub-3-TU
# residual buckets inventoried after TIM-67/pass-34. Heterogeneous
# fixes (per-bucket independent) -- bundling is purely overhead
# amortization (one pre/post measurement, one inventory write-up).
#
# Per-bucket outcomes (see TIM-68 issue thread for the verdict table):
#   1a) overload-resolution / NOSEQCON.CPP:73
#       fix: add (numsend, numrecieve) pass-through to ConnectionClass
#            ctor (REDALERT/CONNECT.H:147 added them; the call site was
#            never updated when RA grew the queue-sizing params).
#       outcome: cleared bucket-1a root cause; TU first-errors at
#                NOSEQCON.CPP:408 (Send overload) -- fragmented.
#
#   1b) overload-resolution / TURRET.CPP:83 + :109
#       fix: delegate both empty-body ctors to DriveClass(NoInitClass())
#            (TurretClass is dead code in RA -- no `new TurretClass`
#            anywhere; only declared in TURRET.{H,CPP}).
#       outcome: TU CLEARED -- graduates FAIL -> OK.
#
#   2)  InitializeCriticalSection / WIN32LIB/MOUSEWW.CPP:78
#       fix: add inert Initialize/Enter/Leave/DeleteCriticalSection
#            inline no-ops to linux/win32-stubs/windows.h next to the
#            CRITICAL_SECTION typedef from TIM-54. The whole mouse/audio
#            threading path is dormant; pthread-backed shims land later.
#       outcome: cleared bucket-2 root cause; TU first-errors at
#                MOUSEWW.CPP:381 (GetCursorPos) -- fragmented.
#
#   3)  GetCDClass / WIN32LIB/WRITEPCX.CPP via externs.h:157
#       fix: forward-declare `class GetCDClass;` in REDALERT/EXTERNS.H
#            before the `extern GetCDClass CDList;` declaration. The
#            recursive include chain wwlib32.h:47 -> mouse.h ->
#            sidebar.h -> function.h -> externs.h reaches this header
#            *before* wwlib32.h:54's #include <playcd.h> has fired.
#            extern of an incomplete type is legal here -- only the
#            declaration is parsed, not any member access.
#       outcome: cleared bucket-3 root cause; TU first-errors at
#                inline.h:929 (Extract_String) -- fragmented.
#
#   4)  StreamLowImpact conflict / SCORE.CPP:48,72 vs WIN32LIB/AUDIO.H:159
#       fix: drop the two `#ifndef WIN32 / extern short StreamLowImpact;
#            / #endif` decls in SCORE.CPP. AUDIO.H's `extern int
#            StreamLowImpact;` (declared in WIN32LIB) is the canonical
#            one and is now always pulled in via function.h after the
#            TIM-67 shim fix. Type mismatch (short vs int) was the
#            conflict.
#       outcome: cleared bucket-4 root cause; TU first-errors at
#                SCORE.CPP:1008 (max() ADL) -- fragmented.
#
#   5)  TEXT_MAP_ERROR / CONQUER.CPP:2398
#       fix: add `#define ENGLISH 1` block at top of CONQUER.CPP before
#            #include "function.h" so LANGUAGE.H's English text macros
#            (TEXT_MAP_ERROR, TEXT_STOP, TEXT_CONTINUE) expand. The
#            language define is normally injected by the original
#            makefile (DEFINES.H:46-50 documents this).
#       outcome: cleared bucket-5 root cause; TU first-errors at
#                CONQUER.CPP:4277 (CountDownTimerClass / Win32 file
#                APIs) -- fragmented.
#
# Pre baseline (post TIM-67, commit e43c97b):
#   pass 34 (TIM-67) : 259 OK / 42 Fail / 301 Total.
#
# Target ceiling: 265 OK / 36 Fail / 301 Total (+6 if all clear).
# Realistic expectation: +1 OK (TURRET.CPP) + 5 fragmented (advance
# past first-error to deeper Group C bucket); net OK delta = +1.
#
# Same harness as passes 7-34 -- same flags, same shim regen, same
# stubs. Difference relative to pass 34: per-bucket source-level edits
# in REDALERT/{NOSEQCON,TURRET,SCORE,CONQUER,EXTERNS}.{CPP,H}, plus
# CRITICAL_SECTION inline thunks in linux/win32-stubs/windows.h.
#
# Pass progression (OK count) -- recent tail:
#   pass 30 (TIM-56)                      : 249
#   pass 31 (TIM-59 + TIM-61)             : 253
#   pass 31-rebaselined (post TIM-62/65)  : 254
#   pass 32 (TIM-63)                      : 254
#   pass 33 (TIM-66)                      : 254
#   pass 34 (TIM-67)                      : 259
#   pass 35 (TIM-68, this run)            : ???  (target ceiling 265)
#
# Measurement script -- the actual fixes live in the source files
# named above.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass35.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass35.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass35.attribution.txt"

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
    # TIM-6: force-include the MSVC-extension shim (calling-convention
    # macros, __int64 typedef, _lrotl). TIM-11 added _NO_COM. TIM-15
    # added itoa/ltoa wrappers and IDirectDrawSurface forward-decl.
    # TIM-29 added far/near/pascal lowercase keyword shim. TIM-31 added
    # INVALID_HANDLE_VALUE to the stub windows.h. TIM-34 added stub
    # memory.h with MemoryClass to unblock AUDIO.H. TIM-36 expanded
    # memory.h to the full AUDIO.H surface (operator bool, Free(const),
    # GameActive, free(const)). TIM-38 promoted ShapeFlags_Type to a
    # named enum to clear shape.h:83 vs jshell.h:221 conflict. Force-
    # include keeps the upstream sources untouched for the cross-cutting
    # MSVC-isms.
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
    echo "# TIM-68 first compile attempt -- pass 35 (post TIM-68 source-level pass: 5 buckets, 6 TUs)"
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

    # Per-TU log captured to a temp so we can extract the *first*
    # diagnostic line for the per-TU primary-error attribution table.
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
        # First "error:" or "fatal error:" line is the primary site.
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

# Tally include-not-found errors so we can compare against pass 18's
# baseline (3 misses, all known-dead siblings).
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
