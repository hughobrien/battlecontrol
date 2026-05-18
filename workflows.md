# Agent Workflows

This document describes the standard workflows an agent should follow to make
progress on this repo. Each workflow covers **when to use it**, **what to run**,
and **what success looks like**.

See [`scripts.md`](scripts.md) for the full command catalog across all surfaces
(nix apps, extension tools, scripts).

---

## Contents

1. [Prerequisites & Readiness](#1-prerequisites--readiness)
2. [Edit-Compile-Test Loop](#2-edit-compile-test-loop)
3. [Build Workflows](#3-build-workflows)
4. [Test Workflows](#4-test-workflows)
5. [CI Gate](#5-ci-gate)
6. [Parity Verification](#6-parity-verification)
7. [Capture Workflows](#7-capture-workflows)
8. [Branch & PR Workflow](#8-branch--pr-workflow)
9. [Release Process](#9-release-process)

---

## 1. Prerequisites & Readiness

### When
At session start, or when entering the repo for the first time.

### Workflow

```bash
# 1. Verify you're inside nix develop (AGENTS.md §self-check):
if [[ -z "${IN_NIX_SHELL:-}" ]]; then
  echo "ERROR: Not inside nix develop shell"
  echo "Reinvoke: nix develop --command <agent>"
  exit 1
fi

# 2. Check toolchain:
nix run .#toolchain-check
# Should print all tools found. Exit 0 = ready.

# 3. Verify CI would pass locally:
nix run .#ci
# Runs all available gates. Auto-skips missing deps.
```

### Success
- `IN_NIX_SHELL` is set
- `toolchain_check()` or `nix run .#toolchain-check` exits 0
- `nix run .#ci` passes all enabled gates

---

## 2. Edit-Compile-Test Loop

### When
After editing any C++ source file, or any code change that affects the build.

### Workflow

```bash
# 1. Regenerate include shim (required after adding #include or headers):
nix run .#include-shim

# 2. Run LP64 lint (must pass — blocking gate):
nix run .#lint-lp64

# 3. Build (choose one):
nix run .#build-native         # native Linux RA + TD (fast iteration)
nix run .#build-wasm           # WASM RA + TD (slower, for browser testing)

# 4. Run the most relevant smoke test:
#    For changes affecting RA WASM:
nix run .#test -- e2e/regression/T1-ra-wasm-boot.spec.ts
#    For changes affecting TD WASM:
nix run .#test -- e2e/regression/T2-td-wasm-boot.spec.ts
#    For native changes:
nix run .#smoke-ra
#    For native TD changes:
nix run .#smoke-td

# 5. Full CI check before push:
nix run .#ci
```

### Shorthand

```bash
# One-command native edit loop (shim → lint → build → smoke):
nix run .#edit-loop

# One-command WASM loop (build → validate → smoke):
nix run .#wasm-loop
```

### Critical rules
- **Never skip the LP64 lint** — it catches `sizeof(long)==8` bugs that
  silently corrupt struct layouts
- **Never push without `nix run .#ci`** — CI is slow (5-15 min per job);
  local check catches the same failures in ~30 seconds
- **Never use `git add -A`** — stage specific files only

---

## 3. Build Workflows

### 3.1 Native Build

### When
Developing locally, debugging with GDB/rr/ASAN, or running native smoke tests.

```bash
# Build both RA + TD (clang, default):
nix run .#build-native

# Build a single target:
build_native(target: "ra", compiler: "clang")

# Clean rebuild:
build_native(target: "both", compiler: "clang", clean: true)
```

**Output:** `build/ra/redalert` and `build/td/tiberiandawn`

### 3.2 WASM Build

### When
Testing browser builds, running e2e tests, or preparing a deploy.

```bash
# Build both RA + TD WASM:
nix run .#build-wasm

# Build a single target:
build_wasm(target: "ra")

# Clean rebuild (fixes stale CMake cache):
build_wasm(target: "ra", clean: true)
```

**Output:** `build-wasm/ra.wasm`, `build-wasm/td.wasm`, `build-wasm/ra.html`, `build-wasm/td.html`

**Output validation:**
```bash
nix run .#validate-wasm
# Must show: ra.wasm: OK (magic \x00asm, size >1MB)
# Must show: td.wasm: OK (magic \x00asm, size >1MB)
```

**⚠️ Stale CMake cache:** If `build_wasm` fails with `include could not find
requested file: /nix/store/.../Emscripten.cmake`, delete `build-wasm/` first,
then rebuild with `clean: true`.

---

## 4. Test Workflows

### 4.1 Regression Suite (T1–T12)

The regression suite covers WASM boot, menu rendering, mission start, audio
pitch, and gameplay SSIM for both RA and TD.

```bash
# CI tier — T1 + T2 (asset-free, no game data needed):
REGRESSION_TIER=ci bash scripts/regression-suite.sh

# Full tier — all tests (requires licensed CnCRemastered MIX files):
REGRESSION_TIER=full bash scripts/regression-suite.sh
```

### 4.2 Single E2E Test

```bash
# Run a specific Playwright spec:
nix run .#test -- e2e/regression/T1-ra-wasm-boot.spec.ts

# Run with extra Playwright args:
run_e2e_test(spec: "e2e/regression/T9-ra-wasm-mission-start.spec.ts",
             args: ["--grep", "Allied L1", "--reporter", "list"])
```

### 4.3 Native Smoke Tests

```bash
# RA: 30s run with RA_AUTOSTART=1, verify 100+ frames:
nix run .#smoke-ra

# TD: debug cheat progression (credits, tech, map reveal, auto-win):
nix run .#smoke-td
```

### 4.4 WASM Screenshot

```bash
# Build, serve, capture a screenshot:
wasm_screenshot(target: "ra", waitMs: 5000)
```

### 4.5 Test Design Rules

When writing a new test, follow the [smoke-test design rule](docs/smoke-test-design-rule.md):
- Write the assertion before the harness
- List numbered acceptance criteria in the test header
- Rendering tests need pixel-diff or colour-range assertions (fill% alone is insufficient)
- Audio tests need frequency-domain assertions

---

## 5. CI Gate

### When
Before every push. Never push to GitHub without running this first.

```bash
# Full local CI (all available gates):
nix run .#ci

# WASM-only:
ci_local(mode: "wasm-only")

# Native-only:
ci_local(mode: "native-only")
```

### Gates (auto-skip if dependencies missing)

| Gate | What It Checks | Requires |
|------|---------------|----------|
| G1 | Native build (RA + TD) | clang++, cmake, ninja, SDL2 |
| G2 | LP64 audit (hard pass) | python3 |
| G3 | WASM build + validate + smoke | emcmake |
| G5 | VQA pixel-diff (synthetic) | python3, ffmpeg |
| G6 | `/opt` path audit | rg (ripgrep) |

### GitHub CI

The CI pipeline (`.github/workflows/ci.yml`) runs on every push/PR to `master`:

| Job | What It Does | Timeout |
|-----|-------------|---------|
| **build** | Native RA + TD, ccache stats | 30m |
| **vqa-pixel-diff** | Synthetic VQA regeneration + pixel-diff | 10m |
| **wine-comparison** | Wine RA95.EXE + Playwright Tier 1/3 tests | 30m |
| **build-wasm** | WASM build, validate, smoke T1/T2, asset-gated T3/T6/T7/T8/T9 | 45m |
| **clang-tidy** | Static analysis (informational) | — |
| **cppcheck** | Static analysis (informational) | — |

---

## 6. Parity Verification

### When
After any rendering change, palette change, VQA codec change, or when adding
a new mission/scene to the parity gate.

### 6.1 VQA Codec Parity

```bash
# Synthetic VQA pixel-diff (no game data needed):
vqa_pixel_diff(mode: "synthetic", threshold: 5)

# Cinematic VQA comparison against ffmpeg:
vqa_pixel_diff(mode: "cinematic", mixPath: "/path/to/MAIN.MIX", threshold: 8)
```

### 6.2 Gameplay Parity (Three-Way Comparison)

Full workflow: Wine OG → Native Linux → WASM → SSIM compare.

```bash
# 1. Generate golden frames from VQA:
vqa_golden(vqaPath: "/path/to/ENGLISH.VQA", numFrames: 4)

# 2. Run full parity report:
parity_report(scene: "allied-l1", mode: "gameplay", targets: "wine,wasm,native")

# 3. Or compare two specific images:
parity_compare(
  imageA: "e2e/screenshots/wine-ra-menu.png",
  imageB: "e2e/screenshots/wasm-ra-menu.png",
  label: "RA-menu",
  thresholdSsim: 0.90
)
```

### 6.3 Data Integrity Check

Always verify game data before comparing:

```bash
data_verify(dir: "/path/to/game/data")
```

---

## 7. Capture Workflows

### When
Generating reference screenshots for regression tests or parity comparison.

```bash
# Wine OG capture (title + menu):
capture_wine(game: "ra")

# Native Linux gameplay capture (requires game data):
capture_native(mission: "allied-l1")

# Unified capture (any mission, any target):
nix run .#capture-checkpoint -- mission allied-l1 --targets wine,native,wasm
```

---

## 8. Branch & PR Workflow

### When
Starting new work or submitting changes.

### Create a branch

```bash
git fetch origin
git checkout -b <name> origin/master
```

### Work and commit

```bash
git add <specific-files>
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

### Enable automerge (mandatory)

```bash
gh pr merge --auto --merge
```

Never merge manually. Automerge waits if CI is red.

### Cleanup after merge

```bash
git pull origin master
git branch -d <name>
git push origin --delete <name>
```

### PR template checklist

Every PR should cover:
- [ ] CI passing (must run `nix run .#ci` before push)
- [ ] Does this fix have a Tiberian Dawn analogue?
- [ ] If adding/modifying a smoke test: assertion-first design, pixel-level checks

---

## 9. Release Process

### When
Cutting a new version (maintainer only).

### Pre-release checklist

- [ ] All CI checks on master green
- [ ] All regression tests pass (T1–T12)
- [ ] README release-notes updated
- [ ] WASM artifacts smoke-tested in browser
- [ ] Native binaries build and validate

### Cut

```bash
git tag v0.X.0
git push origin v0.X.0
```

The [`release.yml`](.github/workflows/release.yml) workflow triggers automatically
on `v*.*.*` tags, building four artifacts in parallel:
1. RA Linux x86_64 (`.tar.gz`)
2. TD Linux x86_64 (`.tar.gz`)
3. RA WASM (`.zip`)
4. TD WASM (`.zip`)

After all builds succeed, it creates a GitHub Release with auto-generated notes
and attaches all artifacts + SHA-256 checksums + manifest.

### Post-release

- [ ] Verify release published with all four artifacts
- [ ] Verify gh-pages deploy ran on master
- [ ] Test deployed WASM at GitHub Pages URL
- [ ] Download one native binary, verify it runs

---

## Appendix: Load the Right Skill

When hitting a specific problem, load the corresponding skill before debugging:

| Symptom / Task | Load Skill |
|----------------|-----------|
| WASM build failure, EM_ASM silent, black screen | `skills/emscripten/SKILL.md` |
| Native build failure, LP64 crash, SDL2 issue | `skills/native-build/SKILL.md` |
| Wine capture fails, blank screenshots | `skills/wine-testing/SKILL.md` |
| VQA corruption, pixel-diff failure | `skills/vqa-codec/SKILL.md` |
| E2E test failure, Playwright timeout, canvas blank | `skills/e2e-testing/SKILL.md` |
| CI job failure, release broken, ccache miss | `skills/ci-cd/SKILL.md` |
| SSIM regression, parity test failure | `skills/parity-comparison/SKILL.md` |
| Nix shell quoting error, flake app args | `skills/nix-shell-escaping/SKILL.md` |
| GHA version pin stale, Node.js deprecation | `skills/gha-updater/SKILL.md` |
| RA version identification, patches, saved games | `skills/ra-archive/SKILL.md` |
| Modding, RULES.INI, scenario INI, MIX editing | `skills/redalert-modding/SKILL.md` |

---

## Appendix: Quick Reference by Action

| You want to... | Run this |
|----------------|----------|
| Check toolchain | `nix run .#toolchain-check` |
| Build native | `nix run .#build-native` |
| Build WASM | `nix run .#build-wasm` |
| Validate WASM | `nix run .#validate-wasm` |
| Run LP64 lint | `nix run .#lint-lp64` |
| Run full lint | `nix run .#lint-all` |
| Regenerate include shim | `nix run .#include-shim` |
| Run e2e test | `nix run .#test -- <spec>` |
| Run CI gate | `nix run .#ci` |
| Serve WASM locally | `nix run .#serve` |
| Capture WASM screenshot | `wasm_screenshot(target: "ra")` |
| Compare two images | `nix run .#parity-compare -- <imgA> <imgB>` |
| Run parity report | `nix run .#parity-report -- --mode gameplay allied-l1` |
| Run VQA check | `nix run .#vqa-check` |
| Generate VQA golden | `nix run .#vqa-golden -- <vqa> <n>` |
| Run native smoke (RA) | `nix run .#smoke-ra` |
| Run native smoke (TD) | `nix run .#smoke-td` |
| Verify game data | `nix run .#data-verify -- <dir>` |
| Edit loop (native) | `nix run .#edit-loop` |
| Edit loop (WASM) | `nix run .#wasm-loop` |
