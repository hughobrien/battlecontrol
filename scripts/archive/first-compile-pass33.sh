#!/usr/bin/env bash
# TIM-66 measurement: pass 33.
#
# Group C source-level pass on the parser:expected class-name residual
# bucket inventoried in TIM-65's post-pass-32 hand-back. Two WIN32LIB TUs
# (MOUSEWW.CPP, WRITEPCX.CPP) first-error at the same site --
# build/include-shim/redalert/mapedit.h:170:1 -- where MapEditClass is
# declared as `: public MouseClass` but MouseClass is incomplete because
# the recursive include chain (mouse.h:39 -> scroll.h -> help.h -> tab.h
# -> sidebar.h -> function.h -> mapedit.h) reaches mapedit.h while
# mouse.h is still mid-parse. TIM-66 lands a single-site source fix at
# REDALERT/MOUSE.H + REDALERT/MAPEDIT.H that:
#   - forward-declares MouseClass after the MOUSE_H guard so externs.h
#     (extern MouseClass Map) parses during the recursive chain;
#   - publishes a MOUSECLASS_DEFINED sentinel at the end of mouse.h once
#     the class body is complete;
#   - guards the MapEditClass body in mapedit.h on MOUSECLASS_DEFINED so
#     it is skipped during the recursive chain (and a forward decl of
#     MapEditClass is provided unconditionally for externs.h:196 under
#     SCENARIO_EDITOR).
#
# Pre baseline:
#   pass 32 (TIM-65) post-commit 480574d : 254 OK / 47 Fail / 301 Total.
#
# Difference relative to pass 31 is upstream-only (Group A type/macro
# bundle in two already-touched headers; no shim restructuring, no
# flag changes, no engine source edits):
#   - TIM-63 fix 1: linux/win32-stubs/windows.h gains the named HRESULT
#                   error-code constants E_FAIL / E_INVALIDARG /
#                   E_OUTOFMEMORY / E_NOTIMPL. Targets WIN32LIB/DDRAW.CPP
#                   via build/include-shim/win32lib/ddraw.h:2623/2660 and
#                   the matching DDERR_OUTOFMEMORY/DDERR_UNSUPPORTED
#                   aliases. Standard <winerror.h> values.
#   - TIM-63 fix 2: linux/win32-stubs/winsock.h gains INADDR_ANY (0u)
#                   wildcard IPv4 bind address. Targets WSPUDP.CPP:168
#                   `addr.sin_addr.s_addr = htonl(INADDR_ANY)`.
#   - TIM-63 fix 3: linux/win32-stubs/winsock.h gains the SOL_SOCKET +
#                   SO_BROADCAST/SO_LINGER/SO_SNDBUF/SO_RCVBUF/SO_ERROR
#                   socket-option-name set. Pre-positions for the pass-33
#                   setsockopt/getsockopt function-shim bundle (referenced
#                   at WSPUDP.CPP:219, WSPIPX.CPP:237, WSPROTO.CPP:536/
#                   538/569/580). Standard <winsock.h> values.
#   - TIM-63 fix 4: linux/win32-stubs/winsock.h gains the IPX_PTYPE /
#                   IPX_FILTERPTYPE option-name macros. Pre-positions for
#                   pass-33 setsockopt(NSPROTO_IPX, IPX_*, ...) calls at
#                   WSPIPX.CPP:247/258. Standard <wsnwlink.h> values.
#
# Same harness as passes 7-31 -- same flags, same shim regen, same
# stubs. Difference is only the type/macro additions above.
#
# Reference: TIM-59 measurement (pass 31).
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
#   pass 31 (TIM-59 + TIM-61)             : 253  -- ΔOK +4 vs pass-30 (SESSION
#                                                  cleared by FindFirstFile fn
#                                                  shim; CCINI/SCENARIO cleared
#                                                  by TIM-61 min/max ADL fix).
#   pass 31-rebaselined (post TIM-62 +
#                        TIM-65)            : 254  -- ΔOK +1 vs pass-31 (FONT.CPP
#                                                  cleared by TIM-65 sys\stat.h
#                                                  source-level normalization).
#   pass 32 (TIM-63, working tree)        : 254  -- ΔOK 0 vs rebaselined; 4
#                                                  candidate sites cleared then
#                                                  fragmented or no-op'd:
#                                                    DDRAW.CPP : E_FAIL ->
#                                                                RestoreDisplayMode
#                                                                (deeper COM stub
#                                                                gap, defer to C);
#                                                    WSPUDP.CPP: INADDR_ANY ->
#                                                                gethostname (fn
#                                                                shim, queue p33);
#                                                    WSPROTO.CPP/WSPIPX.CPP: SO_*
#                                                                / IPX_* singletons
#                                                                pre-positioned but
#                                                                blocked on
#                                                                getsockopt/setsockopt
#                                                                /WSAStartup fn shims
#                                                                (queue pass-33).
#   pass 33 (TIM-66, this run)            : 254  -- ΔOK 0 vs pre-baseline.
#                                                  parser:expected class-name
#                                                  bucket fully drained (2/2):
#                                                    MOUSEWW.CPP -> fragmented to
#                                                                   InitializeCriticalSection
#                                                                   (Win32 critical-
#                                                                   section fn shim);
#                                                    WRITEPCX.CPP -> fragmented to
#                                                                    GetCDClass (missing
#                                                                    type, externs.h:157).
#
# Measurement only -- TIM-66 source fixes live in REDALERT/MOUSE.H +
# REDALERT/MAPEDIT.H. The working tree also carries the TIM-63 stub
# additions (linux/win32-stubs/windows.h E_*, winsock.h INADDR_ANY/SO_*/
# IPX_*) that pre-positioned pass-32 but were never committed; those
# remain queued behind their function-shim follow-ups.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass33.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass33.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass33.attribution.txt"

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
    echo "# TIM-66 first compile attempt -- pass 33 (post TIM-66 source-level parser:expected class-name drain at REDALERT/MOUSE.H + REDALERT/MAPEDIT.H; carries TIM-63 stub deltas in working tree)"
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
