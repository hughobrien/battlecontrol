#!/usr/bin/env bash
# TIM-148 pass-44F: closing pass. Stop_Sample_Playing real body +
# Sound_End UAF fix. After this pass, the audio substrate is feature-
# complete from this umbrella's perspective.
#
# Baseline: pass-44E tip (commit 86c911b) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-44E ===
#
# (1) REDALERT/AUDIO.CPP, Linux branch (`#else // !_MSC_VER`):
#       * Stop_Sample_Playing(sample): replaces no-op stub. Scans all 8
#         voices under SDL_LockAudioDevice and deactivates every voice
#         whose published `sample` pointer matches (not just the first --
#         the original DSAUDIO API stopped *every* voice playing the
#         matching sample, and a sound effect re-triggered into a
#         different slot while the prior copy was still playing should
#         stop both). Mirrors Is_Sample_Playing's scan shape; mirrors
#         Stop_Sample's defensive zeroing of fade_remaining_callbacks.
#       * Sound_End: lifecycle order corrected from
#         `Music_Teardown(); SDL_Audio_Close();` (UAF window between
#         freeing g_music_blob and SDL_PauseAudioDevice taking effect)
#         to `Stop_Sample(VOICE_MUSIC); Music_Teardown(); SDL_Audio_Close();`
#         -- matches the File_Stream_Sample_Vol song-change pattern
#         verbatim. Stop_Sample under the SDL lock deactivates the slot
#         so the mix loop will skip it; only then is it safe to free
#         g_music_blob; SDL_Audio_Close finishes the device shutdown.
#         The misleading pass-44E comment at AUDIO.CPP:351-353 is
#         replaced with the corrected lifecycle explanation.
#
# (2) MSVC branch unchanged byte-for-byte from pass-44E.
#
# (3) No new TUs. AUDIO.CPP is an existing TU; the *.cpp glob is unchanged.
#
# (4) No edits to STARTUP.CPP, THEME.CPP, SCORE.CPP, CONQUER.CPP, MAPSEL.CPP,
#     ADPCM.CPP, or any WIN32LIB/ header. Existing call sites unchanged.
#
# === Explicit non-deliverable ===
#
# Speak / Speak_AI stay `#if 0`-gated. The Unity-frontend On_Speech
# callback bridge remains the runtime speech path on Linux. Re-enabling
# would route through Play_Sample_Handle(..., VOICE_SPEECH) which
# requires VOX assets at runtime; asset extraction is explicitly out of
# scope per the umbrella description. Speech re-enablement is
# **deferred to a future issue tied to VOX asset distribution**.
#
# === Stays no-op (Linux branch) ===
#
# 5 entry points keep no-op stub bodies after 44F:
# Get_Digi_Handle, Restore_Sound_Buffers, Set_Primary_Buffer_Format,
# Start_Primary_Sound_Buffer, Stop_Primary_Sound_Buffer. These are
# DSAUDIO/Win32-specific lifecycle hooks with no Linux-substrate
# semantics under the SDL2 path -- intentionally inert.
#
# === Closes the umbrella ===
#
# Six +0 audio passes total (44A seam + 44B device open + 44C voice
# mixer + 44D ADPCM decode + 44E music streaming + 44F closing). After
# the link-side umbrella ([TIM-143](/TIM/issues/TIM-143) /
# [TIM-144](/TIM/issues/TIM-144)) puts a runnable binary in someone's
# hand, SFX, score-screen ticks, music streaming, and the
# Stop_Sample_Playing side of the speech bridge all function.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Spot-check on AUDIO.CPP, THEME.CPP, SCORE.CPP, STARTUP.CPP, CONQUER.CPP
# -- all five OK pre-floor-run.
#
# Realistic ceiling: 301/0/301. The two changes are tiny (one fresh
# function body in a TU that already compiles + one function-call order
# swap with comment refresh). Anything else means an unrelated cascade
# -- revert + handback per the rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44F.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44F.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44F.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44F (Stop_Sample_Playing + Sound_End UAF fix; closes umbrella)"
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
