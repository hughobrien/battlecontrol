#!/usr/bin/env bash
# TIM-67 measurement: pass 34.
#
# Group C source-level pass on the audio-symbol residual bucket
# inventoried after pass-33. Five TUs first-error at audio symbols
# declared in REDALERT/WIN32LIB/AUDIO.H (Play_Sample / SFX_Type /
# Sample_Type / SampleType):
#   - REDALERT/SCENARIO.CPP:1656  ->  Play_Sample not declared
#   - REDALERT/SCORE.CPP:187      ->  Play_Sample not declared
#   - REDALERT/AUDIO.CPP:55       ->  SFX_Type not declared
#                                       (followed by Sample_Type:56,
#                                        SampleType:856)
#   - REDALERT/THEME.CPP:196      ->  SampleType not declared
#   - REDALERT/CONQUER.CPP:1630   ->  SampleType not declared
#
# Single-site root cause: the case-folding include shim
# (build/include-shim/) had a basename collision on `audio.h` between
# REDALERT/AUDIO.H and REDALERT/WIN32LIB/AUDIO.H. The shim generator
# took candidates[0] (REDALERT/AUDIO.H, the dead-code AudioClass
# header) and never produced a win32lib/audio.h symlink. Every TU
# transitively included `<audio.h>` through WIN32LIB/WWLIB32.H:51
# but landed on REDALERT/AUDIO.H -- which defines AudioClass (used
# by no source file in the tree) and lacks the Westwood audio surface
# (Play_Sample / SFX_Type / Sample_Type / extern SoundType /
# extern SampleType) that the failing TUs reference.
#
# TIM-67 fix lives in scripts/generate-include-shim.py: when
# resolving the `audio.h` basename and multiple candidates exist,
# prefer the WIN32LIB candidate so the shim ships
# win32lib/audio.h -> REDALERT/WIN32LIB/AUDIO.H. The redalert/audio.h
# symlink is no longer produced (REDALERT/AUDIO.H is referenced by
# nothing in the tree -- verified by `grep -rn AudioClass REDALERT/`
# which finds only its definition at REDALERT/AUDIO.H itself).
#
# Hypothesis (single-site): one shim-generator change clears all 5
# TUs simultaneously.
#
# Pre baseline:
#   pass 33 (TIM-66) post-commit c277e68 : 254 OK / 47 Fail / 301 Total.
#
# Same harness as passes 7-33 -- same flags, same shim regen, same
# stubs. Difference relative to pass 33 is upstream-only (one
# generator-script edit; no shim restructuring, no flag changes,
# no engine source edits, no manual shim symlink edits).
#
# Pass progression (OK count) -- recent tail:
#   pass 30 (TIM-56)                      : 249
#   pass 31 (TIM-59 + TIM-61)             : 253
#   pass 31-rebaselined (post TIM-62/65)  : 254
#   pass 32 (TIM-63)                      : 254
#   pass 33 (TIM-66)                      : 254
#   pass 34 (TIM-67, this run)            : ???  (target ceiling 259)
#
# Measurement only -- TIM-67 fix lives in scripts/generate-include-shim.py.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass34.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass34.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass34.attribution.txt"

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
    echo "# TIM-67 first compile attempt -- pass 34 (post TIM-67 shim-generator audio.h collision fix in scripts/generate-include-shim.py)"
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
