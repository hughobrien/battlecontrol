#!/usr/bin/env bash
# TIM-141 measurement: pass 41C (DDRAW.CPP runtime port — drop
# IDirectDrawSurface stub, gate live consumers).
#
# Context (pass-41B tip, commit 625f95d): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 3):
#   Edit A — REDALERT/WIN32LIB/DDRAW.H:
#     * Remove the `_NO_COM`-gated `struct IDirectDrawSurface { ... }`
#       stub (GetBltStatus, Blt, Lock, Unlock, AddAttachedSurface,
#       Release, SetPalette, Restore). Leave a forward decl
#       `struct IDirectDrawSurface;` so `LPDIRECTDRAWSURFACE` still
#       types as a pointer to incomplete struct.
#     * IDirectDrawPalette already a forward decl from commit 1.
#     * IDirectDraw already a forward decl from commit 2.
#   Edit B — REDALERT/WIN32LIB/GBUFFER.CPP:
#     * Attach_DD_Surface body wrapped under `#ifdef _MSC_VER`
#       (AddAttachedSurface).
#     * Un_Init Unlock/Remove_DD_Surface/Release block wrapped under
#       `#ifdef _MSC_VER`. VideoSurfacePtr is always NULL on Linux
#       because DD_Init's CreateSurface is MSVC-gated already.
#     * GraphicBufferClass::Lock VideoSurfacePtr->Lock while-loop
#       wrapped under `#ifdef _MSC_VER`. Lock-buffer wiring deferred
#       to commit 4 (sourcing Buffer/Pitch from SDL surface).
#     * GraphicBufferClass::Unlock VideoSurfacePtr->Unlock branch
#       wrapped under `#ifdef _MSC_VER` with an early-return-FALSE
#       Linux fallback.
#     * DD_Linear_Blit_To_Linear hardware Blt return wrapped under
#       `#ifdef _MSC_VER`; Linux returns DD_OK.
#   Edit C — REDALERT/WIN32LIB/GBUFFER.H:
#     * GraphicViewPortClass::Fill_Rect DD fast-path (GetBltStatus
#       + Blt) wrapped under `#ifdef _MSC_VER`. Linux always falls
#       through to Buffer_Fill_Rect / Lock+Unlock CPU path.
#   Edit D — REDALERT/WIN32LIB/DDRAW.CPP:
#     * Wait_Blit body wrapped under `#ifdef _MSC_VER`. SDL renderer's
#       PRESENTVSYNC handles vsync on Linux.
#     * SurfaceMonitorClass::Restore_Surfaces inner Surface[i]->Restore
#       call wrapped under `#ifdef _MSC_VER`. SDL2 doesn't lose
#       surfaces on focus loss; Linux falls through to the
#       Misc_Focus_Restore_Function notification path.
#
# Out-of-scope confirmation (per FoundingEngineer's review):
#   * CONQUER.CPP:3137/3165/3178 — inside `#ifdef MPEGMOVIE`, which is
#     commented out in DEFINES.H:139. Already dead.
#   * DDRAW.H:655-774 / DSOUND.H:220-229 Lock/Unlock/Restore macros are
#     `#define`s gated by `_NO_COM`/`_WIN32`, never expanded on Linux.
#   * DDRAW.CPP:851 (PaletteSurface->SetPalette in Set_DD_Palette) is
#     already inside the commit-1 `#else _MSC_VER` arm.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). All nine live IDirectDrawSurface
#                    method-call sites identified by FoundingEngineer's
#                    inventory are gated by this pass.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress (especially DDRAW.CPP, GBUFFER.CPP,
#   or any TU that includes GBUFFER.H and instantiates Fill_Rect): revert
#   Edits A-D and hand back. If the regression points at the deferred
#   Lock-buffer wiring (commit 4 territory) — `Buffer`/`Pitch`/`Offset` not
#   set on Linux Lock() return — flag it explicitly and hand back; do not
#   absorb the scope.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41C.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41C.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41C.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41C (drop IDirectDrawSurface stub, gate live consumers)"
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
