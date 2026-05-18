---
name: parity-comparison
description: Use when comparing WASM/native Linux C&C output against original Wine/RA95 baseline screenshots. Trigger on symptoms like SSIM below threshold, parity test regression, Wine OG capture failure, MIX checksum mismatch, cinematic pixel-diff failure, or any new visual change that needs parity validation. Also trigger when adding a new scene/menu/mission to the parity gate.
version: 0.2.0
---

# Parity Comparison Skill

> **Tools available via `pi-battlecontrol-dev` extension:** `data_verify`, `wine_capture`,
> `parity_compare`, `wasm_screenshot`, `vqa_pixel_diff`, `run_e2e_test`.
> Ask the agent to run these instead of typing raw commands.

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

```
data_verify(dir: "/path/to/game/data")
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

Use the `wine_capture` tool:

```
# Red Alert title + menu (takes ~30s):
wine_capture(game: "ra")

# Tiberian Dawn title + menu:
wine_capture(game: "td")
```

**Output:** `e2e/screenshots/wine-{game}-title.png` and `wine-{game}-menu.png`

**⚠️ Wine 11.0 wow64 caveat:** Wine 11 ships as `wineWow64Packages.stable`
(Nix) which does NOT support `WINEARCH=win32` (`wineWowPackages.stable`
is deprecated upstream). However, it **can** run 32-bit RA95.EXE natively
— just omit `WINEARCH=win32` entirely. The 64-bit prefix auto-handles
32-bit binaries.

**⚠️ Patch chain order for RA95.EXE under Wine 11:**
Apply patches in this exact order, or the game will crash immediately:
```bash
cp RA95.EXE ./RA95_patched.EXE
python3 scripts/nocd-patch.py ./RA95_patched.EXE
python3 scripts/cdlabel-patch.py ./RA95_patched.EXE
python3 scripts/vqa-skip-patch.py ./RA95_patched.EXE
```
(`focus-skip-patch.py` and `game-in-focus-patch.py` are for the AUTODEMO
workflow only — not needed for basic gameplay screenshots.)

**Direct Wine capture (no script):**
```bash
STAGE=$(mktemp -d /tmp/wine-capture-XXXX)
for f in /path/to/data/*.MIX /path/to/data/*.INI; do ln -sf "$f" "$STAGE/$(basename \"$f\")"; done
cp RA95_patched.EXE "$STAGE/RA95.EXE"
cp result/bin/ddraw.dll "$STAGE/ddraw.dll"    # cnc-ddraw
cat >"$STAGE/ddraw.ini" <<'EOF'
[ddraw]
renderer=gdi
windowed=true
hook=0
window_state=normal
[ra95]
scanline_double=true
EOF

Xvfb :99 -screen 0 640x480x24 -ac &
sleep 1
DISPLAY=:99 openbox --sm-disable &
sleep 1

cd "$STAGE"
WINEPREFIX=/tmp/.wine-og \
  WINEDLLOVERRIDES="ddraw=n,b" \
  DISPLAY=:99 \
  timeout 60 wine RA95.EXE &

# Capture with ImageMagick import (more reliable than ffmpeg x11grab for Wine)
sleep 4
DISPLAY=:99 import -window root -depth 8 /tmp/wine-screenshot.png
```

**Campaign-specific captures** (manual scripts only):
```bash
bash scripts/wine-allied-l1.sh    # Allied L1
bash scripts/wine-soviet-l1.sh    # Soviet L1 (golden stored in e2e/goldens/)
```

Set env vars to enable downstream comparison:
```bash
export WINE_RA_READY=1    # Enables RA parity tests
export WINE_TD_READY=1    # Enables TD parity tests
```

### §2.2 — Step 2: Capture WASM/Linux test screenshots

**WASM (via Playwright):**

Use the `wasm_screenshot` tool for a quick capture:
```
wasm_screenshot(target: "ra", waitMs: 1000, buildFirst: true)
```

Or run the full parity E2E test suite:
```
run_e2e_test(spec: "e2e/tim710-wasm-parity.spec.ts")
# With Wine OG comparison:
# (run wine_capture first, then set WINE_RA_READY=1)
```

**WASM Allied L1 gameplay (early frames):**
```
run_e2e_test(spec: "e2e/tim708-wasm-allied-l1.spec.ts")
```
Output screenshots:
- `e2e/tim708/allied-l1/wasm-t5.png` (5s)
- `e2e/tim708/allied-l1/wasm-t15.png` (15s)
- `e2e/tim708/allied-l1/wasm-t30.png` (30s)
- `e2e/screenshots/wasm-gameplay/allied-l1/capture.png` (canonical)

**Native Linux (via built-in BMP capture hooks):**

The native build has TIM-490 hooks that save BMP screenshots at game loop
frames 10, 50, and 100. Run with:
```bash
source scripts/xvfb-ensure.sh :99 640x480x24
DISPLAY=:99 SDL_AUDIODRIVER=dummy SDL_RENDER_DRIVER=software \
  RA_AUTOSTART=1 timeout 30 ./build/ra
# BMPs saved to /tmp/redalert-gameplay-f{010,050,100}.bmp
```

**Native Linux (manual capture with ImageMagick):**
```bash
source scripts/xvfb-ensure.sh :99 640x480x24
DISPLAY=:99 SDL_AUDIODRIVER=dummy SDL_RENDER_DRIVER=software \
  RA_AUTOSTART=1 ./build/ra &
sleep 5
DISPLAY=:99 import -window root -depth 8 native-screenshot.png
```
> **Note:** `import` (ImageMagick) is more reliable for Xvfb capture than
> `ffmpeg x11grab`, which often returns blank frames.

### §2.3 — Step 3: Run parity comparison

Use the `parity_compare` tool:

```
parity_compare(
  imageA: "e2e/screenshots/wine-ra-menu.png",
  imageB: "e2e/screenshots/tim710-wasm-menu.png",
  label: "RA-menu",
  thresholdSsim: 0.90,
  diffOut: "e2e/screenshots/diff-menu.png"
)
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

For frame-level cinematic comparison, use the `vqa_pixel_diff` tool:

```
# RA cinematics (full game VQA scan):
vqa_pixel_diff(mode: "cinematic", mixPath: "/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1/MAIN.MIX", threshold: 8)

# TD cinematics:
vqa_pixel_diff(mode: "cinematic", mixPath: "/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1/CONQUER.MIX", threshold: 8)
```



**Why ffmpeg ≈ Wine OG:** ffmpeg's VQA decoder is a clean-room reverse-engineering
of the Westwood codec. Frame-for-frame output is effectively identical to RA95.EXE's
output (±1 per channel on 6→8 bit palette expansion).

**For WASM cinematic parity specifically:**
```
run_e2e_test(spec: "e2e/tim600-english-vqa-verify.spec.ts")
```

---

## §4.5 — Diagnosing rendering bugs (shape decode / blit issues)

If the rendering looks corrupted ("many small coloured squares", garbled textures,
wrong colours), the issue is likely in the shape blit pipeline rather than in the
shape decode itself. The shape format (KeyFrameHeaderType + LCW decompression)
is tested separately — corrupted-but-right-sized output points to the blit step.

**Check the stride calculation in shape blit functions.**

Every row-based blit must include `Get_Pitch()` in its stride. All correct
functions follow this pattern:
```cpp
int stride = vp->Get_Width() + vp->Get_XAdd() + vp->Get_Pitch();
```

Key files to check:
| File | Function | Status |
|------|----------|--------|
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Buffer_Frame_To_Page` | ✅ Fixed (TIM-1054) |
| `linux/td-win32-stubs.cpp` | `Buffer_Frame_To_Page` | ✅ Fixed (TIM-1054) |
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Buffer_Draw_Stamp` | ✅ Correct |
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Linear_Blit_To_Linear` | ✅ Correct |
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Buffer_Fill_Rect` | ✅ Correct |
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Buffer_Clear` | ✅ Correct |
| `linux/win32-stubs/wwlib-asm-stub.cpp` | `Buffer_Remap` | ✅ Correct |

Without `Get_Pitch()`, each successive row is drawn `Pitch` bytes too early,
progressively shearing the image. `Pitch = SDL_Get_Primary_Pitch() - Width`
(set in `GBUFFER.CPP:599`) and is almost always non-zero for SDL surfaces.

**Reproduction:** The oil derrick pump (STRUCT_PUMP, shape "V19") in Allied
Mission 1 displays as coloured squares when this stride is wrong. Check by
capturing WASM or native screenshots and comparing against Wine OG.

---

## §5 — Diagnosing SSIM regression

When a previously-passing parity check starts failing:

1. **Check if the Wine OG reference changed.** Re-run `wine_capture(game: "ra")` and compare the
   new screenshot against the old one:
   ```
   parity_compare(imageA: "old-wine-menu.png", imageB: "e2e/screenshots/wine-ra-menu.png", thresholdSsim: 0.95)
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
   (The `parity_compare` tool doesn't expose `--print-bbox` yet — use the Python script directly for this.)
   If the content bboxes differ significantly, the captures are from different
   game states.

### Native capture troubleshooting

If native capture produces blank/black frames with ffmpeg, try:
1. Use ImageMagick `import` instead: `DISPLAY=:99 import -window root capture.png`
2. Ensure `SDL_RENDER_DRIVER=software` is set (avoids GPU dependency)
3. Ensure `SDL_AUDIODRIVER=dummy` is set (no audio card needed)
4. Wait at least 4s for the first frame to render (the game loads MIX files first)
5. The TIM-490 BMP hooks fire at frames 10, 50, 100 automatically in autostart mode

### WASM capture troubleshooting

- If the page shows a black canvas, ensure COOP/COEP headers are set (the WASM
  server at `wasm/serve-coop.py` provides these)
- If `__wasmReady` never fires, check the browser console for pageerrors
- First screenshot may be mostly black (~55% fill) while assets load

---

### Automated bisection for parity regressions

When a previously-passing parity check fails, bisect to find the offending commit:

1. **Identify the commit range:**
   ```bash
   git log --oneline win-pass..new-fail  # commits between known-good and known-bad
   ```

2. **Write a bisect script** that builds WASM, captures a screenshot, and compares:
   ```bash
   #!/bin/bash
   # bisect-parity.sh — exits 0 (good) if parity passes, 125 (skip) if build fails
   set -e
   wasm_build target=ra || exit 125
   wasm_screenshot target=ra waitMs=2000 buildFirst=false || exit 125
   parity_compare imageA=e2e/screenshots/wine-ra-menu.png \
                  imageB=e2e/screenshots/tim710-wasm-menu.png \
                  thresholdSsim=0.90 || exit 1
   ```

3. **Run bisect:**
   ```bash
   git bisect start win-pass..new-fail
   git bisect run bash bisect-parity.sh
   ```

   > **Caveat:** Bisect runs from a detached HEAD. The WASM server + asset server
   > must be started outside the bisect loop and stay running across all steps.
   > Alternatively, include server start/stop in the bisect script with PID tracking.

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

### Extension tools (preferred — ask the agent)

See the [skills index](../README.md#companion-scripts) for the full list of
`pi-battlecontrol-dev` extension tools. Parity-relevant tools:

| Tool | Purpose |
|------|---------|
| `data_verify` | MIX checksum + INI verification |
| `wine_capture` | Wine OG title + menu screenshots |
| `wasm_screenshot` | Capture a WASM game screenshot |
| `parity_compare` | SSIM + fill% + p99 diff between two PNGs |
| `vqa_pixel_diff` | VQA frame-by-frame pixel diff (synthetic or cinematic) |
| `run_e2e_test` | Run a Playwright e2e test spec |

### Underlying scripts (use directly for advanced options)

| Script | Purpose |
|--------|---------|
| `scripts/parity-compare.py` | SSIM + fill% + p99 diff (supports `--no-align`, `--print-bbox`, `--crop-bottom`) |
| `scripts/cinematic-compare.py` | VQA frame-by-frame pixel diff (RA) |
| `scripts/td-cinematic-compare.py` | VQA frame-by-frame pixel diff (TD) |
| `scripts/ra-data-verify.py` | MIX checksum + INI verification |
| `scripts/wine-ra.sh` / `wine-td.sh` | Wine OG launcher + screenshot capture |
| `scripts/wine-allied-l1.sh` / `wine-soviet-l1.sh` | Campaign-specific captures |
| `e2e/tim710-wasm-parity.spec.ts` | WASM self-validation + Wine parity |
| `e2e/tim699-ra-compare.spec.ts` | RA Wine OG comparison (Tier 1+3) |
| `e2e/tim711-td-compare.spec.ts` | TD Wine OG comparison |

---

## §8 — Verification bar (smoke test)

| # | Check | Tool / Command | Expected |
|---|-------|----------------|----------|
| 1 | Data integrity | `data_verify(dir: ...)` or `python3 scripts/ra-data-verify.py [DATA_DIR]` | exit 0 (or SKIP) |
| 2 | Parity compare works | `parity_compare(imageA: "...", imageB: "...", thresholdSsim: 0.99)` | SSIM ≈ 1.0 (same image vs itself) |
| 3 | Cinematic compare | `vqa_pixel_diff(mode: "cinematic", threshold: 8)` | all VQAs PASS, p99 ≤ 8 |
| 4 | WASM parity | `run_e2e_test(spec: "e2e/tim710-wasm-parity.spec.ts", args: ["--grep", "Tier 1"])` | all Tier 1 pass |

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
