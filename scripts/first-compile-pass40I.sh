#!/usr/bin/env bash
# TIM-89 measurement: pass 40I.
#
# Win32-stub-shape additive bundle in linux/win32-stubs/. Drains the
# WINSTUB.CPP GetLocalTime + mmio first-error cluster surfaced after
# TIM-87 (pass-40G) cleared DLGPROC.
#
# Bundle:
#   linux/win32-stubs/windows.h:
#     - GetLocalTime inert decl (sibling of TIM-85 GetSystemTime;
#       SYSTEMTIME typedef already in place)
#   linux/win32-stubs/mmsystem.h:
#     - HMMIO opaque-handle typedef
#     - MMIO_READ/MMIO_WRITE/MMIO_READWRITE/MMIO_CREATE/MMIO_PARSE/
#       MMIO_DELETE/MMIO_EXIST/MMIO_ALLOCBUF constants (canonical
#       Win32 SDK hex values from <mmsystem.h>)
#     - mmioOpen/mmioClose/mmioRead/mmioWrite/mmioSeek variadic-
#       template inert stubs (mmioOpen returns NULL handle, others
#       return 0 -- WINSTUB only consumes the success/failure branch
#       and the data is a cosmetic ASSERT.TXT log line)
#
# Pre baseline (post TIM-87, commit 4d800ea):
#   276 OK / 25 Fail / 301 Total.
#
# Realistic ceiling: 277 OK / 24 Fail (+1) -- WINSTUB.CPP clears.
# Realistic floor:   276 OK / 25 Fail (+0) -- WINSTUB advances to a
#   deeper first-error (TEXT_MEMORY_ERROR @802 cluster, engine text-
#   constant surface; cluster drained, no regressions).
# Smoke-confirmed per-TU after-stub first-error:
#   WINSTUB -> TEXT_MEMORY_ERROR @802 (engine text-constant cluster;
#              Memory_Error_Handler is non-multimedia / non-time-of-
#              day -- triggers the issue's "stop & hand back" rule).
#
# Same harness as passes 7-43/45/46/40G -- same flags, same shim
# regen, same stubs. Difference relative to pass 40G: one bundled
# additive edit spanning two stub headers (linux/win32-stubs/
# windows.h and linux/win32-stubs/mmsystem.h, TIM-89 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 40G (TIM-87, DLGPROC + bundle)   : 276
#   pass 40I (TIM-89, GetLocalTime + mmio): ???  (smoke +0 -> 276)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40I.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40I.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40I.attribution.txt"

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
    echo "# TIM-89 first compile attempt -- pass 40I (GetLocalTime + mmio cluster)"
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
