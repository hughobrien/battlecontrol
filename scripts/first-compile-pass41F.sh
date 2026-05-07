#!/usr/bin/env bash
# TIM-141 measurement: pass 41F (DDRAW.CPP runtime port — SDL_Event
# window-class pump in Wait_Vert_Blank).
#
# Context (pass-41E tip, commit 52fa22c): OK 301 / FAIL 0 / Total 301.
#
# This pass (TIM-141 commit 6):
#   Edit A — REDALERT/WIN32LIB/DDRAW.CPP (file-static block, ~line 89):
#     * `static bool SDL_QuitRequested = false;` — sticky flag, set on
#       drain of any SDL_QUIT.
#     * `static void SDL_Process_Window_Events(void)` — file-local
#       helper that:
#         - SDL_PumpEvents() once.
#         - Loops SDL_PeepEvents(SDL_GETEVENT, SDL_WINDOWEVENT,
#           SDL_WINDOWEVENT) into a 16-event stack buffer until
#           drained. SDL_WINDOWEVENT_FOCUS_LOST / _MINIMIZED ->
#           AllSurfaces.Set_Surface_Focus(FALSE);
#           SDL_WINDOWEVENT_FOCUS_GAINED / _RESTORED ->
#           Set_Surface_Focus(TRUE).
#         - Loops SDL_PeepEvents(SDL_GETEVENT, SDL_QUIT, SDL_QUIT)
#           and OR's any drained event into SDL_QuitRequested.
#     * `extern "C" bool SDL_Quit_Requested(void)` accessor so other
#       TUs can poll without leaking <SDL.h>. (Wiring into the game
#       loop is a follow-up; commit 6 only exposes the signal.)
#     * Why SDL_PeepEvents and not SDL_PollEvent: PollEvent drains
#       the entire queue, but keyboard / mouse / joystick events must
#       remain queued for the DINPUT lane. Tight type filters are
#       the only correct way. Mirrors how Wine's winex11 driver
#       isolates window-class events from input events.
#   Edit B — REDALERT/WIN32LIB/DDRAW.CPP (Wait_Vert_Blank, top):
#     * Calls SDL_Process_Window_Events() *before* the
#       `SDL_PrimarySurface == nullptr || SDL_VideoRenderer == nullptr`
#       early-out, so focus state can flip even before the renderer
#       is fully up.
#
# Out of scope for commit 6:
#   * SDL_KEYDOWN / SDL_KEYUP / SDL_TEXTINPUT — DINPUT lane (must NOT
#     be drained here).
#   * SDL_MOUSEMOTION / SDL_MOUSEBUTTONDOWN / SDL_MOUSEBUTTONUP /
#     SDL_MOUSEWHEEL — DINPUT lane.
#   * SDL_JOYAXISMOTION etc. — DINPUT lane.
#   * Wiring SDL_Quit_Requested() into the game loop — follow-up.
#   * Window resize / fullscreen toggle / key repeat — later.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). All edits live in DDRAW.CPP
#                    behind the existing `#ifndef _MSC_VER` block;
#                    MSVC paths in Wait_Vert_Blank and the file-static
#                    block are byte-for-byte unchanged.
#
# Cascade-stop rule:
#   Any of the 301 currently-OK TUs regress: revert Edits A-B and hand
#   back. Single-site failure: ripgrep siblings (Set_Surface_Focus,
#   AllSurfaces, InFocus) before classifying. Any broader breakage
#   gets its own pass.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass41F.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass41F.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass41F.attribution.txt"

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
    echo "# TIM-141 first compile attempt -- pass 41F (SDL_Event window-class pump in Wait_Vert_Blank)"
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
