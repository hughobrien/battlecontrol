#!/usr/bin/env bash
# TIM-149 pass-45A: post-substrate runtime-path umbrella, opening pass.
# File-IO substrate seam declared in linux/win32-stubs/posix_fileio.h.
# Header only; mirrors TIM-148 pass-44A (audio seam) and TIM-141 pass-41A
# (DDRAW seam). Real bodies land in pass-45B.
#
# Baseline: pass-44F tip (commit d9d674b) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-44F ===
#
# (1) NEW linux/win32-stubs/posix_fileio.h:
#       * Forward declarations for the six POSIX-backed file-IO entry
#         points (RA_PosixFile_CreateFileA / CloseHandle / ReadFile /
#         WriteFile / SetFilePointer / GetFileSize) that pass-45B will
#         implement.
#       * !_MSC_VER guarded -- MSVC builds are byte-identical.
#       * NOT included by any engine TU in 45A. The header is the public
#         surface for the future substrate .cpp; wiring through windows.h
#         (replacing the variadic-template stubs at windows.h:993-1001)
#         is the second deliverable in pass-45B, paired with the body
#         landing.
#       * HANDLE encoding contract documented inline (heap-allocated
#         descriptor, Win32 sentinel INVALID_HANDLE_VALUE preserved).
#
# (2) No edits to any existing TU. windows.h CreateFile / CloseHandle
#     stubs unchanged from pass-44F. RAWFILE.CPP / BMP8.CPP / CONQUER.CPP
#     / NULLMGR.CPP / WINSTUB.CPP all unchanged.
#
# (3) No new TUs in the *.cpp glob. The header is in linux/win32-stubs/,
#     not REDALERT/, so the compile-floor source set is identical to
#     pass-44F.
#
# === Closes survey-side of the umbrella ===
#
# The runtime-path-survey document (key `runtime-path-survey` on
# TIM-149) covers all six survey questions: first-runtime-exercise
# gating, asset/file-IO, pump cadence, init order, Speak deferral, and
# residual quirks. Pass-45A is the smallest implementation step that
# materially advances toward the playable milestone -- it locks in the
# file-IO substrate's public ABI before any engine TU starts depending
# on it.
#
# === Why this is the right first step ===
#
# Per the survey §2: under the link build (-DWIN32),
# RawFileClass::Open hits CreateFile, gets INVALID_HANDLE_VALUE, and
# every asset load fails. Until file-IO lights up, no runtime exercise
# of audio/graphics/input is possible end-to-end -- the binary won't
# even reach Audio_Init successfully because STARTUP.CPP::main opens
# REDALERT.INI at line 461, well before any other substrate is touched.
# Wiring real POSIX bodies is the unblocker; declaring the seam first
# (this pass) is the smallest commit that doesn't perturb anything.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Spot-check on STARTUP.CPP, RAWFILE.CPP, AUDIO.CPP -- all OK pre-floor-run
# (header isn't transitively pulled by any of them).
#
# Realistic ceiling: 301/0/301. The change is a single new header, not
# included anywhere yet. Anything else means an unrelated cascade --
# revert + handback per the rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45A.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45A.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45A.attribution.txt"

mkdir -p "$LOG_DIR"

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
    echo "# TIM-149 first compile attempt -- pass 45A (file-IO substrate seam header; opens umbrella)"
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
