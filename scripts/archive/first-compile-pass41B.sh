#!/usr/bin/env bash
# TIM-141 measurement: pass 41B (DDRAW.CPP runtime port — drop IDirectDraw
# stub, gate live consumers).
#
# Context (pass-41A tip, commit b851231): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 2):
#   Edit A — REDALERT/WIN32LIB/DDRAW.H:
#     * Remove the `_NO_COM`-gated `struct IDirectDraw { ... }` stub
#       (CreateSurface, RestoreDisplayMode, Release, GetCaps,
#       WaitForVerticalBlank). Leave a forward decl `struct IDirectDraw;`
#       so `LPDIRECTDRAW` still types as a pointer to incomplete struct.
#     * IDirectDrawSurface stub stays (commit 3 graduates GBUFFER.CPP).
#   Edit B — REDALERT/WIN32LIB/DDRAW.CPP:
#     * Reset_Video_Mode: legacy DD teardown body now `#else`-arm of the
#       SDL2 path (was unconditional, would no longer compile).
#     * Get_Free_Video_Memory: Linux path returns `INT_MAX` (no fixed VRAM
#       ceiling under SDL2); MSVC path unchanged.
#     * Get_Video_Hardware_Capabilities: Linux path returns 0 (no hardware
#       acceleration claimed); MSVC path unchanged.
#     * Wait_Vert_Blank: Linux path is `SDL_Delay(1)`; real vsync is the
#       SDL renderer's job (created PRESENTVSYNC in Set_Video_Mode).
#   Edit C — REDALERT/STATS.CPP:
#     * Video-memory probe block (DDCAPS + DirectDrawObject->GetCaps)
#       wrapped under `#ifdef _MSC_VER`. FIELD_VIDEO_MEMORY just goes
#       unset on Linux for now (informational).
#   Edit D — REDALERT/WIN32LIB/GBUFFER.CPP:
#     * `DirectDrawObject->CreateSurface(...)` in DD_Init wrapped under
#       `#ifdef _MSC_VER`. VideoSurfacePtr stays nullable; downstream code
#       (Attach_DD_Surface, blit paths) still uses the IDirectDrawSurface
#       stub which is still in scope on Linux.
#
# Out-of-scope confirmation:
#   * CONQUER.CPP:3080-3131 (SetCooperativeLevel/SetDisplayMode/CreateSurface)
#     is inside `#ifdef MPEGMOVIE`, which is commented out in DEFINES.H:139.
#     Already dead code on the Linux build, no edit needed.
#   * DDRAW.CPP:526/529/538/551/566 are inside `#if (0)` (Set_Video_Mode
#     legacy block at lines 500-574). Already dead, no edit needed.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). The IDirectDraw stub had five
#                    method shapes; all live consumers identified by
#                    FoundingEngineer's review are gated by this pass.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress (especially DDRAW.CPP, STATS.CPP,
#   GBUFFER.CPP, or any TU that includes DDRAW.H and touches LPDIRECTDRAW
#   via a method): revert Edits A-D and hand back.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41B.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41B.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41B.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41B (drop IDirectDraw stub, gate live consumers)"
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
