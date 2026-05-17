#!/usr/bin/env bash
# TIM-141 measurement: pass 41A (DDRAW.CPP runtime port — SDL2 native entry,
# IDirectDrawPalette stub removal).
#
# Context (pass-40AQ tip, commit 5a15b7c): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 1):
#   Edit A — REDALERT/WIN32LIB/DDRAW.CPP:
#     * #include <SDL2/SDL.h> on the Linux build.
#     * Static SDL_Window* / SDL_Renderer* / SDL_Surface* / SDL_Color[256].
#     * Set_Video_Mode: SDL_Init + SDL_CreateWindow + SDL_CreateRenderer
#       + indexed primary SDL_Surface of w x h.
#     * Reset_Video_Mode: SDL teardown ahead of the existing DirectDraw branch.
#     * Set_DD_Palette: always populate PaletteEntries[]; mirror into
#       SDL_PaletteEntries[256]; apply to SDL_PrimarySurface->format->palette
#       via SDL_SetPaletteColors. The DirectDraw SetPalette/SetEntries flow
#       is gated under `#ifdef _MSC_VER`.
#   Edit B — REDALERT/WIN32LIB/DDRAW.H:
#     * Remove the `_NO_COM`-gated IDirectDrawPalette stub struct (last
#       consumer was DDRAW.CPP:752 PalettePtr->SetEntries(...), now gated
#       to the MSVC build). The forward decl `struct IDirectDrawPalette;`
#       outside the stub block keeps LPDIRECTDRAWPALETTE alive as a
#       pointer to incomplete type.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0) — same surface, no change in count.
# Realistic floor:   301 OK / 0 FAIL (+0) — IDirectDrawPalette stub had a
#                    single live consumer (DDRAW.CPP:752), now gated under
#                    `#ifdef _MSC_VER`.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress (especially DDRAW.CPP itself):
#   revert Edit A and Edit B, hand back.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41A.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41A.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41A.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41A (DDRAW.CPP SDL2 entry, IDirectDrawPalette stub removal)"
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
