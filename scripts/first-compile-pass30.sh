#!/usr/bin/env bash
# TIM-56 measurement: pass 30.
#
# Third bundle-mode pass after the TIM-53 pivot. Pass-29 (TIM-55) cleared
# 8/8 primary-error sites at the shim layer and -- combined with the
# TIM-54 source-level edits that landed in the working tree -- raised
# the OK count from 184 to 207. The pass-29 attribution surfaced seven
# next-shot singletons that all clustered into the three already-touched
# headers (windows.h / winsock.h / mmsystem.h); pass-30 picks them off
# in a single shim-only sweep.
#
# Pre baseline:
#   - Stale issue-description figure (pre TIM-54 commit)   : 207 OK / 94 Fail
#   - Clean re-run of pass-29.sh against current tree
#     (post TIM-54 commit fdd497e, pre TIM-56 shim edits) : 249 OK / 52 Fail
#
# The 207 baseline cited in TIM-56 was computed against the working tree
# while TIM-54's source-level edits were uncommitted; commit fdd497e
# ("TIM-54: ... pass-29-C OK 203->249 (+46)") landed those edits and
# brings the true pass-29 baseline to 249. We use 249 as the reference
# for pass 30's per-fix verdict and OK/Fail diff.
#
# Same harness as passes 7-29 -- same flags, same shim regen, same
# stub set. Difference relative to pass 29 is upstream-only (pure
# Group A shim taxonomy gaps; no shim restructuring, no flag changes,
# no engine source edits):
#   - TIM-56 fix 1: linux/win32-stubs/windows.h gains the WIN32_FIND_DATA
#                   directory-enumeration record (with FILETIME-based
#                   timestamps, MAX_PATH-sized cFileName, and 14-byte
#                   cAlternateFileName). Targets SESSION.CPP:1325 + 1446.
#   - TIM-56 fix 2: linux/win32-stubs/windows.h gains the FILE_ATTRIBUTE_*
#                   bitflag set (READONLY/HIDDEN/SYSTEM/DIRECTORY/ARCHIVE
#                   /NORMAL/TEMPORARY) consumed by SESSION.CPP file-mask
#                   tests at lines 1328 and 1448, and by the existing
#                   CreateFile call sites in RAWFILE/CONQUER/WINSTUB.
#   - TIM-56 fix 3: linux/win32-stubs/windows.h gains the MessageBox
#                   style-flag set (MB_OK / MB_OKCANCEL / MB_YESNO /
#                   MB_RETRYCANCEL / MB_ICONSTOP / MB_ICONQUESTION /
#                   MB_ICONEXCLAMATION / MB_ICONASTERISK / MB_DEFBUTTON*
#                   / MB_*MODAL). Targets WIN32LIB/DDRAW.CPP:90 plus the
#                   STARTUP/BMP8/MPMGRW/W95TRACE call sites.
#   - TIM-56 fix 4: linux/win32-stubs/windows.h gains the ShowWindow
#                   nCmdShow set (SW_HIDE / SW_NORMAL / SW_SHOW(NORMAL|
#                   MAXIMIZED|MINIMIZED|NA|MINNOACTIVE|NOACTIVATE) /
#                   SW_MINIMIZE / SW_RESTORE / SW_MAXIMIZE). Targets
#                   STARTUP.CPP:180 plus the CCDDE/INTERNET/MCIMOVIE/
#                   NETDLG/WOLAPIOB ShowWindow callers.
#   - TIM-56 fix 5: linux/win32-stubs/winsock.h gains the sockaddr_in
#                   IPv4 socket-address struct (sin_family, sin_port,
#                   sin_addr layered over the stub in_addr, sin_zero).
#                   Targets WSPUDP.CPP:146.
#   - TIM-56 fix 6: linux/win32-stubs/winsock.h gains socket-type and
#                   address-family macros (SOCK_STREAM / SOCK_DGRAM /
#                   SOCK_RAW; AF_UNSPEC / AF_INET / AF_IPX / AF_NS).
#                   Targets WSPIPX.CPP:98 + WSPUDP.CPP:166.
#   - TIM-56 fix 7: linux/win32-stubs/winsock.h gains the WSAAsyncSelect
#                   event-type set (FD_READ / FD_WRITE / FD_OOB /
#                   FD_ACCEPT / FD_CONNECT / FD_CLOSE). Targets
#                   WSPROTO.CPP:187.
#   - TIM-56 fix 8: linux/win32-stubs/mmsystem.h gains the multimedia
#                   timer event-type set (TIME_ONESHOT / TIME_PERIODIC /
#                   TIME_CALLBACK_FUNCTION / TIME_CALLBACK_EVENT_SET /
#                   TIME_CALLBACK_EVENT_PULSE / TIME_KILL_SYNCHRONOUS).
#                   Targets WIN32LIB/TIMERINI.CPP:122.
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
#   pass 26 (TIM-51)                      : 184
#   pass 27 (TIM-52)                      : 184
#   pass 29 (TIM-55 shim portion)         : 207  -- pre-TIM-54 commit
#   pass 29-C (post TIM-54 commit fdd497e): 249  -- clean baseline for pass 30
#   pass 30 (TIM-56, this run)            : 249  -- ΔOK 0; 7 candidate sites
#                                                  cleared then fragmented to
#                                                  function-not-declared on
#                                                  the same TU (FindFirstFile,
#                                                  MessageBox, socket, NSPROTO_IPX,
#                                                  WSAAsyncSelect, timeSetEvent,
#                                                  TEXT_NO_RAM)
#
# Measurement only -- source fixes live in TIM-56.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass30.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass30.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass30.attribution.txt"

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
    echo "# TIM-56 first compile attempt -- pass 30 (post TIM-56 bundle-mode shim sweep: 7 singleton fixes across windows.h/winsock.h/mmsystem.h)"
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
