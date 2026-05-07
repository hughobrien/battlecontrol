#!/usr/bin/env bash
# TIM-97 measurement: pass 40M.
#
# WINSTUB.CPP TEXT_* -> TXT_* alias drain in linux/win32-stubs/windows.h.
# WINSTUB.CPP:802 (Memory_Error_Handler) calls
#     WWMessageBox().Process(TEXT_MEMORY_ERROR, TEXT_ABORT, false);
# The TEXT_* spelling comes from REDALERT/LANGUAGE.H, which gates the
# string-table macros on `#ifdef ENGLISH` (and parallel GERMAN /
# FRENCH blocks). The original Westwood makefile injected the language
# define globally; our per-TU compile harness does not. TIM-84 fixed
# INIT.CPP / STARTUP.CPP / CONQUER.CPP via TU-local `#define ENGLISH 1`,
# but WINSTUB.CPP was left out. This pass solves the same parser
# problem with a header-only alias instead of an engine-source pin --
# WINSTUB.CPP only ever uses the int overload of WWMessageBox::Process,
# so a textual alias to the existing TXT_* int constants from
# CONQUER.H is enough to bind the call.
#
# Bundle (added to linux/win32-stubs/windows.h, after the TIM-96 GDI
# constants block, before the closing #endif):
#   - TEXT_MEMORY_ERROR  -> TXT_ERROR_ERROR  (compiler-suggested slot)
#   - TEXT_ABORT         -> TXT_ABORT        (canonical 1:1)
#
# Pre-survey on master 170a166 (post TIM-95 commit) confirmed
# WINSTUB.CPP first-error matches the TIM-97 issue claim:
#   REDALERT/WINSTUB.CPP:802:32 -> 'TEXT_MEMORY_ERROR' was not declared
#   REDALERT/WINSTUB.CPP:802:51 -> 'TEXT_ABORT' was not declared
# Both undeclareds are at the same call-site cluster (line 802), so the
# pass-40M scope includes both per the issue's "concurrent first-errors
# at the same call-site cluster" guidance.
#
# Pre baseline (post TIM-95, commit 170a166):
#   278 OK / 23 Fail / 301 Total.
#
# Realistic ceiling: 279 OK / 22 Fail (+1) -- WINSTUB.CPP fully clears
#   if no deeper first-error trips after the alias.
# Realistic floor: 278 OK / 23 Fail (+0) -- WINSTUB.CPP advances past
#   the TEXT_* cluster but trips a deeper non-text first-error
#   (ExitProcess @812 confirmed by the post-alias smoke compile -- a
#   kernel32 surface for a follow-on pass; out-of-scope here).
#
# Histogram diff target (WINSTUB only):
#   pre  -> WINSTUB.CPP:802:32 -> 'TEXT_MEMORY_ERROR' was not declared
#   post -> WINSTUB.CPP:812:9  -> 'ExitProcess' was not declared
#                                 (kernel32 surface; follow-on pass)
#
# Pass timeline so far:
#   pass 39  (TIM-74)                     : 267
#   pass 40A (TIM-75)                     : 268
#   pass 40B (TIM-76)                     : 268
#   pass 40C (TIM-78)                     : 268
#   pass 40D (TIM-79, IDirectDrawPalette) : 270 (worktree WIP)
#   pass 41  (TIM-77)                     : 269 -> 270 with TIM-79
#   pass 42  (TIM-80, SendMessage)        : 271 -> 272 with TIM-79
#   pass 43  (TIM-82, CountDownTimerClass): 274 (with TIM-79 WIP)
#   pass 45  (TIM-84, ENGLISH= pin)       : 274
#   pass 40F (TIM-85, Win32 stub bundle)  : 275
#   pass 40G (TIM-87, Win32 shape bundle) : 276
#   pass 40H (TIM-88, RAWFILE lseek)      : 277
#   pass 40I (TIM-89, WINSTUB mmio)       : 277
#   pass 40J (TIM-90, BMP8 wingdi structs): 278 (floor; histogram drain)
#   pass 40J' (TIM-91, _splitpath shim)   : 278
#   pass 40K (TIM-94, kernel32 cluster)   : 277
#   pass 40K' (TIM-92, GetModuleFileName) : 277
#   pass 40L (TIM-96, BMP8 GDI dispatch)  : 277 (floor; histogram drain)
#   pass 40L' (TIM-95, PostMessage drain) : 278 (pre-baseline tip)
#   pass 40M (TIM-97, this run)           : ?
#
# Measurement script -- the actual fix lives in linux/win32-stubs/
# windows.h.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass40M.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass40M.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass40M.attribution.txt"

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
    echo "# TIM-97 first compile attempt -- pass 40M (WINSTUB TEXT_*->TXT_* alias)"
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
