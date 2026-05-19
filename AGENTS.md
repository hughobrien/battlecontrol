# Agents — Entry Point

_battlecontrol — C&C Red Alert + Tiberian Dawn port to Linux/WASM_

**Game naming note:** "C&C95" is the original Command & Conquer (1995), which is the same game as Tiberian Dawn (TD). Any script, reference, or data path mentioning C&C95/GDI/Nod belongs to TD, not Red Alert (RA).

This is the file an AI coding agent should read first when landing in this repo.
It covers the quickstart, canonical build/test commands, the change cycle, and the
skill index. For deep architecture, see `ARCH.md`. For human-facing docs, see
`README.md`.

## ⚠️ Prerequisite: Enable Nix experimental features

Before running any Nix commands, enable the required experimental features:

```bash
mkdir -p ~/.config/nix
cat >> ~/.config/nix/nix.conf << 'EOF'
experimental-features = nix-command flakes
EOF
```

This lets you omit `--extra-experimental-features` from every Nix invocation.

## ⚠️ Critical: Verify you are inside `nix develop`

Every `git commit`, build command, test runner, linter, or script invocation in
this project **must** be run inside the Nix development shell. Outside the shell,
tools like `nixfmt`, `clang-tidy`, `shfmt`, `yamllint`, and `ruff` are not on PATH.
The pre-commit hook will fail with cryptic errors.

### Agent self-check block

> **Agent instructions:** At startup, check `$IN_NIX_SHELL`. If it is empty or unset,
> print the message below to the user and stop. Do not attempt to run any commands.

```bash
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  echo ""
  echo "============================================"
  echo " ERROR: Not inside nix develop shell"
  echo "============================================"
  echo " Reinvoke the agent with:"
  echo ""
  echo "   nix develop --command <agent-name>"
  echo ""
  echo " Example:"
  echo "   nix develop --command pi"
  echo "   nix develop --command claude"
  echo "   nix develop --command aider"
  echo "============================================"
  exit 1
fi
```

### Verify before proceeding

Once inside the dev shell, verify everything is available:

```bash
echo "IN_NIX_SHELL=$IN_NIX_SHELL"
```

Should print `IN_NIX_SHELL=1` (or another non-empty value). If it does, proceed.

### Correct

Once inside the dev shell, run commands directly — no `nix develop --command` wrapper needed:

```bash
git commit -m "..."
nix run .#lint
python3 scripts/lint-lp64.py
```

### Common mistakes

| ❌ Wrong | ✅ Correct |
|----------|-----------|
| `nix develop --command git commit ...` (unnecessary wrapper) | `git commit ...` |
| Running outside dev shell — tools missing from PATH | Enter `nix develop` first |

> expect to run inside the dev shell and do not wrap themselves.

## ⚠️ After every PR: always enable automerge

Every pull request **must** have automerge enabled immediately after creation:

```bash
gh pr merge --auto --merge
```

This is step 5 in the Done workflow below. Never merge manually. If CI fails,
automerge will wait until it passes. If CI is green, the PR merges automatically.

---

## ⚠️ Before every push: run `nix run .#test`

**GitHub CI is slow (5–15 min per job).** Always run the test gate locally
before pushing to catch failures instantly:

```bash
nix run .#test
```

This runs lint → build → boot tests, diff-gated against origin/master.
For the full regression suite (all targets, every test): `nix run .#regression`.

> **Never push without running `nix run .#test` first.** A quick local check
> saves 15 minutes of CI wait-and-retry.

---

## How to Make Progress

1. Choose a mission not already marked done (see `TODO.md`).
2. Generate some screenshots.
3. Examine for differences.
4. Hack hack hack.
5. See if the differences are resolved.
6. PR with automerge.

---

## Quickstart (verify readiness)

All workflows are available via `nix run .#<name>` commands. Run:

```
nix run .#test
```


---

## Canonical Build Commands

### Native Linux (CMake)

```bash
# Build RA native
cmake --preset linux-native && cmake --build build --target ra --parallel

# Build TD native
cmake --build build --target td --parallel

# Or use the tier apps:
nix run .#build
```

Binaries land in `build/ra` and `build/td`

### WASM (Emscripten)

```bash
# Build RA WASM
emcmake cmake --preset wasm && cmake --build build-wasm --target ra --parallel

# Build TD WASM
cmake --build build-wasm --target td --parallel
```

Outputs: `build-wasm/ra.wasm`, `build-wasm/td.wasm`, `build-wasm/ra.html`,
`build-wasm/td.html`

> ⚠️ **Stale CMake cache.** If the build fails with `include could not find
> requested file: /nix/store/.../Emscripten.cmake`, delete `build-wasm/` and
> reconfigure.

### GitHub Pages deploy (automatic)

On every merge to `master`, the `gh-pages.yml` workflow:
1. Builds `ra.wasm` + `td.wasm`
2. Runs smoke tests (Chromium + Firefox)
3. Runs asset-gated regression tests (if secrets configured)
4. Deploys to GitHub Pages

The deploy directory is assembled from `build-wasm/*.wasm`, `build-wasm/*.js`,
`build-wasm/*.html`, plus `wasm/preloader.js` and
`wasm/coi-serviceworker.min.js`. A `version.json` manifest is generated with
commit SHA and build timestamp.

Manual deploy (legacy):

```bash
gh workflow run "GitHub Pages Deploy"
```

---

## Canonical Test Commands

### Boot tests (CI tier, fast)

```bash
nix run .#test
```

### Full regression (all targets)

```bash
nix run .#regression
```

### LP64 audit

```bash
python3 scripts/lint-lp64.py --errors-only
```

### VQA decode/compare

```bash
python3 scripts/vqa-decode.py --vqa NAME --mix PATH --out DIR [--duration N] [--engine {ffmpeg,native}]
python3 scripts/vqa-compare.py -- <dirA> <dirB>
```

### Parity comparison (Wine OG vs WASM/Linux)

```bash
nix run .#parity -- check <scene> [--mode vqa|gameplay] [--targets <t>]
```


---

## Edit-Compile-Test Loop

The standard loop for an agent working on a fix:

```
1. Edit source
2. Build       → nix run .#build
3. LP64 audit  → python3 scripts/lint-lp64.py --errors-only
4. Test        → nix run .#test
5. CI check    → nix run .#regression   (full suite before push)
6. Commit      → git commit -m "short imperative subject"
```

> **Step 5 is mandatory.** Never skip local regression before pushing.

If the change touches rendering or palette paths, add a parity check:

```bash
nix run .#parity -- check <scene>
```

See [Branch and PR Workflow](#branch-and-pr-workflow) below for the push, PR,
and automerge steps.

---

## Parity Investigation Workflow

When investigating a visual difference between the original 1996 binary
(under Wine) and the Linux/WASM ports, the tooling spans three directories.

### Gameplay Frame Parity (native + WASM vs Wine OG)

For mission screenshots, the Wine OG (ra95/Wine) is the **reference**.  The
pipeline generates goldens from Wine, captures the same mission state from
native Linux and WASM, and runs a three-way SSIM comparison.

**Full workflow:**

```
# Build prerequisites
build_native(target: "ra")
# (build-cnc-ddraw.sh still manual)

# Generate gameplay goldens from Wine (the reference)
python3 scripts/capture-checkpoint.py mission allied-l1 --targets wine,native,wasm
python3 scripts/capture-checkpoint.py mission soviet-l1 --targets wine,native,wasm

# Capture same state from WASM
run_e2e_test(spec: "e2e/tim708-wasm-allied-l1.spec.ts")
run_e2e_test(spec: "e2e/tim710-wasm-parity.spec.ts", args: ["--grep", "Soviet L1"])

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

**Mechanism for capture (all three targets):**

| Target | Mechanism |
|--------|-----------|
| Wine OG | `python3 scripts/capture-checkpoint.py mission <id> --targets wine` — binary patches + Xvfb + cnc-ddraw |
| Native | `python3 scripts/capture-checkpoint.py mission <id> --targets native` — RA_AUTOSTART + Xvfb |
| WASM | `python3 scripts/capture-checkpoint.py mission <id> --targets wasm` — Playwright + dev server |

The native build skips intro VQAs when `RA_AUTOSTART=1` is set (TIM-500),
going directly to Start_Scenario.  Mission terrain renders within 5-10s.

The native build skips intro VQAs when `RA_AUTOSTART=1` is set (TIM-500),
going directly to Start_Scenario.  Mission terrain renders within 5-10s.

**Key scripts:**

| Script | Purpose |
|--------|---------|
| `scripts/capture-checkpoint.py` | Unified capture orchestrator: run any mission/VQA at any frame across Wine/native/WASM targets |
| `scripts/drivers/*.py` | Capture drivers: wine.py, native.py, wasm.py, compare.py |
| `scripts/parity-report.sh --mode gameplay` | Three-way SSIM comparison for single-frame gameplay scenes |

### Step-by-step for a VQA cinematic frame comparison

The VQA pipeline (cinematic parity) uses `--mode vqa` (default) and the
multi-frame `e2e/goldens/vqa/<stem>/` layout.

**1. Decode VQA frames** (using native decoder or ffmpeg):

```bash
# Decode a VQA file with the native decoder:
python3 scripts/vqa-decode.py --vqa ENGLISH.VQA --out /tmp/vqa-frames --duration 4 --engine native

# Or use ffmpeg:
python3 scripts/vqa-decode.py --vqa ENGLISH.VQA --out /tmp/vqa-frames-ffmpeg --duration 4 --engine ffmpeg
```

Decoded frames land in the output directory as PNG files.

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

When an agent hits a symptom, read the corresponding skill for diagnostic guidance.

| Domain | Skill | Extension tools | Trigger symptoms |
|--------|-------|----------------|-----------------|
| Native build | `skills/native-build/` | `scripts/build-native.sh`, `nix run .#build` | CMake failure, missing SDL2, LP64 crashes |
| WASM/Emscripten | `skills/emscripten/` | `emcmake cmake --preset wasm`, `nix run .#build` | EM_ASM silent, black screen, garbled audio |
| E2E testing | `skills/e2e-testing/` | `scripts/serve-wasm.sh`, `scripts/test-runner.sh` | pageerror, `__wasmReady` timeout, blank Xvfb |
| VQA codec | `skills/vqa-codec/` | `python3 scripts/vqa-compare.py` | Block corruption, palette errors, CI failure |
| Parity comparison | `skills/parity-comparison/` | `nix run .#parity` | SSIM regression, parity failure |
| CI/CD | `skills/ci-cd/` | `nix run .#build`, `nix run .#test` | CI failure, release broken, deploy stuck |
| GHA updater | `skills/gha-updater/` | — | Stale action versions, Node.js deprecation warnings |
| Nix shell escaping | `skills/nix-shell-escaping/` | — | nix-shell quoting errors, variable expansion traps |

Each skill has a symptom-classification table and diagnostic procedures.

---

## Critical Invariants

Things an agent must never break:

1. **LP64 correctness.** `sizeof(long)==8` on Linux. Never pass a `long` where a
   32-bit value is expected. Run `scripts/lint-lp64.py --errors-only` after every
   change that touches struct layouts, typedefs, or binary I/O.

2. **0 exit codes from companion scripts.** Scripts prefixed `skill-` must exit 0
   on success. If you modify one, verify with that script's own smoke test.

3. **WASM binary validation.** `ra.wasm` and `td.wasm` must be >1MB and have
   valid WASM magic (`\x00asm`). The WASM build scripts perform this check
   automatically.

4. **COOP/COEP headers.** WASM requires `Cross-Origin-Opener-Policy: same-origin`
   and `Cross-Origin-Embedder-Policy: require-corp` for SharedArrayBuffer. The
   dev server (`wasm/serve-coop.py`) provides these. Never remove them.

5. **PROXY_TO_PTHREAD boundary.** Under Emscripten's `-sPROXY_TO_PTHREAD`, the game
   loop runs in a Worker. Any `EM_ASM` that touches the DOM, `Module['_key']`, or
   Web Audio must use `MAIN_THREAD_EM_ASM`. See `skills/emscripten/SKILL.md` §2.1.

6. **Smoke-test design rule.** Every rendering test must include a pixel-range or
   pixel-diff assertion — fill% alone is insufficient. See
   `docs/smoke-test-design-rule.md`.

7. **Include shim regeneration.** CMake auto-runs `generate-include-shim.py` as a
   build dependency. After adding a new `#include` or header, a rebuild regenerates
   it automatically. For manual regeneration: `python3 scripts/generate-include-shim.py`.

8. **Never use `git add -A` (or `git add .` / `git add --all`).** Always stage
   specific files with explicit paths. Blind `-A` picks up unrelated changes and
   risks committing garbage (node_modules/ logs, build artifacts, generated files).

9. **Capture scripts are in `scripts/drivers/`.** The old per-campaign capture scripts
   (`wine-allied-l1.sh`, `wine-soviet-l1.sh`, `wine-vqa-capture.sh`, `wine-gameplay.sh`,
   `native-capture.sh`, `gen-gameplay-goldens.sh`) have been subsumed by the Python
   `capture-checkpoint.py` orchestrator and its drivers. Use `capture-checkpoint`
   for all new capture work.

10. **Wine builds are FPS-limited via cnc-ddraw.** All Wine capture scripts set
   `maxfps=30` in `ddraw.ini` (under `[ddraw]`). This applies to both RA and TD.
   Never remove or change this without updating all remaining scripts:
   `wine-nod-l1.sh`, `wine-nod-m1.sh`, `wine-gdi-m1.sh`,

---

## Key Scripts Reference

All reusable scripts live in `scripts/`.

| Script / Tool | Purpose |
|---------------|---------|
| `build-native.sh` | One-command native Linux build (ra + td) |
| `build-wasm/` | WASM build output directory |
| `serve-wasm.sh` | WASM dev server with COOP/COEP |
| `toolchain-check.sh` | Toolchain prerequisite check |
| `vqa-decode.py` | VQA decode from MIX (wraps tools/vqa_dump + ffmpeg) |
| `vqa-compare.py` | Compare two VQA decode output dirs (video + audio) |
| `tools/vqa_dump/vqa_dump.cpp` | Standalone C++ VQA decoder, no external deps |
| `parity-compare.py` | SSIM + fill% + p99 pixel diff |
| `*-data-verify.py` | MIX checksum verification |
| `wine-check.sh` | Wine prerequisite check |
| `wine-ra.sh` / `wine-td.sh` | Wine OG screenshot capture |
| `xvfb-ensure.sh` | Idempotent Xvfb launcher (source it) |
| `parity-report.sh` | Three-way parity report (vqa + gameplay modes) |
| `lint-lp64.py` | LP64 static hazard audit |
| `generate-include-shim.py` | Case-folding include shim generator |
| `capture-checkpoint.py` | Unified capture orchestrator: run any mission/VQA at any frame across Wine/native/WASM targets |
| `drivers/wine.py` | Wine capture driver (generalizes wine-allied-l1.sh, wine-vqa-capture.sh) |
| `drivers/native.py` | Native capture driver (generalizes native-capture.sh) |
| `drivers/wasm.py` | WASM capture driver (Playwright headless) |
| `drivers/compare.py` | Wrapper around parity-compare.py for multi-target comparison |
| `wine-ra-setup.sh` / `wine-td-setup.sh` | First-time Wine prefix setup |
| `ra-autostart-patch.py` | Binary patch for RA95.EXE: zero-click auto-boot into any Allied mission at Normal difficulty. See [Auto-launch patch](#auto-launch-patch-wine) below. |
| `ra-scenario-patch.py` | Replace hardcoded mission name in RA95.EXE (e.g. SCG01EA→SCG02EA) |
| `tools/wine-input/*` | SendInput injectors + BitBlt capture inside Wine |
| `tools/cnc-ddraw/` flake | Build cnc-ddraw with scanline_double patch — `nix build path:./tools/cnc-ddraw#cnc-ddraw` |

---

## Auto-launch patch (Wine)

The `ra-autostart-patch.py` + `ra-scenario-patch.py` chain applies binary patches
to RA95.EXE so the game boots directly into any Allied mission at Normal difficulty
with zero menu clicks — no SendInput automation needed.

### Patch chain order

Apply in this order (existing Wine scripts apply the first 5 at runtime):

```bash
python3 scripts/nocd-patch.py RA95.EXE
python3 scripts/ddscl-patch.py RA95.EXE
printf '\x00' | dd of=RA95.EXE bs=1 seek=$((0x1BFCB7)) conv=notrunc  # cdlabel
python3 scripts/focus-skip-patch.py RA95.EXE
python3 scripts/game-in-focus-patch.py RA95.EXE
python3 scripts/vqa-skip-patch.py RA95.EXE
python3 scripts/ra/ra-scenario-patch.py RA95.EXE SCG02EA   # target mission
python3 scripts/ra/ra-autostart-patch.py RA95.EXE           # auto-boot
```

### What it does

Four patches to `Select_Game()` in the RA95.EXE binary:

| Patch | Effect |
|-------|--------|
| `esi=4` → `esi=1` | Forces `selection=SEL_START_NEW_GAME` — enters new-game handler, skips Main_Menu |
| NOP `je` to Fetch_Difficulty | Always sets DIFF_NORMAL — no difficulty dialog |
| `jne` → `jmp` to Choose_Side | Skips faction dialog — Choose_Side just plays a movie (already NOPed by vqa-skip) |
| NOP `jne` to Soviet string | Always picks SCG01EA.INI (already patched to target by ra-scenario-patch) |

### Mission naming

| Filename | Mission |
|----------|---------|
| `SCG01EA.INI` | Allied L1 |
| `SCG02EA.INI` | Allied L2 |
| `SCG03EA.INI` | Allied L3 |
| `SCU01EA.INI` | Soviet L1 |

Difficulty is baked into the game's handicap system, not the filename — Normal
is the default for the `IsFromInstall` code path (which the patches activate).
The scenario INI data lives inside `MAIN.MIX`.

### Native/WASM equivalent

For the Linux native or WASM builds, use environment variables instead of binary
patches (already implemented in `INIT.CPP`):

```bash
RA_AUTOSTART=1 RA_AUTOSTART_SCENARIO=SCG02EA.INI ./build/ra/redalert
```

Difficulty defaults to Normal; an `RA_AUTOSTART_DIFFICULTY` env var is the
next step.

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
| *(below)* | [Branch and PR Workflow](#branch-and-pr-workflow) |

---

## Branch and PR Workflow

All work is done on branches. Never commit directly to `master`.

### Create a branch

```bash
git fetch origin
git checkout -b <name> origin/master
```

### Work and commit

```bash
# Make changes, then:
git add <files>
git commit -m "<short imperative subject>"
```

### Push and PR

```bash
git fetch origin
git rebase origin/master --autostash
git push origin HEAD
gh pr create --repo hughobrien/battlecontrol \
  --title "<short description>" \
  --body "<details>" \
  --base master
```

### Enable automerge (required)

```bash
gh pr merge --auto --merge
```

> **Automerge is mandatory.** If CI is green, the PR merges automatically.
> If CI is red, it waits. Never merge manually.

### Cleanup after merge

```bash
git pull origin master
git branch -d <name>
git push origin --delete <name>
```

