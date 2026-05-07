#!/usr/bin/env bash
# TIM-141 measurement: pass 41E (DDRAW.CPP runtime port — SDL2 present
# pump in Wait_Vert_Blank).
#
# Context (pass-41D tip, commit 652addc): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 5):
#   Edit A — REDALERT/WIN32LIB/DDRAW.CPP (file-static block):
#     * New file-statics next to SDL_PrimarySurface for the present-pump
#       caches: `SDL_PrimaryTexture` (ARGB8888 streaming), `SDL_PrimaryARGB`
#       (ARGB8888 CPU intermediate), `SDL_CachedW`/`SDL_CachedH` for
#       size-change detection, and `SDL_FirstPresentDone` to gate the
#       SDL_ShowWindow once-per-session call.
#   Edit B — REDALERT/WIN32LIB/DDRAW.CPP (Wait_Vert_Blank, ~line 785):
#     * Replaces the `SDL_Delay(1)` placeholder with a present pump:
#         - Bails fast if `SDL_PrimarySurface == nullptr` or
#           `SDL_VideoRenderer == nullptr`.
#         - Lazily creates / size-recreates the cached texture and ARGB
#           intermediate from `SDL_PrimarySurface->w/h`.
#         - `SDL_BlitSurface(SDL_PrimarySurface, NULL, SDL_PrimaryARGB, NULL)`
#           — palette-aware indexed -> ARGB conversion using the palette
#           populated by Set_DD_Palette.
#         - `SDL_UpdateTexture` -> `SDL_RenderClear` -> `SDL_RenderCopy`
#           -> `SDL_RenderPresent`. Vsync rides
#           `SDL_RENDERER_PRESENTVSYNC` set in Set_Video_Mode.
#         - First successful present -> `SDL_ShowWindow(SDL_VideoWindow)`
#           once. Window was created `SDL_WINDOW_HIDDEN` at
#           DDRAW.CPP:505.
#   Edit C — REDALERT/WIN32LIB/DDRAW.CPP (Reset_Video_Mode):
#     * Frees `SDL_PrimaryTexture` and `SDL_PrimaryARGB` *before* the
#       renderer (resource ordering — texture is renderer-owned), then
#       resets `SDL_CachedW/H` and `SDL_FirstPresentDone`. The MSVC
#       DirectDraw branch is byte-for-byte unchanged.
#
# Out-of-scope confirmation (per commit-5 spec):
#   * Palette polish — Set_DD_Palette already wires SDL_SetPaletteColors.
#   * Fill_Rect / DD_Linear_Blit_To_Linear audits — defer to a later pass
#     once present-pump-visible regressions can drive the change list.
#   * SDL_Event pump (input/quit) — DINPUT lane.
#   * DSOUND / VQA — separate seams.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). All edits live in DDRAW.CPP
#                    behind the existing `#ifndef _MSC_VER` block; MSVC
#                    DirectDraw paths in Wait_Vert_Blank and
#                    Reset_Video_Mode are untouched.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress: revert Edits A-C and hand
#   back. Single-site failure: ripgrep siblings before classifying. Any
#   broader breakage gets its own pass.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41E.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41E.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41E.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41E (SDL2 present pump in Wait_Vert_Blank)"
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
