#!/usr/bin/env bash
# TIM-148 pass-44A: SDL2 audio substrate seam (skeleton header).
#
# Baseline: pass-43N tip (commit 9b38433) = OK 301 / FAIL 0 / Total 301.
# pass-43E (commit d184c28) is the prior input-substrate landing that this
# audio umbrella mirrors in shape.
#
# This pass introduces the seam header for the SDL2 audio backend without
# touching any TU. The header is forward declarations only and is not yet
# included by any .cpp file; the build script's *.cpp glob is unaffected.
#
# === Diff vs pass-43N ===
#
# (1) New file linux/win32-stubs/sdl_audio.h: extern "C" forward decls for
#     SDL_Audio_Open / SDL_Audio_Close / SDL_Audio_Is_Open. Whole file
#     gated on `#if !defined(_MSC_VER)`. Mirrors the sdl_quit.h /
#     sdl_input.h shape from TIM-142 / TIM-145.
#
# (2) No edits to AUDIO.CPP, THEME.CPP, SCORE.CPP, STARTUP.CPP, or any
#     header in REDALERT/WIN32LIB. Live audio call surface (Audio_Init,
#     Play_Sample, File_Stream_Sample_Vol, Stop_Sample, Sample_Status,
#     Fade_Sample, Set_Primary_Buffer_Format, Sound_End) stays on the
#     EA upstream no-op stubs at REDALERT/AUDIO.CPP:55-83.
#
# === Why a seam-only first pass ===
#
# The audio-survey document on TIM-148 lays out a 6-step landing
# (44A..44F). 44A's job is to establish the C-callable seam between
# the SDL2 backend (which will live inside REDALERT/AUDIO.CPP under
# `#ifndef _MSC_VER` from 44B onward) and any future cross-TU
# consumer (e.g. a per-frame Sound_Callback pump invoked from
# CONQUER.CPP::Main_Loop), without dragging <SDL2/SDL.h> into the
# call-site TU. The DDRAW seam (sdl_quit.h / sdl_input.h) shipped
# the same way -- forward decls first, real bodies in subsequent
# passes.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Header-only addition cannot regress any TU because no TU
# transitively includes the new header on this pass. Verification:
# spot-check the 5 audio-touching TUs (AUDIO.CPP, THEME.CPP,
# SCORE.CPP, STARTUP.CPP, CONQUER.CPP) -- all five OK.
#
# Realistic ceiling: 301/0/301. Anything else means an unrelated
# regression -- revert + handback per the cascade-stop rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44A.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44A.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44A.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44A (SDL2 audio substrate seam)"
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
