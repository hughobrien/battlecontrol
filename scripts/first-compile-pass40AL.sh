#!/usr/bin/env bash
# TIM-133 measurement: pass 40AL (MPLIB.CPP + MPMGRD.CPP Watcom DOS shim-decl bundle).
#
# Context (post TIM-132 tip, commit 9bf3d71): OK 296 / FAIL 5 / Total 301.
# Five residual FAILs: DLLInterface*, MPLIB, MPMGRD, DDRAW.
#
# This pass: enrich 6 stub headers under linux/win32-stubs/ to provide
# missing Watcom DOS / MPath VxD-chunnel declarations for MPLIB+MPMGRD:
#   1. i86.h:      add int386/int386x no-op macros
#   2. mgenord.h:  add MGENVXD_* / DPMIAPI_POST_WINDOWS_ORD macros
#   3. rtq.h:      add complete RTQ_NODE struct (rtqUpCtr + rtqDatum)
#   4. mplib.h:    add Mgen* / Yield / PostWindowsMessage decls
#   5. mplpc.h:    add LPCGetMPAddr() -> int
#   6. services.h: add TGAMEDEF struct + GetGameDef() decl
#
# First errors at pass-40AK tip:
#   MPLIB.CPP:35:  error: 'int386' was not declared in this scope
#   MPMGRD.CPP:62: error: 'MGenGetMasterNode' was not declared in this scope
#
# Realistic ceiling: 298 OK / 3 FAIL (+2) — MPLIB + MPMGRD graduate.
# Realistic floor:   297 OK / 4 FAIL (+1) — one TU graduates.
#
# Histogram diff target:
#   pre  -> MPLIB.CPP:35:  'int386' was not declared in this scope
#         , MPMGRD.CPP:62: 'MGenGetMasterNode' was not declared in this scope
#   post -> MPLIB.CPP  gone from FAIL list (ceiling)
#         , MPMGRD.CPP gone from FAIL list (ceiling)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40AL.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40AL.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40AL.attribution.txt"

mkdir -p "$LOG_DIR"

# Serialise pass-40AL invocations end-to-end via flock.
SHIM_LOCK="$LOG_DIR/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

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
    echo "# TIM-133 first compile attempt -- pass 40AL (MPLIB+MPMGRD Watcom DOS shim-decl bundle)"
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
