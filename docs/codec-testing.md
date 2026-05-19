# VQA Codec Testing

## Why this exists

The VQA bug cluster (TIM-587, TIM-602, TIM-604, TIM-613) cost roughly 3 days of
debugging.  Quantitative metrics (fill%, frame count) passed while frames showed
block-aligned corruption.  A frame-by-frame decode comparison would have caught
each regression within seconds.

## How it works

`scripts/vqa-decode.py` extracts VQAs from MIX archives and decodes using one
of two engines:

- **`--engine ffmpeg`** — ffmpeg's independent VQA decoder (reference)
- **`--engine native`** — the project's standalone C++ decoder
  (`tools/vqa_dump/vqa_dump.cpp`), no external dependencies

`scripts/vqa-compare.py` compares two decode output directories frame-by-frame
(both video and audio), reporting any per-pixel or per-sample differences.

## Quick start

```bash
# Decode intro VQA with ffmpeg (reference):
python3 scripts/vqa-decode.py -- --vqa ENGLISH.VQA --mix /path/to/MAIN.MIX --out /tmp/vqa-ffmpeg --engine ffmpeg

# Decode same VQA with native decoder:
python3 scripts/vqa-decode.py -- --vqa ENGLISH.VQA --mix /path/to/MAIN.MIX --out /tmp/vqa-native --engine native

# Compare the two outputs:
python3 scripts/vqa-compare.py -- /tmp/vqa-ffmpeg /tmp/vqa-native

# Limit to first N seconds:
python3 scripts/vqa-decode.py -- --vqa PROLOG.VQA --mix /path/to/MAIN.MIX --out /tmp/vqa-prolog --duration 4 --engine native
```

Exit codes: **0** = pass, **1** = fail (decoder mismatch), **2** = skip (data absent).

## CI integration

The VQA gates in `.github/workflows/ci.yml` run on every PR when game data is
available:

| Step | Gate | Skips when |
|------|------|-----------|
| VQA decode (ffmpeg) | Extract frames via ffmpeg reference | Data absent |
| VQA decode (native) | Extract frames via native decoder | Data absent |
| VQA compare | Compare ffmpeg vs native output | Data absent |

## Using the standalone decoder directly

`tools/vqa_dump/vqa_dump.cpp` is a standalone C++ VQA decoder with no external
dependencies.  It can be compiled on any platform with a C++17 compiler:

```bash
g++ -o vqa_dump tools/vqa_dump/vqa_dump.cpp
./vqa_dump input.vqa output_dir/
```

## Threshold guidance

Since the comparison is between two independent decoders (ffmpeg and native),
any difference indicates a real bug.  The threshold is effectively **0** — either
they match byte-for-byte or they don't.

| Scenario | Expected result |
|----------|----------------|
| Correct decoder vs ffmpeg | Identical output |
| Palette off-by-one | Per-pixel delta detected |
| Wrong codebook index | Frame mismatch detected |
| Solid-colour bug (TIM-587/613 class) | Frame mismatch detected |
| Audio drift | Audio sample mismatch detected |

## The native VQA decoder

`tools/vqa_dump/vqa_dump.cpp` implements the same VQA decoding logic as the
runtime decoder (`linux/win32-stubs/vqa_player.cpp`) but as a standalone tool.
It correctly handles:

- 6-bit VGA palette expansion `(v << 2) | (v >> 4)` — matches ffmpeg
- Solid-colour codebook pre-fill for both blockH=4 (0xFF00–0xFFFF) and
  blockH=2 (0x0F00–0x0FFF) ranges (TIM-587 / TIM-613)
- CBFZ / CBPZ LCW decompression and partial-codebook accumulation
- VPTZ / VPRZ decompressed frame-pointer arrays
- ADPCM audio track extraction

If `vqa_player.cpp` changes in a way that affects frame output, update
`tools/vqa_dump/vqa_dump.cpp` to match and re-run the compare harness.
