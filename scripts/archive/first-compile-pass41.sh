#!/usr/bin/env bash
# TIM-77 measurement: pass 41.
#
# Winsock cluster shim drain in linux/win32-stubs/winsock.h. The cluster
# surfaced post TIM-76 in WSPIPX.CPP / WSPROTO.CPP / WSPUDP.CPP. All
# entries are trivially-additive (inert inline returns, no-op bodies,
# integer macro constants), matching the proven TIM-67 audio-symbol /
# TIM-71 input-symbol / TIM-74-75 GDI-symbol shape.
#
# Functions added:
#   WSAStartup(WORD, LPWSADATA)                 -> 0
#   gethostname(char*, int)                     -> 0 (writes empty string)
#   gethostbyname(const char*)                  -> NULL
#   getsockopt(SOCKET,int,int,char*,int*)       -> 0
#   setsockopt(SOCKET,int,int,const char*,int)  -> 0
#   WSAGetLastError()                            -> 0
#
# Types added:
#   struct hostent  (h_name/h_aliases/h_addrtype/h_length/h_addr_list)
#
# Macros added:
#   WSAEWOULDBLOCK            10035
#   WSAGETSELECTEVENT(lParam) LOWORD(lParam)
#   WSAGETSELECTERROR(lParam) HIWORD(lParam)
#
# Pre baseline (post TIM-76, commit 4f856d3):
#   pass 40B (TIM-76) : 268 OK / 33 Fail / 301 Total.
#
# Realistic ceiling for THIS pass: 271 OK (+3) -- if WSPIPX, WSPROTO and
#   WSPUDP all reach OK.
# Realistic floor: 269 OK (+1) -- WSPROTO and WSPUDP cascade past the
#   winsock cluster into Win32 SendMessage (windows.h scope, out of TIM-77
#   scope), so only WSPIPX should reach OK; the other two advance to a
#   deeper non-winsock first-error.
#
# Pre-survey single-TU smoke (post-edit) confirmed:
#   WSPIPX.CPP   -> exit 0 (cluster cleared, no further first-error).
#   WSPROTO.CPP  -> first-error advanced to SendMessage (line 453).
#   WSPUDP.CPP   -> first-error advanced to SendMessage (line 280).
#
# Same harness as passes 7-40B -- same flags, same shim regen, same
# stubs. Difference relative to pass 40B: one bundled additive edit in
# linux/win32-stubs/winsock.h (TIM-77 cluster).
#
# Pass progression (OK count) -- recent tail:
#   pass 36 (TIM-69)                      : 264
#   pass 37 (TIM-70)                      : 264
#   pass 38 (TIM-71)                      : 266
#   pass 39 (TIM-74)                      : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 41  (TIM-77, this run)            : ???  (expected 269)
#
# Measurement script -- the actual fix lives in linux/win32-stubs/winsock.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41.attribution.txt"

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
    # Force-include the MSVC-extension shim (calling-convention macros,
    # __int64, _lrotl, ShapeFlags_Type promotion, etc.).
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
    echo "# TIM-77 first compile attempt -- pass 41 (winsock cluster shim)"
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
