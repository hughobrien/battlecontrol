---
name: vqa-codec
description: Use when working on the VQA video codec — debugging palette corruption, codebook errors, ADPCM audio drift, LCW decompression bugs, or block-aligned visual artifacts. Trigger on symptoms like ffmpeg pixel-diff failures, synthetic test VQA regeneration mismatch, solid-marker regressions (blockH=4 0xFF / blockH=2 0x0F), CBFZ/CBPZ decoding errors, p99 pixel delta exceeding threshold, or CI vqa-pixel-diff job failing.
version: 0.1.0
---

# VQA Codec Skill

You are working on the VQA (Westwood Vector Quantized Animation) codec used by C&C
Red Alert and Tiberian Dawn for cinematic cutscenes. The project has a C++ reference
decoder (`linux/win32-stubs/vqa_player.cpp`), a Python reference decoder
(`scripts/vqa_decode_verify.py`), and a pixel-diff harness that validates both
against ffmpeg's independent decoder.

Read `docs/codec-testing.md` for codec-testing context before starting.

---

## Phase 0 — Quick check

```bash
# Run the always-available synthetic VQA gate (no game data needed):
python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2 --threshold 5
```

Exit codes: **0** = pass, **1** = fail, **2** = skip (ffmpeg absent).

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

**Fix pattern:** In both `vqa_player.cpp` and `vqa_decode_verify.py`, the solid-colour
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

When a specific block index produces wrong colours, extract the codebook for that frame:

```bash
# In vqa_decode_verify.py, add debug logging for codebook entries:
# print(f"  codebook[{idx}] = 0x{entry:04x} → RGB({r},{g},{b})")
```

Compare against ffmpeg's output frame-by-frame. Codebook errors typically produce
p99 deltas of 50–200 (visually obvious wrong colours).

---

## §2.4 — Synthetic test VQA regeneration

`e2e/goldens/vqa/test.vqa` is a 2,640-byte committed file that exercises all codec
paths. The CI regenerates it from the generator and diffs against the committed version.

**When to regenerate:**
1. After changing `scripts/gen_test_vqa.py`
2. When CI reports "committed test.vqa differs from generator output"

```bash
python3 scripts/gen_test_vqa.py e2e/goldens/vqa/test.vqa
git add e2e/goldens/vqa/test.vqa
```

**What it exercises:**
- CBFZ full-codebook decode (4-entry, 4×4 blocks)
- VPTZ compressed frame-pointer array
- Solid-colour markers for blockH=4
- CBPZ single-part partial codebook
- 6-bit VGA palette scaling

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

## §2.6 — Python decoder vs ffmpeg divergence

When the Python decoder and ffmpeg disagree, determine which is correct:

1. Compare both against the C++ decoder (`vqa_player.cpp`) — this is the runtime
   decoder in both native and WASM builds
2. If ffmpeg and C++ agree but Python disagrees, fix Python
3. If C++ and Python agree but ffmpeg disagrees, review ffmpeg's VQA source
   (ffmpeg's decoder may have its own bugs for edge-case VQA files)

The Python decoder MUST match the C++ decoder byte-for-byte. They share the same
logic by design.

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

```bash
# Generate golden frames for a VQA file:
python3 scripts/vqa-pixel-diff.py /path/to/file.vqa \
    --generate-goldens \
    --goldens-dir e2e/goldens/vqa/

# Golden frames are written to:
#   e2e/goldens/vqa/<stem>/golden_0000.png
#   e2e/goldens/vqa/<stem>/golden_0029.png (if --frames specified)
```

---

## §5 — Adding the Python decoder to the CI gate

When `vqa_player.cpp` changes in a way that affects frame output:

1. Update `vqa_decode_verify.py` to match the C++ logic
2. Regenerate synthetic test VQA if needed
3. Run the harness: `python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2`
4. On real game data (if available): `python3 scripts/vqa-pixel-diff.py build/run-172/MAIN.MIX`
5. Confirm p99 ≤ 5 for all frames

---

## §6 — CI integration

The `vqa-pixel-diff` job in `.github/workflows/ci.yml` runs on every PR:

| Step | Gate | Always runs? |
|------|------|-------------|
| Regenerate synthetic VQA | Diff against committed `test.vqa` | Yes |
| Synthetic VQA pixel-diff | Frames 0,1,2, threshold 5 | Yes |
| Game VQA pixel-diff | Frames 0,29,59 from `MAIN.MIX` | Only if data present |

If a step would normally fail because game data is absent, it exits 2 or 0 to avoid
blocking PRs from contributors without data.

---

## §7 — Verification bar

| Gate | Command | Expected result |
|------|---------|----------------|
| Synthetic VQA | `python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2` | Exit 0, p99 ≤ 5 |
| Generator sync | `python3 scripts/gen_test_vqa.py /tmp/test.vqa.new && diff -q e2e/goldens/vqa/test.vqa /tmp/test.vqa.new` | Identical |
| Game VQA (optional) | `python3 scripts/vqa-pixel-diff.py build/run-172/MAIN.MIX --frames 0,29,59` | Exit 0, p99 ≤ 5 |

---

## Reference

- `docs/codec-testing.md` — Codec testing guide (107 lines)
- `scripts/vqa-pixel-diff.py` — Pixel-diff harness (Python reference vs ffmpeg)
- `scripts/vqa_decode_verify.py` — Python reference decoder (mirrors vqa_player.cpp)
- `scripts/gen_test_vqa.py` — Synthetic test VQA generator
- `linux/win32-stubs/vqa_player.cpp` — C++ runtime decoder (native + WASM)
- `e2e/goldens/vqa/test.vqa` — 2,640-byte committed synthetic VQA
- `e2e/tim600-english-vqa-verify.spec.ts` — WASM VQA verification test
- `e2e/tim677-vqa-underrun-probe.spec.ts` — VQA buffer underrun probe
