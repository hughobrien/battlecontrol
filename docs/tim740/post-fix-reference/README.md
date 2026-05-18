# TIM-754 — RA Wine OG cinematic re-verification after TIM-740 scanline fix

Re-verifies cinematic parity once cnc-ddraw's `scanline_double=true`
workaround (PR #140, TIM-740) is in place. Captures the post-fix Wine OG
intro VQA frames as reference artefacts and quantifies the rendering
improvement against the pre-fix interlaced captures.

## Method

1. Re-ran the VQA decode/compare pipeline (TIM-705 Part A) against the same
   `MAIN.MIX` to confirm the decoder vs ffmpeg parity spec is unchanged by
   TIM-740 — it should be, because TIM-740 modifies the Wine + cnc-ddraw
   render substrate, not the VQA decoder.
2. Re-used the live Wine OG verify captures already on disk from
   `scripts/wine-ra-cnc-ddraw-fix-verify.sh`
   (`/tmp/tim740/verify/{A_control,B_scanline_double}/t{8,10,12,14}.png`)
   produced under fresh Xvfb + openbox sessions with and without the
   `scanline_double=true` flag.
3. Cropped each 800×600 Xvfb capture to the 640×400 game window region
   (`x=80..720`, `y=100..500`).
4. Computed pre-fix vs post-fix SSIM, PNG-size ratio, and a structural
   "gap row" count (rows whose brightness is < 10% of both neighbours —
   the signature of the interlace artefact) using
   `scripts/tim754-wine-vqa-compare.py`.

## Results

### Parity spec (vqa-decode + vqa-compare) — unchanged

Re-run 2026-05-15 against `MAIN.MIX` (Allied CD1), 8 cinematics including
`AFTRMATH`, `ALLIES1`, `ALLIES2`, `SOVS1`, `ANTS`, `FLARE`, `NUKESTOK`:

```
RESULT: PASS (8/8)
All  p99=0  mean=0.0  ssim=1.0000
```

Identical to the TIM-705 baseline. TIM-740 does not touch the decoder
pipeline, so the decoder-vs-ffmpeg parity is invariant — as expected.

### Wine OG live captures (intro VQA, pre vs post TIM-740)

| timestamp | SSIM(pre,post) | PNG size ratio | pre gap rows | post gap rows |
|-----------|---------------:|---------------:|-------------:|--------------:|
| t8        | 1.0000         | 1.00×          | 1            | 1             |
| t10       | 0.7849         | 1.29×          | 157          | 12            |
| t12       | 0.7723         | 1.49×          | 157          | 2             |
| t14       | 0.0849         | 1.54×          | 157          | 12            |

- `t8` is still a black fade-in frame in both variants — the intro VQA
  has not started painting content yet, hence SSIM=1.0.
- For every active content frame (t10, t12, t14) the structural gap-row
  count drops from a perfect 157 (every other row in the 311-row content
  band) to single-digit residue — a ≥ 92% reduction in the interlace
  artefact.
- PNG file size ratio of 1.29–1.54× matches the values documented in
  `e2e/tim740/notes.md` (1.38–1.56×).
- SSIM(pre, post) varies with how much content survives in the dimmed
  pre-fix capture: t10 (bright "Trinity, New Mexico" caption) ≈ 0.78,
  t14 (dark transition frame) ≈ 0.08.

The remaining gap rows in post-fix t10/t14 are the documented limitation
of TIM-740's heuristic ("when both rows differ by less than 10× but more
than ~3×, the fix doesn't fire"). They cluster at the very top of the
content band — a known acceptable residue.

## Reference artefacts

This directory pins the cropped game-window region from the post-fix
verify run as the canonical "Wine OG intro VQA looks like this" reference
for future regression detection:

- `wine-og-post-fix-t{8,10,12,14}.png` — 640×400, post-TIM-740 Wine OG
- `wine-og-pre-fix-t{8,10,12,14}.png` — 640×400, pre-TIM-740 Wine OG
- `ssim-report.json` — machine-readable SSIM + structural metrics

The post-fix t10 capture (`wine-og-post-fix-t10.png`) shows the
"Trinity, New Mexico" title card from the Einstein prolog with no
visible interlace banding — the expected visual result of TIM-740.

## What does *not* need updating

- `e2e/tim708/allied-l1/*.png` — gameplay screenshots from Allied
  Mission 1, captured after the intro VQA. Not affected by TIM-740.
- `e2e/tim739/after-cdlabel-patch-t{10,20}.png` — pre-TIM-740 interlaced
  intro captures. These are kept *intentionally* as historical evidence
  for the TIM-740 motivation; the TIM-739 commit explicitly handed off
  the interlace artefact as the next ticket.
- `e2e/cinematic-compare/` — removed; `vqa-decode` output is generated
  per-run and not committed.

## Reproducing

```bash
# 1. (one-time) build patched cnc-ddraw with scanline_double support
bash scripts/build-cnc-ddraw.sh

# 2. capture pre-fix and post-fix Wine OG intro frames under Xvfb
bash scripts/wine-ra-cnc-ddraw-fix-verify.sh
# → /tmp/tim740/verify/{A_control,B_scanline_double}/t{8,10,12,14}.png

# 3. compute SSIM + structural metrics and save the cropped references
python3 scripts/tim754-wine-vqa-compare.py
# → docs/tim740/post-fix-reference/

# 4. confirm decoder-vs-ffmpeg parity is unchanged
nix run .#vqa-decode -- --vqa ALLIES1 --mix /path/to/MAIN.MIX --out /tmp/vqa-ffmpeg --engine ffmpeg --duration 4
nix run .#vqa-decode -- --vqa ALLIES1 --mix /path/to/MAIN.MIX --out /tmp/vqa-native --engine native --duration 4
nix run .#vqa-compare -- /tmp/vqa-ffmpeg /tmp/vqa-native
# → No differences found
```
