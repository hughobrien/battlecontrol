#!/usr/bin/env bash
# TIM-141 measurement: pass 41D (DDRAW.CPP runtime port — SDL2 lock-buffer
# wiring for GraphicBufferClass::Lock on the Linux primary surface).
#
# Context (pass-41C tip, commit 69eaf18): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 4):
#   Edit A — REDALERT/WIN32LIB/DDRAW.H:
#     * Linux-only extern decls for SDL primary-surface accessors:
#       `SDL_Has_Primary_Surface`, `SDL_Get_Primary_Pixels`,
#       `SDL_Get_Primary_Pitch`. Keeps <SDL.h> out of every TU
#       that includes DDRAW.H or GBUFFER.H.
#   Edit B — REDALERT/WIN32LIB/DDRAW.CPP:
#     * Definitions for the three accessors next to the
#       file-static SDL_PrimarySurface. Indexed SDL surfaces have
#       CPU-resident pixels — no SDL_LockSurface needed for the
#       software-rendered path.
#   Edit C — REDALERT/WIN32LIB/GBUFFER.H:
#     * New Linux-only `BOOL IsSDLPrimary` member on
#       GraphicBufferClass. MSVC layout untouched (gated on
#       `#ifndef _MSC_VER`); marks the GBC bound to the SDL
#       primary screen.
#   Edit D — REDALERT/WIN32LIB/GBUFFER.CPP:
#     * GraphicBufferClass default ctor and `Init()` initialise
#       `IsSDLPrimary = FALSE` (Linux-only).
#     * `DD_Init()` flips `IsSDLPrimary = SDL_Has_Primary_Surface()`
#       inside the existing `GBC_VISIBLE & flags` branch.
#     * `Lock()` gains a Linux-only fast path that, when
#       `IsSDLPrimary` is true, sources `Offset` from
#       `SDL_Get_Primary_Pixels()` and `Pitch` from
#       `SDL_Get_Primary_Pitch() - Width`, mirroring the MSVC
#       `DDLOCK_WAIT` DD_OK branch (Offset is the live pixel
#       pointer; Buffer is left untouched, just like the MSVC
#       path). Bumps `LockCount` and `TotalLocks`.
#     * `Unlock()` mirrors with a Linux-only branch that sets
#       `Offset = NOT_LOCKED` on the final pop and decrements
#       `LockCount`. No paired SDL_UnlockSurface — the indexed
#       surface is CPU-resident.
#
# Out-of-scope confirmation (per FoundingEngineer's commit-4 spec):
#   * Present pump (SDL_BlitSurface → SDL_UpdateTexture →
#     SDL_RenderCopy → SDL_RenderPresent). Separate later commit.
#   * Palette translation polish (already wired in DDRAW.CPP
#     Set_DD_Palette → SDL_SetPaletteColors).
#   * DSOUND / DINPUT / VQA work.
#   * Touching Fill_Rect or DD_Linear_Blit_To_Linear (correctly
#     dead-Linux today; will stay that way until present pump lands).
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). Edits are gated #ifndef _MSC_VER
#                    on the active TUs (DDRAW.CPP, GBUFFER.CPP) and add a
#                    Linux-only member behind #ifndef _MSC_VER on GBUFFER.H,
#                    so the MSVC path is byte-for-byte unchanged.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress: revert Edits A-D and hand
#   back. If a single sibling site needs the same gate (e.g. another
#   GBC ctor leaks an uninitialized IsSDLPrimary), fold the sibling in
#   only if it's a single-line addition matching the same pattern.
#   Anything broader gets its own pass.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41D.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41D.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41D.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41D (SDL2 lock-buffer wiring for primary GBC)"
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
