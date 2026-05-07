#!/usr/bin/env bash
# TIM-143 pass-43M: Umbrella A WIN32-elision survey + selective enable.
#
# Baseline: pass-42A tip (commit 21f0598) = OK 301 / FAIL 0 / Total 301.
#
# Goal: surface the iceberg behind the 301/0/301 milestone by enabling
# the four whole-body `#ifdef WIN32`-elided TUs (TCPIP, INTERNET, STATS,
# CCDDE) PLUS the two partial-body TUs that the issue calls out
# (NETDLG, NULLDLG). Measure the per-TU error histogram and cluster the
# new errors for the next wave.
#
# === Macro shape: per-TU -DWIN32 enable list (chosen) ===
#
# Three options were on the table:
#
#   (a) Global -DWIN32 across every TU.
#       Rejected: 76 of 301 TUs reference `#ifdef WIN32`; surfacing all
#       of them in one pass conflates the four whole-body bodies under
#       survey with cascade effects across the whole corpus and defeats
#       the point of the histogram.
#
#   (b) Per-TU enable list (CHOSEN).
#       Surgical: -DWIN32 fires only for the six target TUs. The
#       remaining 295 TUs build with byte-identical flags to pass-42A,
#       so any regression there would be a toolchain artifact, not the
#       survey. Zero source touches; rerunning without the enable list
#       restores the floor. Attribution is clean because every new FAIL
#       line carries one of the six target paths.
#
#   (c) Conditional include shim or per-TU `#define WIN32` patch.
#       Rejected: same blast radius as (b) but introduces a code edit
#       that has to be carried, reviewed, and unwound. Script-level
#       enable is the smaller change.
#
# === Target TUs ===
#
# Whole-body elided (named in the TIM-143 wake payload):
#   * REDALERT/TCPIP.CPP        — body 56..906 under #ifdef WIN32
#   * REDALERT/INTERNET.CPP     — body 50..end under #ifdef WIN32
#   * REDALERT/STATS.CPP        — body 41..end under #ifdef WIN32
#   * REDALERT/CCDDE.CPP        — body 52..end under #ifdef WIN32
#
# Partial-body unmasking (also called out by the wake payload):
#   * REDALERT/NETDLG.CPP       — 10 internal #ifdef WIN32 sites
#   * REDALERT/NULLDLG.CPP      — 20+ internal #ifdef WIN32 sites
#
# === Cascade-stop expectations ===
#
# Per the issue, cascade-stop discipline is suspended for this
# measurement pass. The compile floor is *expected* to drop — that is
# the iceberg this pass exists to map. We do NOT revert on FAIL; we
# capture the histogram and hand back for the next wave.
#
# Realistic ceiling: 301 OK / 0 FAIL — would mean the WIN32 bodies
#                    compile cleanly behind the existing shim. Highly
#                    unlikely; would imply the iceberg is empty.
# Realistic floor:   295 OK / 6 FAIL — every target TU surfaces at
#                    least one new error. Most likely outcome.
# Plausible worst:   <295 OK — partial-body WIN32 branches in NETDLG /
#                    NULLDLG cause new errors that don't bottom out at
#                    fmax-errors=20. Still useful data.
#
# Diff vs pass-42A: this script differs only in (1) per-TU -DWIN32
# enable for six target TUs, (2) artifact filenames. No source edits.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass43M.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass43M.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass43M.attribution.txt"
ENABLE_TRACE="$LOG_DIR/first-compile-pass43M.enable-trace.txt"

mkdir -p "$LOG_DIR"

SHIM_LOCK="$LOG_DIR/include-shim.lock"
exec 200>"$SHIM_LOCK"
flock -x 200

: > "$LOG_FILE"
: > "$SUMMARY_FILE"
: > "$ATTRIB_FILE"
: > "$ENABLE_TRACE"

CXX="${CXX:-g++}"

python3 "$REPO_ROOT/scripts/generate-include-shim.py" \
    --repo-root "$REPO_ROOT" \
    --shim-root "$SHIM_DIR" \
    --clean \
    --quiet

# Common flags (identical to pass-42A).
COMMON_FLAGS=(
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

# TUs to compile with -DWIN32 added on top of COMMON_FLAGS.
# Whole-body-elided + partial-body unmaskers per the wake payload.
WIN32_ENABLE_TUS=(
    "REDALERT/TCPIP.CPP"
    "REDALERT/INTERNET.CPP"
    "REDALERT/STATS.CPP"
    "REDALERT/CCDDE.CPP"
    "REDALERT/NETDLG.CPP"
    "REDALERT/NULLDLG.CPP"
)

is_win32_target() {
    local rel="$1"
    for t in "${WIN32_ENABLE_TUS[@]}"; do
        [[ "$rel" == "$t" ]] && return 0
    done
    return 1
}

shopt -s nullglob nocaseglob
SOURCES=( "$SRC_DIR"/*.cpp "$SRC_DIR"/WIN32LIB/*.cpp )
shopt -u nocaseglob

total=${#SOURCES[@]}
ok=0
fail=0
i=0
win32_ok=0
win32_fail=0

{
    echo "# TIM-143 pass-43M: per-TU WIN32 enable survey"
    echo "# host: $(uname -srm)"
    echo "# compiler: $($CXX --version | head -1)"
    echo "# date: $(date -Is)"
    echo "# sources: $total .cpp files"
    echo "# baseline: pass-42A OK 301 / FAIL 0 / Total 301"
    echo "# enable list (gets -DWIN32):"
    for t in "${WIN32_ENABLE_TUS[@]}"; do echo "#   $t"; done
    echo "# common flags: ${COMMON_FLAGS[*]}"
    echo
} >> "$LOG_FILE"

for src in "${SOURCES[@]}"; do
    i=$((i + 1))
    rel="${src#$REPO_ROOT/}"

    if is_win32_target "$rel"; then
        FLAGS=( -DWIN32 "${COMMON_FLAGS[@]}" )
        enabled=1
    else
        FLAGS=( "${COMMON_FLAGS[@]}" )
        enabled=0
    fi

    tu_log="$(mktemp)"

    {
        echo
        if (( enabled )); then
            echo "===== [$i/$total] $rel  (WIN32-ENABLED) ====="
        else
            echo "===== [$i/$total] $rel ====="
        fi
    } >> "$LOG_FILE"

    if "$CXX" "${FLAGS[@]}" "$src" >"$tu_log" 2>&1; then
        ok=$((ok + 1))
        if (( enabled )); then
            win32_ok=$((win32_ok + 1))
            echo "OK   $rel  WIN32-ENABLED" >> "$SUMMARY_FILE"
            echo "$rel -> WIN32-ENABLED OK" >> "$ENABLE_TRACE"
        else
            echo "OK   $rel" >> "$SUMMARY_FILE"
        fi
    else
        fail=$((fail + 1))
        if (( enabled )); then
            win32_fail=$((win32_fail + 1))
            echo "FAIL $rel  WIN32-ENABLED" >> "$SUMMARY_FILE"
        else
            echo "FAIL $rel" >> "$SUMMARY_FILE"
        fi
        primary=$(grep -m1 -E ': (fatal error|error):' "$tu_log" || true)
        if [[ -n "$primary" ]]; then
            if (( enabled )); then
                echo "$rel -> [WIN32] $primary" >> "$ATTRIB_FILE"
                echo "$rel -> WIN32-ENABLED FAIL: $primary" >> "$ENABLE_TRACE"
            else
                echo "$rel -> $primary" >> "$ATTRIB_FILE"
            fi
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
    echo "win32-enable target: ${#WIN32_ENABLE_TUS[@]}"
    echo "win32-target ok:     $win32_ok"
    echo "win32-target fail:   $win32_fail"
} | tee -a "$SUMMARY_FILE" >> "$LOG_FILE"

echo "Log:           $LOG_FILE"
echo "Summary:       $SUMMARY_FILE"
echo "Attribution:   $ATTRIB_FILE"
echo "Enable trace:  $ENABLE_TRACE"
echo "ok=$ok fail=$fail total=$total win32-target ok=$win32_ok fail=$win32_fail"
