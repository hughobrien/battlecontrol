#!/usr/bin/env bash
# TIM-148 pass-44B: Audio_Init / Sound_End real bodies under SDL2.
#
# Baseline: pass-44A tip (commit 2db00e8) = OK 301 / FAIL 0 / Total 301.
# pass-44A landed the seam header (linux/win32-stubs/sdl_audio.h) without
# touching any TU. This pass replaces the EA upstream Audio_Init / Sound_End
# no-op stub bodies in REDALERT/AUDIO.CPP with SDL2-backed implementations
# under `#ifndef _MSC_VER`; the MSVC branch keeps the upstream stubs
# byte-for-byte for parity.
#
# === Diff vs pass-44A ===
#
# (1) REDALERT/AUDIO.CPP: lines 55-83 wrapped in `#ifdef _MSC_VER` /
#     `#else`. MSVC branch: 26 EA stubs verbatim. Linux branch:
#       * `#include "sdl_audio.h"` + `#include <SDL2/SDL.h>` + `<cstring>`
#       * `static SDL_AudioDeviceID g_audio_device` + `static bool g_audio_open`
#       * `static Sound_Mixer_Callback(void*, Uint8*, int)` -> memset to silence
#       * `extern "C" SDL_Audio_Open(rate, channels, bits_per_sample)`:
#           SDL_InitSubSystem(AUDIO) + SDL_OpenAudioDevice with
#           freq=rate, format=AUDIO_S16SYS, channels=channels, samples=1024,
#           callback=Sound_Mixer_Callback. SDL_PauseAudioDevice(dev, 0) on
#           success.
#       * `extern "C" SDL_Audio_Close()`: idempotent
#           SDL_PauseAudioDevice(dev, 1) + SDL_CloseAudioDevice(dev) +
#           SDL_QuitSubSystem(AUDIO).
#       * `extern "C" SDL_Audio_Is_Open()`: returns g_audio_open.
#       * `Audio_Init(HWND, bits, stereo, rate, reverse) -> SDL_Audio_Open(rate, stereo?2:1, bits)`,
#         returns TRUE/FALSE per the BOOL contract. window + reverse_channels are
#         Win32-isms with no Linux analogue.
#       * `Sound_End() -> SDL_Audio_Close()`.
#       * The other 24 entry points stay no-op stubs identical to MSVC.
#
# (2) No new TUs. AUDIO.CPP is one of the existing 301; the *.cpp glob is
#     unchanged.
#
# (3) No edits to STARTUP.CPP, THEME.CPP, SCORE.CPP, CONQUER.CPP, or any
#     WIN32LIB/ header. The existing live call sites (STARTUP.CPP:526
#     Audio_Init, STARTUP.CPP:794 / 992 / 1015 Sound_End, NULLDLG.CPP:7292
#     etc.) keep their existing call shape.
#
# === Why no voice mixing on this pass ===
#
# Pass-44C lands the voice table + the real per-voice mix loop. Splitting
# Audio_Init / Sound_End from voice mixing keeps the diff small: this pass
# only proves the SDL device opens cleanly under the engine's real
# Audio_Init shape, with no risk to the silence callback's correctness.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Spot-check on the 5 audio-touching TUs (AUDIO.CPP, THEME.CPP, SCORE.CPP,
# STARTUP.CPP, CONQUER.CPP) -- all five OK pre-floor-run.
#
# Realistic ceiling: 301/0/301. Anything else (especially a non-AUDIO.CPP
# regression) means an unrelated cascade -- revert + handback per the rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44B.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44B.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44B.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44B (Audio_Init / Sound_End real bodies)"
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
