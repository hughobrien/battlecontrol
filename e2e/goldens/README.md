# Golden Images

Reference screenshots used by SSIM-based regression gates in the e2e suite.

## Files

| File | Test | Origin |
|------|------|--------|
| `clean-ra-menu.png` | T10 menu-bleed (T10-ra-menu-bleed.spec.ts) | Clean RA main menu, no gameplay |
| `ra-gameplay-f100.png` | TIM-429 visual audit (wasm-gameplay.spec.ts) | SCG01EA at frame 100 |
| `ra-gameplay-f300.png` | TIM-429 visual audit (wasm-gameplay.spec.ts) | SCG01EA at frame 300 |
| `ra-gameplay-f500.png` | TIM-429 visual audit (wasm-gameplay.spec.ts) | SCG01EA at frame 500 |
| `soviet-l1-wineog-f500.png` | Wine OG reference | Soviet L1 Wine capture |
| `soviet-m2-wineog-f500.png` | Wine OG reference (TIM-905) | Soviet M2 Wine capture |
| `nod-m1-wineog-f500.png` | Wine OG reference (TIM-905) | TD Nod M1 Wine capture (Xvfb+openbox) |
| `vqa/test.vqa` | VQA test fixture | Synthetic VQA for unit tests |

## Regenerating

Goldens must be captured from a **known-good** WASM build and manually reviewed before committing.

1. Build WASM and serve:
   ```
   emcmake cmake --preset wasm && cmake --build build-wasm --target ra --parallel
   python3 wasm/serve-coop.py &
   ```

2. Serve game assets (CD1 MIX files required):
   ```
   python3 wasm/serve-assets.py /path/to/CD1 &
   ```

3. Run the capture (goldens auto-save to this directory when missing):
   ```
   RA_ASSETS_URL=http://localhost:9090/ npx playwright test e2e/wasm-gameplay.spec.ts \
     --grep "6 ·" --reporter=line
   ```

4. Review the candidate goldens in `e2e/goldens/`. Compare against a previous release to confirm visual parity.

5. Commit the reviewed goldens.

## Threshold

The SSIM threshold for gameplay goldens is **0.95** (configurable via `--threshold-ssim` in `runParityCompare`). Below this, CI fails and the workflow artifact contains side-by-side diff output for diagnosis.
