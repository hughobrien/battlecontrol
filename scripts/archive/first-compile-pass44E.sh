#!/usr/bin/env bash
# TIM-148 pass-44E: music streaming chunker (option (i)).
#
# Graduates File_Stream_Sample / File_Stream_Sample_Vol / Sound_Callback /
# maintenance_callback on the Linux branch from no-op stubs to real bodies,
# defines `int StreamLowImpact = 0;` (canonical-typed; declared at
# REDALERT/WIN32LIB/AUDIO.H:159 but never previously instantiated), and
# aligns two `extern short StreamLowImpact;` decls (MAPSEL.CPP, THEME.CPP)
# to `extern int` for parity with AUDIO.H -- both were already dead-code
# under the `#ifndef WIN32` gate (WIN32 is defined transitively via
# wwstd.h:46 for any TU transiting wwlib32.h, per project memory), but the
# alignment removes a strict-linker landmine.
#
# Streaming model is option (i): full-song fabricated `pcm_len`, async fill
# into a calloc'd `sizeof(AUDHeaderType) + UncompSize` buffer routed into
# g_voices[VOICE_MUSIC] via Play_Sample_Handle. 44C's mix loop is unchanged
# -- music plays through the same per-voice path as SFX, just into a
# different slot.
#
# Baseline: pass-44D tip (commit adfc2e5) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-44D ===
#
# (1) REDALERT/AUDIO.CPP, file scope (outside `#ifdef _MSC_VER` gate):
#       * `int StreamLowImpact = 0;` -- canonical definition.
#
# (2) REDALERT/AUDIO.CPP, Linux branch (`#else // !_MSC_VER`):
#       * Chunker globals:
#           - `g_music_fh` (int = -1): open AUD file handle.
#           - `g_music_blob` (uchar* = nullptr): calloc'd
#             `sizeof(AUDHeaderType) + UncompSize` buffer.
#           - `g_music_pcm_capacity` (ulong = 0): == AUDHeader.UncompSize.
#           - `g_music_pcm_written` (ulong = 0): bytes decoded so far.
#           - `g_music_source_rate` (int = 0): AUD header Rate.
#           - `g_music_scratch` (uchar* = nullptr) +
#             `g_music_scratch_cap` (ulong = 0): realloc'd to max-seen
#             chunk.size, reused across chunks (no per-call malloc on the
#             refill hot path).
#       * Static helpers:
#           - Music_Teardown(): close fh, free blob + scratch, zero state.
#           - Music_Decode_Toward(target, throttle): decode chunks from
#             g_music_fh into g_music_blob's PCM region until
#             g_music_pcm_written >= target, EOF, or error. Throttle caps
#             to one chunk per call (StreamLowImpact path). Returns 1 on
#             progress, 0 on clean EOF (closes fh), -1 on format/I/O
#             error.
#       * Graduated entry points:
#           - File_Stream_Sample_Vol(filename, volume, real_time_start):
#             tear down any prior song, Open_File, Project_AUD_Header,
#             calloc full-song buffer, pre-fill ~1s of headroom, publish
#             via Play_Sample_Handle into VOICE_MUSIC, return VOICE_MUSIC
#             (= 5). Returns 0 on any error path.
#           - File_Stream_Sample: thin wrapper -> File_Stream_Sample_Vol
#             at full volume (255).
#           - Sound_Callback: engine-thread refill pump. Detects external
#             Stop_Sample(VOICE_MUSIC) (THEME song change) and natural
#             EOF (mix loop hit pcm_len). Maintains ~1s headroom ahead of
#             the audio thread's read cursor. Honors StreamLowImpact != 0
#             by capping to one chunk per call.
#           - maintenance_callback -> Sound_Callback (single shared
#             refill cadence).
#       * Sound_End: now calls Music_Teardown() before SDL_Audio_Close().
#
# (3) Sample_Read signature unchanged. The CEO ruling allowed extending
#     it with a caller-supplied scratch parameter, but pass-44E's
#     Sound_Callback does its own inline chunk decode through
#     Music_Decode_Toward (using g_music_scratch), so no Sample_Read
#     callers exist in-tree at the chunker layer. Keeping Sample_Read's
#     signature stable avoids dead-but-compiled-in code.
#
# (4) REDALERT/MAPSEL.CPP:88, REDALERT/MAPSEL.CPP:106,
#     REDALERT/THEME.CPP:54: `extern short StreamLowImpact;` ->
#     `extern int StreamLowImpact;`. All three sites are gated on
#     `#ifndef WIN32`, which is false in any TU transiting wwlib32.h
#     (wwstd.h:46 pre-defines WIN32 -- see project memory). Dead-code on
#     Linux today; aligned for parity and strict-linker safety.
#
# (5) MSVC branch unchanged byte-for-byte from pass-44D.
#
# (6) No new TUs. AUDIO.CPP / MAPSEL.CPP / THEME.CPP are existing TUs;
#     the *.cpp glob is unchanged.
#
# === Threading invariants ===
#
# - SDL audio thread reads from g_music_blob[0..g_music_pcm_written) under
#   the SDL device lock (44C mix loop).
# - Engine thread writes to g_music_blob[g_music_pcm_written..) outside
#   the lock (Music_Decode_Toward); the split is safe because writes only
#   ever extend an append-only front, and Sound_Callback maintains a
#   headroom margin so the audio thread's cursor stays behind it.
# - Bytes ahead of g_music_pcm_written are zero (calloc) -- they sound
#   like silence if the audio thread overruns. Not garbage.
# - Updates to chunker globals (g_music_pcm_written etc.) are written by
#   the engine thread only and read by the engine thread only. No SDL
#   thread access.
# - Sound_End's Music_Teardown ordering: closes the file handle and frees
#   buffers before SDL_Audio_Close zeros g_voices[]. Either order is
#   safe (Music_Teardown doesn't touch SDL state); current order is
#   defensive against future SDL_Audio_Close races.
#
# === Stays no-op (Linux branch) ===
#
# 6 entry points keep no-op stub bodies after 44E:
# Stop_Sample_Playing, Get_Digi_Handle, Restore_Sound_Buffers,
# Set_Primary_Buffer_Format, Start_Primary_Sound_Buffer,
# Stop_Primary_Sound_Buffer. Stop_Sample_Playing pairs with the speech
# path -- 44F.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Spot-check on AUDIO.CPP, THEME.CPP, SCORE.CPP, STARTUP.CPP, CONQUER.CPP,
# ADPCM.CPP, MAPSEL.CPP, plus WIN32LIB/PALETTE.CPP (Sound_Callback caller)
# -- all eight OK pre-floor-run.
#
# Realistic ceiling: 301/0/301. Anything else means an unrelated cascade
# -- revert + handback per the rule. If the MAPSEL.CPP / THEME.CPP extern
# alignment introduces a regression (it shouldn't, since both were
# already dead-code under #ifndef WIN32), revert the alignment but keep
# the StreamLowImpact definition + chunker (the load-bearing fix).

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44E.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44E.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44E.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44E (music streaming chunker, option (i))"
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
