# Parity Root-of-Trust Working Log

Date: 2026-05-21

Purpose: preserve the active debugging thread for Wine/native reproducibility and
frame alignment across context compaction.

## Goal

The immediate gold standard is:

1. Capture 100 reproducible frames from Wine.
2. Capture the corresponding reproducible frames from native.
3. Once each side is internally reproducible, diff them to find the real engine
   or renderer divergence.

## Current State

- Wine now has a cnc-ddraw root-of-trust capture path under active development.
- Native already has an internal frame trap and produces byte-identical output
  for repeated runs at a fixed requested frame.
- The old Wine process-memory frameprobe plus X11/BitBlt screenshot path could
  be stable on Allied L2, but Allied L1 still drifted across Wine runs. That
  made it unsuitable as the sole root of trust.
- As of the 23:47 UTC run, Wine can produce a reproducible 100-frame Allied L1
  sequence when captures are keyed to RA95's internal frame counter, captured
  through cnc-ddraw's GDI render loop, run at 60 FPS, and started after the
  initial mission-entry instability window.

## Files Touched In This Pass

- `tools/cnc-ddraw/tim780-capture-hook.patch`
  - Adds `ss_take_screenshot_file()`.
  - Adds env-gated capture hooks.
  - Primary `Flip` hook exists, but RA95 did not hit it in the current GDI path.
  - GDI render-loop hook does fire and dumps the actual displayed primary
    surface.
- `flake.nix`
  - Applies `tim780-capture-hook.patch` after `tim740-scanline-double.patch`.
- `scripts/drivers/wine.py`
  - Adds `WINE_CNCDDRAW_CAPTURE=1`.
  - Adds `WINE_CNCDDRAW_CAPTURE_FLIP=N`.
  - Writes `BC_CAPTURE_FLIP`, `BC_CAPTURE_FILE`, `BC_CAPTURE_HALT`, and
    `BC_CAPTURE_RA_FRAME_ADDR` into the Wine process environment.
  - Waits for `wine-cncddraw.png` and returns it as the Wine capture.
- `scripts/capture-checkpoint.py`
  - Wine mission data dir now falls back through `WINE_DATA_DIR`, `DATA_DIR`,
    then `RA_ASSETS`.
- `scripts/capture-wine-sequence.py`
  - Captures Wine render-loop sequences with cnc-ddraw.
  - Defaults to `--fps 60` and `--clock ra`.
  - Emits `wine-sequence-report.json` with byte and decoded-RGBA hashes.
- `scripts/test_cncddraw_capture_hook.py`
  - Contract test for the cnc-ddraw hook and driver wiring.
- `scripts/test_capture_checkpoint_seed.py`
  - Extended to cover Wine data-dir fallback behavior.
- `divergences.md`
  - Updated with the root-of-trust and frame-alignment observations.

## Verification So Far

Commands run successfully:

```bash
python3 scripts/test_capture_checkpoint_seed.py
python3 scripts/test_cncddraw_capture_hook.py
python3 -m py_compile scripts/drivers/wine.py scripts/capture-wine-sequence.py
nix build .#cnc-ddraw --impure --print-out-paths
```

The local cnc-ddraw patch is now zero-context enough to pass `git diff --check`
while still applying cleanly after `tim740-scanline-double.patch`.

## Important Artifacts

Wine render-frame 50, Allied L1, cnc-ddraw GDI render-loop capture:

- `/tmp/battlecontrol/2026-05-21T22-55-47-mission-allied-l1/wine.png`
- `/tmp/battlecontrol/2026-05-21T22-56-34-mission-allied-l1/wine.png`

These two are byte-identical:

- `sha256=f88994da288231728f9fba7fad2dc66d264d039ec60f62c4dbfb6bf47943d365`

Native Allied L1 frame 50:

- `/tmp/battlecontrol/2026-05-21T22-57-23-mission-allied-l1/native.png`
- `/tmp/battlecontrol/2026-05-21T22-57-40-mission-allied-l1/native.png`

These two are byte-identical:

- `sha256=b2f9f09e5c1519348011565b597a576372bca51264931516d695bf3d0371c4a6`

Wine render-frame 50 with RA95 frame-counter log:

- `/tmp/battlecontrol/2026-05-21T23-08-46-mission-allied-l1`
- Driver log line:
  `bc-capture: render_frame=50 ra_frame=91 file=... result=ok`

Native alignment sweep against that Wine PNG:

- `/tmp/battlecontrol/native-align-raframe91-20260521T230940Z`
- Native frames 88-92: about `SSIM=0.465`, `p99=228`.
- Native frame 93: best observed nearby match, `SSIM=0.9786`, `p99=112`.
- Native frames 94-96: still high, gradually lower.

Interpretation: Wine render-frame 50 corresponds visually to roughly native
presented frame 93, even though the Wine memory counter read at the render dump
is `91`. This is likely a counter/present boundary offset, not random drift.

Wine sequence experiments:

- Render-clock sequence, start 1, count 100, 10 FPS:
  `/tmp/battlecontrol/2026-05-21T23-22-58-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-23-44-wine-sequence-allied-l1`.
  Result: complete, but not a stable frame corpus. The 8-bit framebuffer index
  data was stable for all frames, but RGB palette/fade timing and logged RA
  frame values drifted. Render-loop ordinal is not the right multi-frame clock.
- RA-clock sequence, start 1, count 100, 60 FPS:
  `/tmp/battlecontrol/2026-05-21T23-35-16-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-35-57-wine-sequence-allied-l1`.
  Result: both captured RA frame IDs `1..100`; one visual mismatch at RA frame
  `31`, captured on render-loop frame `70` in one run and `71` in the other.
  This points at mission-entry/palette/present-boundary instability.
- RA-clock sequence, start 50, count 100, 60 FPS:
  `/tmp/battlecontrol/2026-05-21T23-36-58-wine-sequence-allied-l1` vs
  `/tmp/battlecontrol/2026-05-21T23-47-13-wine-sequence-allied-l1`.
  Result: complete, identical RA frame IDs `50..149`, and all 100 PNGs are
  byte-identical. This is the current Wine root-of-trust corpus.

## Current Hypotheses

1. The prior Allied L1 Wine nondeterminism was at least partly a screenshot
   timing/root-of-trust issue. The cnc-ddraw render-loop PNGs are byte-stable.
2. The RA95 memory counter at `0x006544c8` is useful but not exactly identical
   to native's capture trap boundary. For Allied L1 render-frame 50 it reads
   `91`, while the closest native visual match is frame `93`.
3. Render-loop ordinal is not a good long-sequence clock. RA-clock capture at
   60 FPS is much more stable, and starting at RA frame 50 avoids mission-entry
   instability for Allied L1.
4. The remaining Wine/native mismatch after alignment is likely a real rendering
   or state divergence, but we should not chase it until we can compare stable
   frame sequences.

## Next Steps

1. Replace or supplement the native sequence wrapper with an in-process native
   sequence dumper. The initial wrapper works but boots once per frame, so 100
   frames would be unnecessarily slow.
2. Run native sequence twice and verify every frame is byte-identical.
3. Build an alignment/comparison report for Wine frame IDs `50..149` versus
   native frame IDs in the same range and nearby offsets.
4. Once both corpora are stable, resume D4/shroud and other visual divergence
   work against stable, aligned frame pairs.

## Useful Invocation

Single Wine cnc-ddraw capture:

```bash
WINE_CNCDDRAW_CAPTURE=1 \
WINE_CNCDDRAW_CAPTURE_FLIP=50 \
WINE_CNCDDRAW_CAPTURE_TIMEOUT=60 \
RA_CAPTURE_FPS=10 \
RA_RANDOM_SEED=0x1eed5eed \
python3 scripts/capture-checkpoint.py mission allied-l1 \
  --frame 50 --targets wine --threshold-ssim 0.90
```

Paired Wine/native capture, currently not aligned by itself:

```bash
WINE_CNCDDRAW_CAPTURE=1 \
WINE_CNCDDRAW_CAPTURE_FLIP=50 \
WINE_CNCDDRAW_CAPTURE_TIMEOUT=60 \
RA_CAPTURE_FPS=10 \
RA_RANDOM_SEED=0x1eed5eed \
python3 scripts/capture-checkpoint.py mission allied-l1 \
  --frame 50 --targets wine,native --threshold-ssim 0.90
```

Current Wine sequence root-of-trust invocation:

```bash
python3 scripts/capture-wine-sequence.py allied-l1 \
  --clock ra --start 50 --count 100 --timeout 180
```

Initial native sequence harness:

- Script: `scripts/capture-native-sequence.py`
- Default: Allied/native RA-clock frames start at 50, 60 FPS, fixed seed.
- Implementation note: this first version wraps the existing native frame trap
  and launches one native process per requested frame. It is good enough to
  prove semantics, but too slow as the final 100-frame loop.
- Smoke run A: `/tmp/battlecontrol/2026-05-21T23-55-09-native-sequence-allied-l1`
- Smoke run B: `/tmp/battlecontrol/2026-05-21T23-55-39-native-sequence-allied-l1`
- Result: frames `50..52` are complete and byte-identical across both runs.
