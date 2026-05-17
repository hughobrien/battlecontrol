# Agents — Entry Point

_battlecontrol — C&C Red Alert + Tiberian Dawn port to Linux/WASM_

This is the file an AI coding agent should read first when landing in this repo.
It covers the quickstart, canonical build/test commands, the change cycle, and the
skill index. For deep architecture, see `ARCH.md`. For human-facing docs, see
`README.md`.

## How to Make Progress

1. Choose a mission not already marked done (see `TODO.md`).
2. Generate some screenshots.
3. Examine for differences.
4. Hack hack hack.
5. See if the differences are resolved.
6. PR with automerge.

---

## Quickstart (verify readiness)

Run these three commands. If all exit 0, the toolchain is ready:

```bash
bash scripts/skill-dev-check.sh                    # g++, clang++, cmake, ninja, SDL2
emcmake cmake --preset wasm 2>&1 | head -5         # Emscripten available (optional)
npx playwright --version                            # Playwright available (optional)
```

---

## Canonical Build Commands

### Native Linux (GCC or Clang)

```bash
bash scripts/skill-native-build.sh                 # both targets (ra + td)
bash scripts/skill-native-build.sh ra              # RA only
bash scripts/skill-native-build.sh td              # TD only
CXX=clang++ bash scripts/skill-native-build.sh     # use clang
```

Binaries land in `build/ra` and `build/td`.

### WASM (Emscripten)

```bash
bash scripts/skill-ci-wasm-smoke.sh                # full cycle: configure + build + validate + smoke
```

This configures via `emcmake cmake --preset wasm`, builds `ra.wasm` and `td.wasm`,
validates WASM magic and size, then runs T1+T2 boot smoke tests.

Outputs: `build-wasm/ra.wasm`, `build-wasm/td.wasm`, `build-wasm/ra.html`,
`build-wasm/td.html`.

---

## Canonical Test Commands

### Smoke tests (fast, always run)

```bash
# WASM boot smoke (requires build-wasm/ artifacts and Xvfb)
source scripts/skill-xvfb-ensure.sh :99 1280x1024x24
source scripts/skill-wasm-serve.sh 8080
DISPLAY=:99 npx playwright test e2e/regression/T1-ra-wasm-boot.spec.ts
DISPLAY=:99 npx playwright test e2e/regression/T2-td-wasm-boot.spec.ts
```

### Full E2E (one command)

```bash
bash scripts/skill-run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
bash scripts/skill-run-e2e.sh e2e/tim710-wasm-parity.spec.ts --grep "Tier 1"
```

Starts Xvfb, starts the WASM server, runs the test, and cleans up both.

### LP64 audit

```bash
python3 scripts/lint-lp64.py --errors-only           # gate: must exit 0
cmake --build build --target lint-lp64               # CMake target version
```

### VQA pixel-diff

```bash
python3 scripts/vqa-pixel-diff.py e2e/goldens/vqa/test.vqa --frames 0,1,2 --threshold 5
```

### Parity comparison (Wine OG vs WASM/Linux)

```bash
python3 scripts/parity-compare.py \
    e2e/screenshots/wine-ra-menu.png \
    e2e/screenshots/tim710-wasm-menu.png \
    --label "RA-menu" --threshold-ssim 0.90
```

### Data integrity

```bash
python3 scripts/ra-data-verify.py /path/to/data      # RA MIX checksums
python3 scripts/td-data-verify.py /path/to/data      # TD MIX checksums
```

---

## Change Cycle

The standard loop for an agent working on a fix:

```
1. Edit source
2. Build       → bash scripts/skill-native-build.sh ra
3. LP64 audit  → python3 scripts/lint-lp64.py --errors-only
4. Smoke test  → bash scripts/skill-run-e2e.sh e2e/regression/T1-ra-wasm-boot.spec.ts
5. Commit      → git commit -m "short imperative subject"
6. Push        → git push
```

If the change touches rendering or palette paths, add a parity check:

```bash
python3 scripts/parity-compare.py <wine-ref> <wasm-screenshot> --threshold-ssim 0.90
```

---

## Parity Investigation Workflow

When investigating a visual difference between the original 1996 binary
(under Wine) and the Linux/WASM ports, the tooling spans three directories.

### Gameplay Frame Parity (native + WASM vs Wine OG)

For mission screenshots, the Wine OG (ra95/Wine) is the **reference**.  The
pipeline generates goldens from Wine, captures the same mission state from
native Linux and WASM, and runs a three-way SSIM comparison.

**Full workflow:**

```bash
# Build prerequisites
bash scripts/skill-native-build.sh ra
bash scripts/build-cnc-ddraw.sh

# Generate gameplay goldens from Wine (the reference)
bash scripts/gen-gameplay-goldens.sh allied-l1
bash scripts/gen-gameplay-goldens.sh soviet-l1

# Capture same state from native Linux
bash scripts/native-capture.sh allied-l1
bash scripts/native-capture.sh soviet-l1

# Capture same state from WASM
npx playwright test e2e/tim708-wasm-allied-l1.spec.ts
npx playwright test e2e/tim710-wasm-parity.spec.ts --grep "Soviet L1"

# Compare three-way
bash scripts/parity-report.sh allied-l1 --mode gameplay --targets wine,wasm,native
bash scripts/parity-report.sh soviet-l1 --mode gameplay --targets wine,wasm,native
```

**Artifact layout for gameplay parity:**

```
e2e/
  goldens/gameplay/<mission>/
    golden.png              # Wine OG reference frame
    manifest.json           # {"mode":"gameplay","total_frames":1,…}
  screenshots/
    wine-gameplay/<mission>/capture.png      # Wine duplicate (always PASS vs golden)
    native-gameplay/<mission>/capture.png    # Native Linux ffmpeg x11grab capture
    wasm-gameplay/<mission>/capture.png     # WASM Playwright canvas screenshot
    diffs/diff-<mission>-<target>.png       # Pixel diff visualisation
```

**Mechanism for native mission start:**

| Mission | Autostart mechanism |
|---------|-------------------|
| Allied L1 | `RA_AUTOSTART=1` → SCG01EA.INI (built-in) |
| Soviet L1 | `RA_AUTOSTART=1` + `RA_AUTOSTART_SCENARIO.FLAG` containing `SCU01EA.INI` (TIM-812 override) |

The native build skips intro VQAs when `RA_AUTOSTART=1` is set (TIM-500),
going directly to Start_Scenario.  Mission terrain renders within 5-10s.

**Key scripts:**

| Script | Purpose |
|--------|---------|
| `scripts/native-capture.sh` | Launch native RA under Xvfb, auto-start mission, capture screenshot |
| `scripts/gen-gameplay-goldens.sh` | Run Wine capture + stage golden + manifest.json |
| `scripts/parity-report.sh --mode gameplay` | Three-way SSIM comparison for single-frame gameplay scenes |

### Step-by-step for a VQA cinematic frame comparison

The VQA pipeline (cinematic parity) uses `--mode vqa` (default) and the
multi-frame `e2e/goldens/vqa/<stem>/` layout.

**1. Generate golden reference frames** (decoder output, validated against ffmpeg):

```bash
# Single VQA:
python3 scripts/gen-vqa-golden.py /path/to/ENGLISH.VQA e2e/goldens/vqa/ENGLISH 4

# All intro VQAs at once:
bash scripts/gen-all-vqa-goldens.sh /path/to/RA/CD1 e2e/goldens/vqa 4
```

Goldens land as `e2e/goldens/vqa/<stem>/frame_0001.png` … `frame_0004.png`.

**2. Capture the same scene from each target:**

| Target | Input driver | Frame capture | Frame-exact? |
|--------|-------------|---------------|--------------|
| ra95/Wine | `tools/wine-input/ra-sendinput.exe` (SendInput → DInput) | `tools/wine-input/ra-screenshot.exe` (BitBlt from window DC) | Timing-approximate only (can't hook the closed binary's VQA player) |
| Linux native | xdotool or stdin | ffmpeg x11grab, or add `RA_VQA_DUMP_FRAME=N` env var to vqa_player.cpp | Yes (we own vqa_player.cpp) |
| WASM | Playwright `page.click()` / `page.keyboard.press()` | `page.screenshot()` or canvas pixel dump | Yes (we own vqa_player.cpp) |

**3. Compare:**

```bash
# Compare a single frame:
python3 scripts/parity-compare.py \
    e2e/goldens/vqa/ENGLISH/frame_0002.png \
    e2e/screenshots/wine-english-frame2.png \
    --label "ENGLISH-frame2" --threshold-ssim 0.90

# Or run the full three-way report for all frames at once:
bash scripts/parity-report.sh ENGLISH --targets wine,wasm,native
```

### The Wine input/capture tools (key capability)

`tools/wine-input/` contains Win32 helpers that run inside the Wine process tree:

| Tool | Does | Why not xdotool |
|------|------|-----------------|
| `ra-sendinput.exe` | Keyboard + mouse injection to DInput | xdotool/XTest generate WM_CHAR but don't fire WH_KEYBOARD_LL hooks — DInput never sees the press. SendInput does. |
| `ra-screenshot.exe` | Captures rendered frame via BitBlt from window DC | ffmpeg x11grab sees the X11 backing store which is often black under Wine 11. BitBlt hits the CPU-side mirror which contains the actual frame. |
| `td-sendinput.exe` | Same for Tiberian Dawn | — |
| `td-screenshot.exe` | Same for Tiberian Dawn | — |

Build them with `i686-w64-mingw32-gcc` (automated in `wine-allied-l1.sh`).
The `seq` subcommand of `ra-sendinput.exe` can chain a full navigation:
`s=2000;c=322,183;s=2000;c=470,244` (sleep 2s, click, sleep 2s, click).

---

## Skill Index

When an agent hits a symptom, it should read the corresponding skill file.
Skills are at `skills/<name>/SKILL.md`.

| Domain | Skill | Trigger symptoms |
|--------|-------|-----------------|
| Native build | `skills/native-build/SKILL.md` | CMake failure, missing SDL2, case-sensitivity include errors, LP64 struct crashes |
| WASM/Emscripten | `skills/emscripten/SKILL.md` | EM_ASM silent no-op, black screen, garbled audio, `onRuntimeInitialized` timeout |
| E2E testing | `skills/e2e-testing/SKILL.md` | Playwright pageerror, `__wasmReady` never set, blank Xvfb screenshots |
| Wine testing | `skills/wine-testing/SKILL.md` | Wine prefix failure, DirectDraw blank, DirectSound dialog blocking automation |
| VQA codec | `skills/vqa-codec/SKILL.md` | Block-aligned corruption, palette errors, CBFZ/CBPZ decode bugs, pixel-diff CI failure |
| Parity comparison | `skills/parity-comparison/SKILL.md` | SSIM below threshold, parity regression, Wine OG capture failure |
| CI/CD | `skills/ci-cd/SKILL.md` | CI job failure, release workflow broken, gh-pages deploy not updating |

Each skill has a Phase 0 smoke check and a Phase 1 symptom-classification table.

---

## Critical Invariants

Things an agent must never break:

1. **LP64 correctness.** `sizeof(long)==8` on Linux. Never pass a `long` where a
   32-bit value is expected. Run `scripts/lint-lp64.py --errors-only` after every
   change that touches struct layouts, typedefs, or binary I/O.

2. **0 exit codes from companion scripts.** Scripts prefixed `skill-` must exit 0
   on success. If you modify one, verify with that script's own smoke test.

3. **WASM binary validation.** `ra.wasm` and `td.wasm` must be >1MB and have
   valid WASM magic (`\x00asm`). Build with `skill-ci-wasm-smoke.sh` to verify.

4. **COOP/COEP headers.** WASM requires `Cross-Origin-Opener-Policy: same-origin`
   and `Cross-Origin-Embedder-Policy: require-corp` for SharedArrayBuffer. The
   dev server (`wasm/serve-coop.py`) provides these. Never remove them.

5. **PROXY_TO_PTHREAD boundary.** Under Emscripten's `-sPROXY_TO_PTHREAD`, the game
   loop runs in a Worker. Any `EM_ASM` that touches the DOM, `Module['_key']`, or
   Web Audio must use `MAIN_THREAD_EM_ASM`. See `skills/emscripten/SKILL.md` §2.1.

6. **Smoke-test design rule.** Every rendering test must include a pixel-range or
   pixel-diff assertion — fill% alone is insufficient. See
   `docs/smoke-test-design-rule.md`.

7. **Include shim regeneration.** After adding a new `#include` to any .CPP file,
   run `python3 scripts/generate-include-shim.py --repo-root . --shim-root build/include-shim --quiet`.

---

## Key Scripts Reference

All reusable scripts live in `scripts/`. Historical build-pass scripts have been
moved to `scripts/archive/`.

| Script | Purpose |
|--------|---------|
| `skill-native-build.sh` | One-command native Linux build (ra + td) |
| `skill-ci-wasm-smoke.sh` | Full WASM CI cycle: configure + build + validate + smoke |
| `skill-run-e2e.sh` | Xvfb + WASM server + Playwright test + cleanup |
| `skill-xvfb-ensure.sh` | Idempotent Xvfb launcher (source it) |
| `skill-wasm-serve.sh` | Start WASM dev server with COOP/COEP (source it) |
| `skill-dev-check.sh` | Toolchain prerequisite check |
| `skill-vqa-check.sh` | VQA CI gate: regenerate → diff → pixel-diff |
| `skill-wine-check.sh` | Wine prerequisite check |
| `parity-compare.py` | SSIM + fill% + p99 pixel diff comparison |
| `parity-report.sh` | Three-way parity report: goldens vs captures (vqa + gameplay modes) |
| `lint-lp64.py` | LP64 static hazard audit |
| `vqa-pixel-diff.py` | Frame-level VQA pixel diff against ffmpeg |
| `cinematic-compare.py` | Cinematic/VQA batch comparison |
| `generate-include-shim.py` | Case-folding include shim generator |
| `*-data-verify.py` | MIX checksum verification |
| `gen-vqa-golden.py` | Decode VQA → N evenly-spaced golden PNG frames |
| `gen-all-vqa-goldens.sh` | Batch golden generation for all 6 intro VQAs |
| `gen-gameplay-goldens.sh` | Generate gameplay golden from Wine capture + manifest |
| `native-capture.sh` | Native Linux gameplay capture under Xvfb |
| `ci-local.sh` | Local CI: run all available gates, auto-skip missing deps |
| `wine-ra.sh` / `wine-td.sh` | Wine OG screenshot capture |
| `wine-ra-setup.sh` / `wine-td-setup.sh` | First-time Wine prefix setup |
| `wine-allied-l1.sh` | Wine → Allied Mission 1 gameplay capture |
| `wine-soviet-l1.sh` | Wine → Soviet Mission 1 gameplay capture |
| `wine-vqa-capture.sh` | Wine → VQA playback frame capture via ra-screenshot.exe |
| `tools/wine-input/ra-sendinput.exe` | SendInput keyboard/mouse injector (reaches DInput) |
| `tools/wine-input/ra-screenshot.exe` | BitBlt frame capture from inside Wine |
| `build-cnc-ddraw.sh` | Build cnc-ddraw with scanline_double patch |

---

## Project Docs

| Doc | Content |
|-----|---------|
| `ARCH.md` | Port architecture, build system, source layout |
| `ROADMAP.md` | Completed milestones and future direction |
| `docs/emscripten-playbook.md` | WASM symptom → root-cause → fix reference |
| `docs/lp64-audit.md` | LP64 porting hazards and fixes |
| `docs/smoke-test-design-rule.md` | Assertion design rules for smoke tests |
| `docs/codec-testing.md` | VQA codec testing methodology |
| `CLAUDE.md` | Claude/Paperclip-specific worktree protocol |
