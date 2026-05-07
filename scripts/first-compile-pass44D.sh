#!/usr/bin/env bash
# TIM-148 pass-44D: ADPCM decode + sample load/free.
#
# Graduates Load_Sample / Load_Sample_Into_Buffer / Sample_Read /
# Free_Sample on the Linux branch from no-op stubs to real bodies wired
# through the in-tree REDALERT/ADPCM.CPP IMA-ADPCM decoder. Output buffer
# layout matches 44C's Play_Sample_Handle consumption contract:
# AUDHeaderType (in-memory, 20 bytes on x86_64 Linux) followed by
# `UncompSize` bytes of decoded S16 mono PCM.
#
# Baseline: pass-44C tip (commit 9b5d572) = OK 301 / FAIL 0 / Total 301.
#
# === Diff vs pass-44C ===
#
# (1) REDALERT/AUDIO.CPP, Linux branch (`#else // !_MSC_VER`):
#       * Includes add: `"soscomp.h"` (decoder API), `<cstdlib>` (malloc/free).
#       * Forward decls add: Open_File / Close_File / Read_File +
#         AUD_FILE_READ_MODE constexpr (FILE.H is shadowed by FUNCTION.H's
#         `#define FILE_H` at line 197 -- see project memory note; declaring
#         the four needed entry points locally avoids the shadow without
#         editing function.h's pre-define list).
#       * On-disk POD structs (private to the Linux branch):
#           - AUDOnDiskHeader (12 bytes, static_asserted): mirrors
#             AUDHeaderType but with uint16/uint32 widths so it works on
#             x86_64 where in-memory `long` is 8 bytes (sizeof(AUDHeaderType)
#             == 20 in memory, 12 on disk -- a real serialization gap that
#             would corrupt reads if ignored).
#           - AUDOnDiskChunkHeader (8 bytes, static_asserted): {Size, OutSize,
#             Magic=0x0000DEAF}. Walked until cumulative output ==
#             AUDHeader.UncompSize.
#       * Helpers:
#           - Project_AUD_Header(disk, dst): field-by-field copy from the
#             on-disk POD into the in-memory AUDHeaderType.
#           - Decode_AUD_Chunks(fh, pcm_out, pcm_capacity): walks chunks,
#             validates magic, reuses a heap scratch (realloc'd to the
#             max-seen chunk.size), runs sosCODECInitStream +
#             sosCODECDecompressData per chunk, returns total decoded
#             bytes or -1 on error. Decoder state resets per chunk (the
#             encoder reset state at chunk boundaries).
#       * Graduated entry points:
#           - Load_Sample(filename): Open_File + Read_File on-disk header +
#             malloc(20 + UncompSize) + Project + Decode_AUD_Chunks +
#             Close_File. Returns the malloced blob (header + PCM).
#           - Load_Sample_Into_Buffer(filename, buffer, size): same shape,
#             writes into caller-provided buffer; returns total bytes
#             (sizeof(AUDHeaderType) + UncompSize) or 0 on too-small /
#             error.
#           - Sample_Read(fh, buffer, size): stateless single-chunk reader
#             for 44E's streaming chunker. Returns chunk.out_size or 0 on
#             EOF / error / caller-buffer-too-small. Per-fh decoder state is
#             not maintained (decoder resets per chunk anyway).
#           - Free_Sample(sample): free + cast-away-const for the C-style
#             API.
#       * Threading: these four entry points operate on engine-thread caller
#         buffers. They do NOT touch g_voices[] -- 44C's Play_Sample_Handle
#         locks when the buffer is published into a voice slot. No
#         SDL_LockAudioDevice in the load path.
#
# (2) MSVC branch unchanged byte-for-byte from pass-44C.
#
# (3) No new TUs. AUDIO.CPP is one of the existing 301; the *.cpp glob
#     is unchanged.
#
# (4) No edits to STARTUP.CPP, THEME.CPP, SCORE.CPP, CONQUER.CPP, ADPCM.CPP,
#     or any WIN32LIB/ header. The existing call sites keep their call shape.
#
# === Stays no-op (Linux branch) ===
#
# 10 entry points keep their no-op stub bodies after 44D:
# File_Stream_Sample, File_Stream_Sample_Vol, Sound_Callback,
# maintenance_callback, Stop_Sample_Playing, Get_Digi_Handle,
# Restore_Sound_Buffers, Set_Primary_Buffer_Format,
# Start_Primary_Sound_Buffer, Stop_Primary_Sound_Buffer.
# Streaming (File_Stream_Sample_Vol + Sound_Callback / maintenance_callback)
# is 44E. Stop_Sample_Playing pairs with the speech path -- 44F.
#
# === Cascade-stop expectations ===
#
# Target outcome: OK 301 / FAIL 0 / Total 301. Floor unchanged.
# Spot-check on the 5 audio-touching TUs (AUDIO.CPP, THEME.CPP, SCORE.CPP,
# STARTUP.CPP, CONQUER.CPP) plus ADPCM.CPP -- all six OK pre-floor-run.
#
# Realistic ceiling: 301/0/301. Anything else (especially a non-AUDIO.CPP
# regression) means an unrelated cascade -- revert + handback per the rule.

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$REPO_ROOT/REDALERT"
SHIM_DIR="$REPO_ROOT/build/include-shim"
STUB_DIR="$REPO_ROOT/linux/win32-stubs"
LOG_DIR="$REPO_ROOT/build"
LOG_FILE="$LOG_DIR/first-compile-pass44D.log"
SUMMARY_FILE="$LOG_DIR/first-compile-pass44D.summary.txt"
ATTRIB_FILE="$LOG_DIR/first-compile-pass44D.attribution.txt"

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
    echo "# TIM-148 first compile attempt -- pass 44D (ADPCM decode + sample load/free)"
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
