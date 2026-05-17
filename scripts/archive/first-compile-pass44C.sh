#!/usr/bin/env bash
# TIM-148 pass-44C: 8-voice table + per-voice S16 PCM mix loop +
# graduated Play_Sample / Stop_Sample / Sample_Status / Is_Sample_Playing /
# Get_Free_Sample_Handle / Sample_Length / Set_Sound_Vol / Set_Score_Vol /
# Fade_Sample bodies. PCM-in only -- ADPCM decode (44D), streaming (44E),
# speech (44F) deferred.
#
# Baseline: pass-44B tip (commit 2e05f2a) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-44B ===
#
# (1) REDALERT/AUDIO.CPP, Linux branch (`#else // !_MSC_VER`):
#       * Includes: add `<cstdint>`, `<algorithm>` (clamp/min/max), `<climits>` (INT_MAX).
#       * State adds:
#           - `static int g_audio_actual_freq / g_audio_actual_channels` (captured
#             from SDL_AudioSpec have post-SDL_OpenAudioDevice).
#           - `static int g_master_sfx_vol / g_master_score_vol` (default 255).
#           - `static constexpr int VOICE_COUNT=8 / VOICE_SFX_BASE=0 /
#             VOICE_SFX_COUNT=5 / VOICE_MUSIC=5 / VOICE_SPEECH=6 / VOICE_RESERVED=7`.
#           - `struct Voice { active, sample, pcm, pcm_len, cursor, source_rate,
#             priority, volume, pan, is_sfx, fade_remaining_callbacks,
#             fade_volume_per_callback }`.
#           - `static Voice g_voices[VOICE_COUNT] = {}`.
#       * Sound_Mixer_Callback rewritten: per-voice byte-cursor mix into the
#         S16 stream (mono or stereo), int32 accumulator with saturating
#         clamp to int16, post-mix fade tick. SDL2 invokes this under the
#         device lock; the callback does not take SDL_LockAudioDevice itself.
#       * SDL_Audio_Open captures `have.freq` / `have.channels` and zeroes
#         g_voices[]. SDL_Audio_Close zeroes the actual_* and g_voices[].
#       * Graduated entry points (each external mutator wraps voice-table
#         writes in SDL_LockAudioDevice / SDL_UnlockAudioDevice):
#           - Play_Sample / Play_Sample_Handle / Stop_Sample / Sample_Status /
#             Is_Sample_Playing / Get_Free_Sample_Handle (5-SFX scan +
#             priority eviction) / Sample_Length (header peek, no lock) /
#             Set_Sound_Vol / Set_Score_Vol / Fade_Sample
#             (60Hz-ticks -> callback-periods rescale).
#       * Remaining 14 entry points (File_Stream_Sample[_Vol], Sound_Callback,
#         maintenance_callback, Load_Sample, Load_Sample_Into_Buffer,
#         Sample_Read, Free_Sample, Stop_Sample_Playing, Get_Digi_Handle,
#         Restore_Sound_Buffers, Set_Primary_Buffer_Format,
#         Start_Primary_Sound_Buffer, Stop_Primary_Sound_Buffer) stay
#         no-op stubs identical to the MSVC branch -- 44D/E/F territory.
#
# (2) MSVC branch unchanged byte-for-byte from pass-44B.
#
# (3) No new TUs. AUDIO.CPP is one of the existing 301; the *.cpp glob
#     is unchanged.
#
# (4) No edits to STARTUP.CPP, THEME.CPP, SCORE.CPP, CONQUER.CPP, or any
#     WIN32LIB/ header. The existing call sites keep their call shape.
#
# === Threading / format invariants ===
#
# - Format is locked to AUDIO_S16SYS (only SDL_AUDIO_ALLOW_FREQUENCY_CHANGE
#   was passed to SDL_OpenAudioDevice). Mix loop relies on this.
# - Channels can be 1 or 2 depending on caller; pan is applied only when
#   channels == 2.
# - Voice-table mutators take SDL_LockAudioDevice (NOT GlobalAudioCriticalSection,
#   declared in WIN32LIB/AUDIO.H but never instantiated -- dead per survey).
# - Frequency renegotiation: source_rate (AUD header `Rate`) vs
#   g_audio_actual_freq differ -> per-voice cursor stride =
#   `2.0 * source_rate / actual_freq` (×2 for S16 byte stride). Double
#   precision for fractional ratios; 8 voices × 1024 frames is trivial CPU.
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
LOG_FILE="$LOG_DIR/first-compile-pass44C.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44C.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44C.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44C (voice table + per-voice mix loop, PCM-in)"
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
