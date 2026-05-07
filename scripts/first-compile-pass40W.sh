#!/usr/bin/env bash
# TIM-109 measurement: pass 40W (NOSEQCON.CPP Send arity fix).
#
# Two call sites in REDALERT/NOSEQCON.CPP invoke ConnectionClass::Send
# with 2 args, but connect.h:211 declares it as a 4-arg pure virtual:
#
#   virtual int Send(char *buf, int buflen, void *extrabuf, int extralen) = 0;
#
# Fix: pass NULL/0 for the unused extra-buffer pair, plus an explicit
# (int) cast on sizeof(CommHeaderType) at :408 since the second arg
# is int and sizeof() is size_t (LP64 long unsigned int).
#
#   :408  before: Send ((char *)&ackpacket, sizeof(CommHeaderType));
#         after:  Send ((char *)&ackpacket, (int)sizeof(CommHeaderType), NULL, 0);
#
#   :592  before: Send (send_entry->Buffer, send_entry->BufLen);
#         after:  Send (send_entry->Buffer, send_entry->BufLen, NULL, 0);
#
# Sibling SEQCONN.CPP has the same 2-arg shape and same arity bug, so
# there is no canonical 4-arg pattern to copy from. NULL/0 matches the
# unused-extrabuf pattern in the concrete Send implementations
# (NULLCONN, IPXCONN ignore extrabuf/extralen entirely).
#
# Standalone smoke compile of NOSEQCON.CPP (against the pass-40V-tip
# shim) exits with no diagnostics.
#
# Pre baseline (pass-40V tip, commit e2d4e01):
#   285 OK / 16 Fail / 301 Total.
#
# Realistic ceiling: 286 OK / 15 Fail (+1) -- NOSEQCON.CPP graduates.
# Realistic floor:   285 OK / 16 Fail (+0) -- a third call site or
#   new in-file cascade surfaces (stop-and-hand-back per TIM-105).
#
# Histogram diff target:
#   pre  -> NOSEQCON.CPP:408 no matching function for ConnectionClass::Send
#   post -> NOSEQCON.CPP gone from FAIL list (ceiling), or
#           a new in-file cascade (floor).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40W.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40W.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40W.attribution.txt"

mkdir -p "$LOG_DIR"

# TIM-112: serialise pass-40W invocations end-to-end via flock.
#
# generate-include-shim.py --clean unlinks every symlink under
# build/include-shim/{redalert,win32lib} and recreates them. If a
# second invocation runs --clean while a first invocation is still in
# its compile loop, the first invocation transiently sees missing
# include-shim outputs (manifested historically as "fatal error: ...:
# No such file or directory" on TUs like SMUDGE.CPP and SOUNDDLG.CPP).
#
# Locking only the regen call is insufficient: the lock would be
# released before the compile loop, leaving the symlinks vulnerable
# to a follow-up invocation's --clean. Holding the lock for the whole
# script means concurrent or rapid back-to-back invocations queue
# end-to-end, and the compile loop runs against a stable shim tree.
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
    echo "# TIM-109 first compile attempt -- pass 40W (NOSEQCON.CPP Send arity fix)"
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
