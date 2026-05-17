#!/usr/bin/env bash
# TIM-51 measurement: pass 26.
#
# Re-baseline after TIM-51 (this ticket -- 7-TU sub-cohort chain audit
# of the new tcpip.h:96 first-error bucket from pass-25). Captured the
# full-diagnostic stream for CONQUER.CPP (canonical TU) and confirmed
# all 7 TUs share an identical 3-line tcpip.h prefix: SOCKET (lines
# 96/105/144-146) and struct in_addr (line 130). Smallest-scope fix is
# the Winsock1 type taxonomy in linux/win32-stubs/winsock.h plus the
# transitive include from windows.h, mirroring TIM-9 (Win32 type
# taxonomy in windows.h) and TIM-46 (windows.h -> mmsystem.h
# transitive). Same fix incidentally clears the WSProto.h:101 bucket
# (4 TUs, identical SOCKET root cause).
#
# Pre baseline (pass 25, TIM-50-confirmed): 182 OK / 119 Fail / 301 Total.
# Top of pass-25 histogram: tcpip.h:96 = 7 TUs, WSProto.h:101 = 4 TUs,
# dde.h:97 = 3 TUs, mapedit.h:170 = 2 TUs, DLLInterface.h:616 = 2 TUs,
# wincomm.h:237 = 1 TU, then long tail of singletons.
#
# Same harness as passes 7-25 -- same flags, same shim regen, same
# stub set. Difference relative to pass 25 is upstream:
#   - TIM-51: linux/win32-stubs/winsock.h replaces the TIM-5 empty
#             placeholder with the minimum-viable Winsock1 type
#             taxonomy: SOCKET, INVALID_SOCKET, struct in_addr / IN_ADDR,
#             WSADATA, MAXGETHOSTSTRUCT. linux/win32-stubs/windows.h
#             gains `#include "winsock.h"` adjacent to the TIM-46
#             mmsystem.h pull, so every TU that already force-includes
#             msvc-compat.h reaches the taxonomy. Pure typedef + sibling
#             names; no shim restructuring, no flag changes.
#
# Pass progression (OK count):
#   pass 1 (no shim)                     : 37
#   pass 2 (lowercase symlinks)          : 44
#   pass 3 (shim + Win32 stubs)          : 73
#   pass 4 (TIM-8 + TIM-9)                : 81
#   pass 5 (TIM-11 + TIM-12)              : 81
#   pass 6 (TIM-14 + TIM-15)              : 88
#   pass 7 (TIM-17 + TIM-18)              : 88
#   pass 8 (TIM-20)                       : 88
#   pass 9 (TIM-22)                       : 88
#   pass 10 (TIM-24)                      : 92
#   pass 11 (TIM-26)                      : 92
#   pass 12 (TIM-28 + TIM-29)             : 95
#   pass 13 (TIM-31)                      : 95
#   pass 14 (TIM-34)                      : 95
#   pass 15 (TIM-36)                      : 95
#   pass 16 (TIM-38)                      : 95
#   pass 18 (TIM-40)                      : 95
#   pass 19 (TIM-42 + TIM-43)             : 95
#   pass 20 (TIM-44)                      : 95
#   pass 21 (TIM-45)                      : 95
#   pass 22 (TIM-46)                      : 95
#   pass 23 (TIM-47)                      : 95
#   pass 24 (TIM-49)                      : 95
#   pass 25 (TIM-50)                      : 182
#   pass 26 (TIM-51, this run)            : ?
#
# Measurement only -- source fix lives in TIM-51.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass26.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass26.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass26.attribution.txt"

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
    echo "# TIM-51 first compile attempt -- pass 26 (post TIM-51 winsock.h type taxonomy + windows.h transitive)"
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
