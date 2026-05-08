#!/usr/bin/env bash
# TIM-149 pass-45C: case-fold fallback for the POSIX file-IO substrate.
#
# Baseline: pass-45B tip (commit ac3e002) -- floor 301/0/301 at that
# commit; current master tip is c4cf1c1 (TIM-151 pass-151) where the
# floor source set has grown to 308 TUs (305 OK / 0 FAIL / 308 total
# per the c4cf1c1 commit message). Pass-45C must keep that floor
# unchanged.
#
# === Diff vs pass-45B ===
#
# (1) MODIFIED linux/win32-stubs/posix_fileio.cpp ONLY:
#       * New helpers in anonymous namespace:
#         - try_open_case_folded(filename, flags, mode):
#             folds the basename portion (after the last '/' or '\\')
#             to uppercase, retries open(2); on ENOENT, folds to
#             lowercase, retries again. Directory portion left exactly
#             as the caller passed it.
#         - is_readonly_open(desired_access, creation_disposition):
#             returns true iff the open is read-only (no GENERIC_WRITE,
#             no create/truncate disposition). Case-fold fallback only
#             fires for read-only opens -- writes/creates must hit the
#             caller's exact path so save files don't get spuriously
#             redirected to a pre-existing case-fold match.
#       * RA_PosixFile_CreateFileA: after the literal-as-passed open
#         fails with ENOENT and is_readonly_open returns true, retry
#         via try_open_case_folded. All other open() failures (EACCES,
#         EISDIR, etc.) are returned as-is via INVALID_HANDLE_VALUE.
#       * No change to ReadFile / WriteFile / SetFilePointer /
#         GetFileSize / CloseHandle bodies.
#
# (2) No changes to windows.h, posix_fileio.h, or any engine TU.
#
# (3) Smoke-tested at /tmp/tim149/smoke before this floor run:
#       * Created /tmp/tim149/smoke/assets/redalert.mix (lowercase).
#       * Asked CreateFileA for "REDALERT.MIX" (uppercase basename,
#         lowercase directory mixed in via pass-through).
#       * Substrate found the file via the case-fold fallback;
#         GetFileSize + ReadFile recovered the full 20-byte payload.
#       * Asked for "NOPE.MIX" (genuinely missing); substrate
#         correctly returned INVALID_HANDLE_VALUE.
#
# === Why this pass + ordering note ===
#
# Per the runtime-path-survey §2: engine code asks for asset blobs by
# uppercase literal name (`"REDALERT.MIX"`, etc.) but Linux is case-
# sensitive. Without the case-fold fallback, a typical Linux distro
# install (lowercase blob basenames) fails every Init_Bootstrap_Mixfile
# call. This is the smallest commit that makes the asset path actually
# work end-to-end without engine-side path normalization.
#
# Original survey ordering had 45C = input pump fallback and 45D =
# case-fold. Reordered: case-fold first because (a) it's TU-local to
# my own substrate so zero conflict risk with the concurrent TIM-150/
# TIM-151/TIM-152 work that's been touching KEY.CPP / KEYBOARD.CPP /
# DDRAW.CPP, and (b) it directly unlocks the assertion paths in
# Init_Bootstrap_Mixfiles (INIT.CPP:3158/3169) that gate the playable
# milestone. Input-pump fallback now slots in as 45D (or later, if
# that's still hot from concurrent agents).
#
# === Cascade-stop expectations ===
#
# Target outcome: floor unchanged at 305/0/308 (whatever the c4cf1c1
# baseline says when re-measured; 45C does not add or remove TUs).
# Spot-check pass: BMP8.CPP and CONQUER.CPP (the two TUs that parse
# the substrate-bound windows.h decls under -fsyntax-only) -- both must
# stay OK.
#
# Realistic ceiling: 305/0/308. The change set is one new function +
# one new helper + one new branch in the existing CreateFileA body --
# all inside linux/win32-stubs/posix_fileio.cpp, which the floor
# measurement does NOT compile. The only way the floor could move is if
# windows.h were perturbed by a concurrent agent between heartbeats;
# spot-grep for `TIM-149 pass-45B` markers before staging.
#
# Anything else means an unrelated cascade -- revert + handback per the
# rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass45C.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass45C.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass45C.attribution.txt"

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
    echo "# TIM-149 first compile attempt -- pass 45C (case-fold fallback in POSIX file-IO substrate)"
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
