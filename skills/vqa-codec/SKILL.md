---
name: vqa-codec
description: Use when working on the VQA video codec — debugging palette corruption, codebook errors, ADPCM audio drift, LCW decompression bugs, or block-aligned visual artifacts. Trigger on symptoms like ffmpeg vs native decoder mismatches, solid-marker regressions (blockH=4 0xFF / blockH=2 0x0F), CBFZ/CBPZ decoding errors, or VQA decode/compare CI failures.
version: 0.1.0
---

# VQA Codec Skill

> **Nix apps:** `nix run .#vqa-decode` and `nix run .#vqa-compare`.
> Ask the agent to run these instead of typing raw commands.

You are working on the VQA (Westwood Vector Quantized Animation) codec used by C&C
Red Alert and Tiberian Dawn for cinematic cutscenes. The project has a C++ runtime
decoder (`linux/win32-stubs/vqa_player.cpp`), a standalone C++ decoder
(`tools/vqa_dump/vqa_dump.cpp`), and a decode/compare harness that validates output
against ffmpeg's independent decoder.

Read `docs/codec-testing.md` for codec-testing context before starting.

---

## Phase 0 — Quick check

Decode and compare a known VQA file (requires game data):

```bash
nix run .#vqa-decode -- --vqa ENGLISH.VQA --mix /path/to/MAIN.MIX --out /tmp/vqa-ref --engine ffmpeg
nix run .#vqa-decode -- --vqa ENGLISH.VQA --mix /path/to/MAIN.MIX --out /tmp/vqa-test --engine native
nix run .#vqa-compare -- /tmp/vqa-ref /tmp/vqa-test
```

---

## Phase 1 — Classify the symptom

| Symptom | Lens | Go to |
|---|---|---|
| Block-aligned cyan/magenta/black squares in output | Solid-colour marker mismatch (TIM-587 class) | §2.1 |
| Wrong colours across entire frame | Palette expansion or codebook index error | §2.2 |
| Frames decode but pixel-diff fails at p50+ | Codebook entry wrong (wrong block colour) | §2.3 |
| Synthetic test VQA fails after generator change | Generator drift — test.vqa out of sync | §2.4 |
| CBFZ/CBPZ frames produce garbled output | LCW decompression or partial-codebook bug | §2.5 |
| ffmpeg produces different output than Python decoder | Palette rounding or decode logic divergence | §2.6 |
| Pixel-diff passes CI but visual inspection shows corruption | Threshold too high or missing golden frames | §3 |

---

## §2.1 — Solid-colour marker regression (TIM-587 / TIM-613 class)

The codec uses high-byte markers in the codebook to indicate solid-colour blocks:

- **blockH=4** (ENGLISH.VQA, PROLOG.VQA): solid markers at `0xFF00`–`0xFFFF`
- **blockH=2** (MAIN.MIX movies): solid markers at `0x0F00`–`0x0FFF`

**Bug:** If the codebook pre-fill uses the wrong blockH, solid-colour blocks are
decoded as black (codebook index 0) instead of the correct colour. This produces
block-aligned black squares — fill% may pass while visual output is broken.

**Fix pattern:** In `vqa_player.cpp`, the solid-colour
marker pre-fill must be gated on blockH:

```cpp
// C++ (vqa_player.cpp)
uint16_t solid_hi = (blockH == 4) ? 0xFF00 : 0x0F00;
for (int i = 0; i < 256; i++) {
    codebook[solid_hi + i] = solid_colour | i;
}
```

After fixing, run the pixel-diff harness against both synthetic and real VQA files.

---

## §2.2 — Palette expansion (6-bit VGA → 8-bit RGB)

VQA stores palette entries as 6-bit VGA values. Expansion to 8-bit is:
```cpp
uint8_t expand_6_to_8(uint8_t v) {
    return (v << 2) | (v >> 4);  // e.g. 0x3F → 0xFF
}
```

An off-by-one or wrong shift causes p99 pixel deltas of 2–4 (just above threshold)
across all frames. This is a palette-level problem, not a codebook-level problem.

**Verify:** Check that both the C++ and Python decoders use the same expansion
formula. The formula `(v << 2) | (v >> 4)` matches ffmpeg's implementation.

---

## §2.3 — Codebook entry debugging

When a specific block index produces wrong colours, add debug logging to the C++
decoder to dump codebook entries for that frame. Compare against ffmpeg's output
frame-by-frame. Codebook errors typically produce p99 deltas of 50–200 (visually
obvious wrong colours).

---

---

## §2.5 — CBFZ / CBPZ / VPTZ / VPRZ block types

| Type | Description | Common bugs |
|------|-------------|-------------|
| CBFZ | Full codebook, 4×4 blocks | Codebook indices wrap at 256 entries |
| CBPZ | Partial codebook | Accumulated entries from previous frame not cleared |
| VPTZ | Compressed frame-pointer array | Decompression produces wrong block offsets |
| VPRZ | Raw frame-pointer array | Block stride calculation wrong for blockH mismatch |

All four types use LCW (Lempel-Ziv-Westwood) decompression for the codebook data.
If LCW decompression is buggy, both CBFZ and CBPZ frames will be affected.

---

## §2.6 — Native decoder vs ffmpeg divergence

When `tools/vqa_dump/vqa_dump.cpp` and ffmpeg disagree, determine which is correct:

1. Compare against the runtime decoder (`vqa_player.cpp`) — this is the decoder
   in both native and WASM builds
2. If ffmpeg and runtime agree but standalone disagrees, fix `vqa_dump.cpp`
3. If runtime and standalone agree but ffmpeg disagrees, review ffmpeg's VQA source
   (ffmpeg's decoder may have its own bugs for edge-case VQA files)

---

## §3 — Pixel-diff threshold guidance

| Scenario | Typical p99 | Action |
|----------|-------------|--------|
| Correct decoder | 0–2 | Pass |
| Palette off-by-one | 2–4 | Investigate palette expansion |
| Wrong codebook index | 50–200 | Fix codebook lookup |
| Solid-marker regression | 50–255 | Check blockH-dependent pre-fill |
| Minor VGA rounding difference | 6–8 | Raise threshold to 10 for specific file only |

Never raise threshold above 20 without a clear diagnosis — that range hides real
visual corruption.

---

## §4 — Golden frames

Golden frames are reference PNGs generated from known-correct VQA output. They are
used for visual comparison but **must not be committed** (derived from game assets).

> **What's NOT committed:** Decoded PNG frames (derived from copyrighted game VQAs).  

```bash
# Decode VQA frames for comparison:
nix run .#vqa-decode -- --vqa file.vqa --out /tmp/vqa-frames --duration 4 --engine native
```

---

## §5 — Audio track verification

VQA files contain ADPCM audio tracks (mono, 22050 Hz). The decoder must produce
correct PCM output in addition to correct video frames.

### Verifying C++ decoder audio output

```bash
# Extract reference audio from a known VQA using ffmpeg:
ffmpeg -i input.vqa -f s16le -ac 1 -ar 22050 reference.raw

# Compare C++ decoder output against ffmpeg reference:
python3 scripts/vqa-audio-diff.py reference.raw decoder_output.raw
```

### Common audio bugs

| Symptom | Likely cause | Check |
|---------|-------------|-------|
| Audio plays too fast/slow | Sample rate mismatch in VQA header parsing | Verify `audio_sample_rate` matches 22050 |
| Static noise instead of speech | ADPCM nibble order or predictor reset wrong | Check frame-by-frame initial predictor values |
| Audio ends early | Total sample count wrong in VQA header | Verify `total_audio_samples` vs actual decoded length |
| Only left channel or silence | Channel count hardcoded to 2 instead of 1 | Verify VQA audio is mono (all C&C VQAs) |

### Adding to CI gate

When `vqa_player.cpp` changes in a way that affects audio output, use `vqa-compare`
to compare audio alongside video:

```bash
nix run .#vqa-compare -- /tmp/vqa-ref /tmp/vqa-test
```

---

## §6 — Verifying decoder changes in CI

When `vqa_player.cpp` changes in a way that affects frame output:

1. Build the standalone decoder: `g++ -o vqa_dump tools/vqa_dump/vqa_dump.cpp`
2. Decode with ffmpeg reference: `nix run .#vqa-decode -- --vqa file.vqa --out /tmp/ref --engine ffmpeg`
3. Decode with native decoder: `nix run .#vqa-decode -- --vqa file.vqa --out /tmp/test --engine native`
4. Compare: `nix run .#vqa-compare -- /tmp/ref /tmp/test`
5. Confirm no video or audio differences

---

## §7 — CI integration

The VQA gates in `.github/workflows/ci.yml` run on every PR using `vqa-decode` and
`vqa-compare`:

| Step | Gate | Always runs? |
|------|------|-------------|
| VQA decode (ffmpeg) | Extract frames from game VQAs via ffmpeg | Only if data present |
| VQA decode (native) | Extract frames from game VQAs via native decoder | Only if data present |
| VQA compare | Compare ffmpeg vs native decode output | Only if data present |

If a step would normally fail because game data is absent, it exits 2 or 0 to avoid
blocking PRs from contributors without data.

---

## §8 — Verification bar

| Gate | Tool / Command | Expected result |
|------|----------------|----------------|
| VQA decode (both engines) | `nix run .#vqa-decode -- --vqa file.vqa --out /tmp/out --engine native` | PNG frames in /tmp/out |
| VQA compare | `nix run .#vqa-compare -- /tmp/ref /tmp/test` | Exit 0, no differences |

---

## Reference

- `scripts/vqa-decode.py` — VQA decode from MIX (wraps tools/vqa_dump + ffmpeg)
- `scripts/vqa-compare.py` — Compare two VQA decode output dirs (video + audio)
- `tools/vqa_dump/vqa_dump.cpp` — Standalone C++ VQA decoder
- `linux/win32-stubs/vqa_player.cpp` — C++ runtime decoder (native + WASM)
- `e2e/tim600-english-vqa-verify.spec.ts` — WASM VQA verification test
- `e2e/tim677-vqa-underrun-probe.spec.ts` — VQA buffer underrun probe
