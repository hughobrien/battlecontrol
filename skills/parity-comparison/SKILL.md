---
name: parity-comparison
description: Use when comparing WASM/native Linux C&C output against original Wine/RA95 baseline screenshots. Trigger on symptoms like SSIM below threshold, parity test regression, Wine OG capture failure, MIX checksum mismatch, cinematic pixel-diff failure, or any new visual change that needs parity validation. Also trigger when adding a new scene/menu/mission to the parity gate.
version: 0.1.0
---

# Parity Comparison Skill

You are comparing output from the WASM or native Linux C&C build against the original
Windows Red Alert (RA95.EXE) or Tiberian Dawn (C&C95.EXE) running under Wine. The goal
is pixel-level visual parity: every frame, menu, and gameplay scene should be
structurally identical (SSIM ≥ 0.90) to the original.

This skill covers the full parity workflow: capture reference screenshots from Wine OG,
capture test screenshots from WASM/Linux, run comparison tools, interpret results, and
triage failures.

---

## Phase 0 — Quick check: data integrity

Before visual comparison, verify the game data matches the reference:

```bash
# Tier 1 — MIX checksum verification (no Wine needed):
python3 scripts/ra-data-verify.py [DATA_DIR]
```

If this fails, the game data is corrupt or from a different release — visual parity
comparison will be invalid regardless of code correctness.

---

## Phase 1 — Classify the parity scenario

| Scenario | What to compare | Go to |
|---|---|---|
| New WASM build, want to verify visual parity | Wine OG title + menu + gameplay | §2 (full workflow) |
| Title screen or main menu changed | Screenshots: Wine OG vs WASM/native | §2.1 + §3.1 |
| Gameplay scene (Allied L1, Soviet L1, etc.) | Screenshots: Wine OG vs WASM at specific frame | §2.2 + §3.2 |
| Cinematic/VQA playback | Frame-by-frame pixel diff via ffmpeg proxy | §4 |
| SSIM regression (was 0.94, now 0.88) | Diagnose what changed between captures | §5 |
| Need to add a new parity scene | Capture Wine OG golden → add to test | §6 |

---

## §2 — Full parity workflow (capture → compare → triage)

### §2.1 — Step 1: Capture Wine OG reference screenshots

**Red Alert:**
```bash
# Capture title + menu (takes ~30s):
bash scripts/wine-ra.sh
# Output: e2e/screenshots/wine-ra-title.png, e2e/screenshots/wine-ra-menu.png

# Campaign-specific captures:
bash scripts/wine-allied-l1.sh    # Allied L1
bash scripts/wine-soviet-l1.sh    # Soviet L1 (golden stored in e2e/goldens/)
```

**Tiberian Dawn:**
```bash
bash scripts/wine-td.sh
# Output: e2e/screenshots/wine-td-title.png, e2e/screenshots/wine-td-menu.png
```

Set env vars to enable downstream comparison:
```bash
export WINE_RA_READY=1    # Enables RA parity tests
export WINE_TD_READY=1    # Enables TD parity tests
```

### §2.2 — Step 2: Capture WASM/Linux test screenshots

**WASM (via Playwright):**
```bash
# Tier 1: captures WASM screenshots, always runs
npm run test:e2e:wasm-parity
# Output screenshots: e2e/screenshots/tim710-wasm-*.png

# With Wine OG comparison enabled:
WINE_RA_READY=1 npm run test:e2e:wasm-parity
```

**Native Linux:**
```bash
# Start Xvfb (idempotent, auto-cleanup on exit):
source scripts/skill-xvfb-ensure.sh :99 640x480x24

# Run game under Xvfb, capture via ffmpeg x11grab:
DISPLAY=:99 ./build/ra &
sleep 10
ffmpeg -f x11grab -video_size 640x480 -i :99 -frames:v 1 native-menu.png -y
```

### §2.3 — Step 3: Run parity comparison

```bash
# SSIM + fill% + p99 pixel diff (Wine OG vs WASM/Linux):
python3 scripts/parity-compare.py \
    e2e/screenshots/wine-ra-menu.png \
    e2e/screenshots/tim710-wasm-menu.png \
    --label "RA-menu" \
    --threshold-ssim 0.90 \
    --diff-out e2e/screenshots/diff-menu.png

# Exit codes: 0=PASS, 1=FAIL, 2=SKIP
```

Output includes:
- **SSIM** — structural similarity (0–1). ≥0.90 = pass.
- **fill_a / fill_b** — % non-black pixels in each image. Large discrepancy → capture problem.
- **p99_diff** — 99th percentile absolute per-channel pixel difference. ≤20 expected for passing.
- **diff_out** — amplified abs-diff PNG showing where images diverge.

### §2.4 — Step 4: Interpret and triage

| Observation | Diagnosis | Action |
|---|---|---|
| SSIM < 0.90, fill_a ≈ fill_b | Genuine visual difference | Inspect diff PNG; check for palette, render order, or input timing differences |
| SSIM < 0.90, fill_a >> fill_b | Wine OG renders more pixels than WASM | Wasm screen is blank or partially rendered — check WASM init, pageerrors |
| SSIM ≈ 1.0 but fill% differs by >5% | Different window decorations or capture area | Use `--crop-bottom N` to mask known-different regions (e.g. command bar) |
| p99_diff > 200, SSIM passes | Small region with high delta (e.g. mouse cursor, UI element) | Inspect diff PNG to identify the hotspot; may be benign |
| `parity-compare.py` returns SKIP | Screenshot file missing | Run the capture step for the missing image |

**Content-based alignment:** `parity-compare.py` uses FFT cross-correlation on luminance
to align images with different canvas sizes (e.g. Wine Xvfb window decorations vs WASM
canvas). If alignment produces false failures, use `--no-align` to fall back to center-crop.

---

## §3 — Parity comparison tiers

The e2e tests follow a tiered structure:

### Tier 1 — Self-validation (always runs, no Wine needed)

| Test | What it checks |
|------|---------------|
| Title screen | Canvas fill ≥5%, 640×480, no cyan-scatter |
| Main menu | Canvas fill ≥30%, 640×480 |
| Allied L1 gameplay | Map fill ≥20% at t=0, t≈10s, t≈30s |
| Soviet L1 frame 500 | Map fill ≥5%, screenshot captured |
| VQA playback | Canvas non-black during early + mid playback |

### Tier 2 — Wine OG parity (requires WINE_RA_READY=1)

| Test | Comparison | Gate |
|------|-----------|------|
| Title screen | Wine OG vs WASM | SSIM ≥ 0.90 |
| Main menu | Wine OG vs WASM | SSIM ≥ 0.90 |
| Allied L1 t=0 | Wine OG vs WASM | SSIM ≥ 0.90 |
| Soviet L1 frame 500 | Wine OG golden vs WASM | SSIM ≥ 0.90 |

Tier 2 tests skip automatically when `WINE_RA_READY` is not set, making them safe
to run on any machine.

---

## §4 — Cinematic/VQA parity

For frame-level cinematic comparison, use the cinematic pixel-diff harness which
compares our Python VQA decoder against ffmpeg (as a proxy for Wine OG output):

```bash
# RA cinematics:
python3 scripts/cinematic-compare.py \
    /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX \
    --threshold 8

# TD cinematics:
python3 scripts/td-cinematic-compare.py \
    /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/CONQUER.MIX

# For specific VQA files:
python3 scripts/cinematic-compare.py \
    build/run-172/MAIN.MIX \
    --threshold 5 \
    --max-vqas 8
```

**Why ffmpeg ≈ Wine OG:** ffmpeg's VQA decoder is a clean-room reverse-engineering
of the Westwood codec. Frame-for-frame output is effectively identical to RA95.EXE's
output (±1 per channel on 6→8 bit palette expansion).

**For WASM cinematic parity specifically:**
```bash
# WASM VQA verification (E2E test):
npx playwright test e2e/tim600-english-vqa-verify.spec.ts
```

---

## §5 — Diagnosing SSIM regression

When a previously-passing parity check starts failing:

1. **Check if the Wine OG reference changed.** Re-run `wine-ra.sh` and compare the
   new screenshot against the old one:
   ```bash
   python3 scripts/parity-compare.py old-wine-menu.png new-wine-menu.png --threshold-ssim 0.95
   ```
   If SSIM < 0.95 between two Wine captures, the capture environment changed
   (Wine version, Xvfb depth, display settings).

2. **Check if the WASM screenshot changed independently.** Was the test run with
   different game data, URL params, or browser version?

3. **Inspect the diff PNG.** `--diff-out` writes an amplified difference image.
   Look for:
   - Full-frame colour shift → palette bug or colour-space change
   - Translation offset → window manager / Xvfb geometry change
   - Localized block differences → render order or z-order change
   - Missing UI elements → input timing or menu navigation regression

4. **Check canvas dimensions.** Mismatched dimensions (e.g. Wine at 640×480 with
   decorations vs WASM at exactly 640×480) are handled by content-based alignment,
   but extreme differences may cause false failures.

5. **Run with `--print-bbox`** to see detected content bounding boxes:
   ```bash
   python3 scripts/parity-compare.py wine.png wasm.png --print-bbox
   ```
   If the content bboxes differ significantly, the captures are from different
   game states.

---

## §6 — Adding a new parity scene

1. **Capture Wine OG reference:**
   ```bash
   bash scripts/wine-allied-l1.sh   # or create a new capture script
   # Screenshot saved to e2e/screenshots/wine-allied-l1-t0.png
   ```

2. **Capture WASM screenshot** (add to existing Playwright test or create new one):
   ```ts
   await page.screenshot({ path: path.join(SCREENSHOTS_DIR, 'tim710-wasm-allied-l1-t0.png') });
   ```

3. **Add parity assertion to the e2e test:**
   ```ts
   const cmp = runParityCompare(wineShot, wasmShot, {
     label: 'allied-l1-t0', thresholdSsim: 0.90, diffOut
   });
   expect(cmp.ssim).toBeGreaterThanOrEqual(0.90);
   ```

4. **Add to CI regression suite** in `gh-pages.yml` under the Playwright tests section.

5. **For golden frames** (committed reference PNGs):
   ```bash
   # Golden frames go in e2e/goldens/ — must NOT contain game assets
   cp e2e/screenshots/wine-allied-l1-t0.png e2e/goldens/allied-l1-wineog-t0.png
   ```

---

## §7 — Tools reference

| Tool | Purpose | Input | Output |
|------|---------|-------|--------|
| `parity-compare.py` | SSIM + fill% + p99 diff | Two PNGs | JSON result + optional diff PNG |
| `cinematic-compare.py` | VQA frame-by-frame pixel diff | MAIN.MIX | Per-VQA PASS/FAIL + JSON report |
| `td-cinematic-compare.py` | TD VQA frame comparison | CONQUER.MIX | Same as cinematic-compare for TD |
| `ra-data-verify.py` | MIX checksum + INI verification | CD1 data dir | PASS/FAIL per file |
| `wine-ra.sh` | Wine OG RA capture | — | title + menu PNGs |
| `wine-td.sh` | Wine OG TD capture | — | title + menu PNGs |
| `wine-allied-l1.sh` | Wine OG Allied L1 | — | gameplay PNGs |
| `wine-soviet-l1.sh` | Wine OG Soviet L1 | — | gameplay PNGs |
| `tim710-wasm-parity.spec.ts` | WASM self-validation + Wine parity | — | Screenshots + PASS/FAIL |
| `tim699-ra-compare.spec.ts` | RA Wine OG comparison (Tier 1+3) | — | MIX checksums + screenshot parity |
| `tim711-td-compare.spec.ts` | TD Wine OG comparison | — | Screenshot parity |

---

## §8 — Verification bar (smoke test)

```bash
# 1. Data integrity (no Wine needed):
python3 scripts/ra-data-verify.py [DATA_DIR]
# Expected: exit 0 (or SKIP if data absent)

# 2. Parity compare tool works (on any two PNGs):
python3 scripts/parity-compare.py \
    e2e/screenshots/wine-ra-menu.png \
    e2e/screenshots/wine-ra-menu.png \
    --label "self-test" --threshold-ssim 0.99
# Expected: PASS with SSIM ≈ 1.0 (comparing image against itself)

# 3. Cinematic compare (requires MAIN.MIX + ffmpeg):
python3 scripts/cinematic-compare.py --threshold 8
# Expected: all VQAs PASS, p99 ≤ 8 per frame

# 4. WASM parity (requires wasm build + server):
npx playwright test e2e/tim710-wasm-parity.spec.ts --grep "Tier 1"
# Expected: all Tier 1 self-validation tests pass
```

---

## Reference

- `scripts/parity-compare.py` — SSIM-based screenshot comparison (335 lines)
- `scripts/cinematic-compare.py` — VQA frame-by-frame parity (718 lines)
- `scripts/ra-data-verify.py` — MIX checksum + INI verification (168 lines)
- `scripts/wine-ra.sh` — RA Wine OG launcher + screenshot capture (208 lines)
- `scripts/wine-td.sh` — TD Wine OG launcher + screenshot capture (191 lines)
- `e2e/tim710-wasm-parity.spec.ts` — RA WASM vs Wine OG parity (550 lines)
- `e2e/tim699-ra-compare.spec.ts` — RA Wine OG comparison (Tier 1 MIX + Tier 3 Wine OG)
- `e2e/tim711-td-compare.spec.ts` — TD Wine OG comparison
- `e2e/goldens/` — Committed golden frames for parity comparison
- `docs/smoke-test-design-rule.md` — Assertion-first design rules
