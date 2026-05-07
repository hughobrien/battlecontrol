#!/usr/bin/env bash
# TIM-147 pass-43N: Umbrella A-prime cluster A1+A2+A3 graduation.
#
# Baseline: pass-43M (commit 407a133) = OK 299 / FAIL 2 / Total 301
#           with WIN32-target ok 4 / fail 2.
#           FAILs: INTERNET.CPP (FindWindow), TCPIP.CPP (accept).
#
# Goal: graduate INTERNET.CPP and TCPIP.CPP from FAIL→OK at the per-TU
# `-DWIN32` enable so the compile floor returns to 301 / 0 / 301 with
# the four whole-body-elided TUs (CCDDE, INTERNET, STATS, TCPIP) all
# live. Cascade-stop discipline is back in force for this pass.
#
# === Diff vs pass-43M ===
#
# (1) Enable list: dropped NETDLG.CPP and NULLDLG.CPP. They are NOT
#     in scope for TIM-147 (the issue is explicit on this) and 43M
#     already showed they OK out behind the existing shim. The four
#     whole-body TUs are the ones we want to keep on a -DWIN32 floor;
#     NETDLG/NULLDLG only had partial-body sites that didn't add value
#     to 43M's FAIL set.
#
# (2) Shim adds in linux/win32-stubs/{windows.h, winsock.h}: A1
#     (FindWindow), A2 (accept / inet_addr / inet_ntoa / INADDR_NONE
#     / IPPROTO_TCP / TCP_NODELAY / PF_INET / hostent::h_addr), A3
#     (WSAAsyncGetHostByAddr / WSAAsyncGetHostByName /
#     WSAGETASYNCERROR / WSAECONNRESET).
#
# (3) Artifact filenames bumped from pass-43M to pass-43N.
#
# === Cascade-stop expectations (back on) ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301 with WIN32-target ok 4
# / fail 0. Any non-target TU regression triggers revert + handback
# per the standard cascade-stop rule. INTERNET / TCPIP must each go
# from FAIL→OK; if either stays FAIL, hand back for histogram triage.
#
# Realistic ceiling: 301 / 0 / 301, win32-target 4/0. Target outcome.
# Plausible:         300 / 1 / 301 — one of INTERNET/TCPIP graduates,
#                    the other surfaces a residual symbol. Acceptable
#                    landing for a follow-up pass; not target.
# Worst:             cascade into siblings (sub-299). Revert + triage.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass43N.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass43N.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass43N.attribution.txt"
ENABLE_TRACE="$LOG_DIR/first-compile-pass43N.enable-trace.txt"

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
# Four whole-body-elided TUs from the TIM-143 wake payload.
# NETDLG.CPP and NULLDLG.CPP are intentionally NOT here (out of scope
# for TIM-147 per the issue body).
WIN32_ENABLE_TUS=(
    "REDALERT/TCPIP.CPP"
    "REDALERT/INTERNET.CPP"
    "REDALERT/STATS.CPP"
    "REDALERT/CCDDE.CPP"
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
    echo "# TIM-147 pass-43N: cluster A1+A2+A3 graduate INTERNET+TCPIP"
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
