#!/usr/bin/env bash
# TIM-142 measurement: pass 43E (wire SDL_Quit_Requested() into
# REDALERT/CONQUER.CPP::Main_Loop).
#
# Note on naming: pass-42.sh is an older TIM-80 historical script
# (Win32 SendMessage shim); not reused. Next sequential pass for
# TIM-142 takes the 42A alpha-suffix per pass-40A/41B/... convention.
#
# Context (pass-41F tip, commit bda1104): OK 301 / FAIL 0 / Total 301.
# Producer landed in TIM-141 pass-41F (DDRAW.CPP):
#   * static bool SDL_QuitRequested = false;
#   * static void SDL_Process_Window_Events() drains SDL_QUIT into it.
#   * extern "C" bool SDL_Quit_Requested(void) accessor.
# Nothing read it yet, so the Linux build could not exit on window
# close. This pass wires the poll into the central per-frame entry.
#
# This pass (TIM-142):
#   Edit A — linux/win32-stubs/sdl_quit.h (NEW):
#     * Tiny portable header. extern "C" forward decl for
#       `bool SDL_Quit_Requested(void)`. Whole file gated on
#       `#if !defined(_MSC_VER)`. Keeps <SDL2/SDL.h> out of the
#       call-site TU (CONQUER.CPP) and out of every other TU.
#   Edit B — REDALERT/CONQUER.CPP (top of file, near other includes):
#     * `#ifndef _MSC_VER  #include "sdl_quit.h"  #endif` after the
#       existing ccdde.h / vortex.h block.
#   Edit C — REDALERT/CONQUER.CPP::Main_Loop (immediately above the
#     existing `if (!GameActive) return(!GameActive);` early-out):
#     * `#ifndef _MSC_VER` block: if SDL_Quit_Requested() returns
#       true, set `GameActive = false`. The very next line is the
#       existing early-out, which then returns `!GameActive == true`,
#       and the calling for-loops in CONQUER/MPLAYER/SOUNDDLG/etc.
#       break out of Main_Loop. This is exactly the same exit path
#       the Win32 build reaches via WINSTUB.CPP::WM_DESTROY (which
#       calls Prog_End("WM_DESTROY", false)).
#
# Why the top of Main_Loop and not Wait_Vert_Blank or the for-loops:
#   * Main_Loop is the single per-frame entry shared by every dialog
#     and the main game loop (12 callers via ripgrep). Polling here
#     gets every loop iteration with one site.
#   * Polling above the existing `!GameActive` check piggybacks on
#     the engine's existing exit semantics — no new flag, no new
#     branch in callers, MSVC byte-for-byte identical.
#   * Wait_Vert_Blank already pumps the queue (TIM-141 pass-41F);
#     polling the resulting flag in Main_Loop separates "drain" from
#     "react", which keeps the DDRAW.CPP pump independent of the
#     engine's exit semantics.
#
# Out of scope for TIM-142:
#   * Window resize, fullscreen toggle, key repeat — defer.
#   * Keyboard / mouse / joystick events — DINPUT lane.
#   * Audio shutdown ordering across DSOUND teardown — separate
#     issue once DSOUND is wired.
#   * Reset of the sticky flag — quit is one-way, by design.
#
# Realistic ceiling: 301 OK / 0 FAIL (+0).
# Realistic floor:   301 OK / 0 FAIL (+0). All edits live behind
#                    `#ifndef _MSC_VER` (header is whole-file gated;
#                    CONQUER.CPP changes are inside per-edit gates).
#                    MSVC paths are byte-for-byte unchanged.
#
# Cascade-stop rule (per CEO/founding-engineer guidance):
#   Any of the 301 currently-OK TUs regress: revert Edits A-C and
#   hand back. Single-site failure: ripgrep siblings (Main_Loop call
#   sites, GameActive writers, sdl_quit.h includers) before
#   classifying. Any broader breakage gets its own pass.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass43E.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass43E.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass43E.attribution.txt"

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
    echo "# TIM-142 first compile attempt -- pass 43E (wire SDL_Quit_Requested() into Main_Loop)"
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
