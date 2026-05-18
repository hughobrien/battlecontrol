# Parity Checkpoint Capture System

Capture screenshots from any mission or cinematic at any frame across all three targets
(Wine OG, native Linux, WASM) and compare for visual parity.

## CLI

```
capture-checkpoint <type> <id> [--frame N] [--targets LIST] [--output DIR]

Types:
  mission   — e.g. allied-l1, allied-l2, allied-l3, soviet-l1
  vqa       — e.g. ENGLISH, PROLOG, ALLY1, SOVIET1

Options:
  --frame N       Frame number to capture (default 0)
  --targets LIST  Comma-separated: wine,native,wasm (default all)
  --output DIR    Output root (default e2e/checkpoints)
```

Maps `allied-l2` → scenario `SCG02EA.INI`, `soviet-l1` → `SCU01EA.INI`.

## Output structure

```
e2e/checkpoints/<type>-<id>/
    manifest.json          # {type, id, scenario, frame, targets, command, timestamp}
    wine/
        capture.png        # Screenshot from each target
        driver.log         # Capture driver logs
    native/
        capture.png
        driver.log
    wasm/
        capture.png
        driver.log
    diff/
        diff-wine-native.png    # Amplified pixel diff per target pair
        diff-wine-wasm.png
        diff-native-wasm.png
    report.json            # {frames[{pair, ssim, p99, path}], summary: PASS|FAIL|PARTIAL}
```

## Drivers

### Wine (`drivers/wine.py`)

```python
capture_mission(scenario: str, frame: int, output_dir: str) -> Path
capture_vqa(vqa_stem: str, frame: int, output_dir: str) -> Path
```

Implemented by wrapping and generalizing the existing bash patterns:

- Applies binary patches (focus-skip, game-in-focus, cdlabel, ra-scenario-patch, ra-autostart-patch)
- Starts Xvfb (1024x768x24) + openbox WM + cnc-ddraw GDI renderer
- Launches RA95.EXE under Wine 10 (pinned, not Wine 11 — volume label regression)
- Waits `frame / 15` seconds from mission start or VQA sequence start for capture
- Captures via ffmpeg x11grab
- For VQA: skips vqa-skip patch, computes timing offset from VQA sequence start

### Native (`drivers/native.py`)

```python
capture_mission(scenario: str, frame: int, output_dir: str) -> Path
```

- Launches native RA binary under Xvfb with `RA_AUTOSTART=1` + `RA_AUTOSTART_SCENARIO=<scenario>.INI`
- Probes for non-black canvas via ffmpeg x11grab polling (1s interval, up to 45s)
- Waits `frame / 15` additional seconds from first non-black canvas
- Captures via ffmpeg x11grab

VQA capture requires new `RA_VQA_DUMP_FRAME` env var support in `vqa_player.cpp` — not in initial MVP.

### WASM (`drivers/wasm.py`)

```python
capture_mission(scenario: str, frame: int, output_dir: str) -> Path
```

- Starts WASM dev server (`wasm/serve-coop.py`) serving build-wasm/
- Launches headless Chromium via Playwright to `?autostart=1&scenario=<scenario>`
- Waits for `__wasmReady` + target frame count via Playwright canvas polling
- Captures canvas screenshot

Frame counting for WASM requires a `__wasmFrameCount` counter exposed on `Module`
(from the `vqa_player.cpp` / `conquer.cpp` frame loop). Not present in current
build — first WASM invocation clears this gap and adds the counter if missing.

VQA requires new URL param support — not in initial MVP.

## Script subsumption

The following scripts will be generalized then replaced:

| Script | Replaced by | Notes |
|--------|-------------|-------|
| `wine-allied-l1.sh` | `drivers/wine.py` + `capture-checkpoint` | Scenario parameterized, frame parameterized |
| `wine-soviet-l1.sh` | Same | Same template, just different scenario |
| `native-capture.sh` | `drivers/native.py` | Generalized scenario support |
| `wine-vqa-capture.sh` | `drivers/wine.py` VQA path | Frame-seeking parameterized |
| `wine-gameplay.sh` | `drivers/wine.py` | Older xdotool-based, SendInput is the modern approach |
| `gen-gameplay-goldens.sh` | Removed | Replaced by direct capture-checkpoint usage |

The simpler utility patches (`nocd-patch.py`, `ddscl-patch.py`, `focus-skip-patch.py`, etc.)
remain — they are atomic patch tools consumed by the Wine driver.

## Flake changes

- Removes scripts that were referenced as `scripts/` in capture derivations once they are subsumed
- Adds `drivers/` to the Python path
- `capture-checkpoint` registered as a `nix run` app or tool

## Implementation order

1. `drivers/wine.py` — generalize mission capture from wine-allied-l1.sh
2. `drivers/native.py` — generalize from native-capture.sh, add RA_AUTOSTART_SCENARIO
3. `capture-checkpoint.py` — orchestrator + comparison
4. `drivers/wasm.py` — WASM capture via Playwright headless
5. Retrofit VQA capture (requires RA_VQA_DUMP_FRAME env var in engine)
6. Remove subsumed scripts, update flake
