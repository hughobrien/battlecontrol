# Agents — Entry Point

_battlecontrol — C&C Red Alert + Tiberian Dawn port to Linux/WASM_

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
nix run .#lint-all
python3 scripts/lint-lp64.py
```

### Common mistakes

| ❌ Wrong | ✅ Correct |
|----------|-----------|
| `nix develop --command git commit ...` (unnecessary wrapper) | `git commit ...` |
| Running outside dev shell — tools missing from PATH | Enter `nix develop` first |

> The extension tools (e.g. `native_build`, `wasm_build`, `run_e2e_test`) also
> expect to run inside the dev shell and do not wrap themselves.

## ⚠️ After every PR: always enable automerge

Every pull request **must** have automerge enabled immediately after creation:

```bash
gh pr merge --auto --merge
```

This is step 5 in the Done workflow below. Never merge manually. If CI fails,
automerge will wait until it passes. If CI is green, the PR merges automatically.

---

## ⚠️ Before every push: run `ci_local` first

**GitHub CI is slow (5–15 min per job).** Always run the full CI gate locally
before pushing to catch failures instantly:

```bash
nix run .#ci
```

Or use the extension tool:

```
ci_local()
```

This runs every available gate: native build, WASM build, LP64 audit, VQA
pixel-diff, include shim, WASM validate. It auto-skips gates with missing
dependencies (e.g., no emcmake = WASM skipped), so it's safe to run anywhere.

> **Never push without running `ci_local` first.** A 30-second local check
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

The `pi-battlecontrol-dev` extension (`.pi/extensions/battlecontrol.ts`) registers
13 tools for build, test, screenshot, and parity workflows. Run:

```
toolchain_check()
```


---

## Canonical Build Commands

### Native Linux (GCC or Clang)

```
native_build(target: "both", compiler: "gcc")
native_build(target: "ra", compiler: "clang")
```

Binaries land in `build/ra` and `build/td`

### WASM (Emscripten)

```
wasm_build(target: "both")
wasm_validate(target: "both")
```

Outputs: `build-wasm/ra.wasm`, `build-wasm/td.wasm`, `build-wasm/ra.html`,
`build-wasm/td.html`

---

## Canonical Test Commands

### Smoke tests (fast, always run)

```
run_e2e_test(spec: "e2e/regression/T1-ra-wasm-boot.spec.ts")
run_e2e_test(spec: "e2e/regression/T2-td-wasm-boot.spec.ts")
```


### LP64 audit

```bash
nix run .#lint                                      # gate: must exit 0
```

### VQA pixel-diff

```
vqa_pixel_diff(mode: "synthetic", threshold: 5)
```

### Parity comparison (Wine OG vs WASM/Linux)

```
parity_compare(
  imageA: "e2e/screenshots/wine-ra-menu.png",
  imageB: "e2e/screenshots/tim710-wasm-menu.png",
  label: "RA-menu",
  thresholdSsim: 0.90
)
```

### Data integrity

```
data_verify(dir: "/path/to/data")
```

---

## Change Cycle

The standard loop for an agent working on a fix:

```
1. Edit source
2. Build       → native_build(target: "ra")
3. LP64 audit  → nix run .#lint
4. Smoke test  → run_e2e_test(spec: "e2e/regression/T1-ra-wasm-boot.spec.ts")
5. Commit      → git commit -m "short imperative subject"
6. CI check    → ci_local()  # ⚠️ run full CI locally before pushing
7. Push        → git push
8. Automerge   → gh pr merge --auto --merge
```

> **Step 6 is mandatory.** Never skip local CI. GitHub CI takes 5–15 minutes;
> `ci_local()` catches the same failures in ~30 seconds.

If the change touches rendering or palette paths, add a parity check:

```
parity_compare(imageA: "<wine-ref>", imageB: "<wasm-screenshot>", thresholdSsim: 0.90)
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

```
# Build prerequisites
native_build(target: "ra")
# (build-cnc-ddraw.sh still manual)

# Generate gameplay goldens from Wine (the reference)
bash scripts/gen-gameplay-goldens.sh allied-l1
bash scripts/gen-gameplay-goldens.sh soviet-l1

# Capture same state from native Linux (manual)
bash scripts/native-capture.sh allied-l1
bash scripts/native-capture.sh soviet-l1

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

When an agent hits a symptom, read the corresponding skill for diagnostic guidance.
Each skill lists which extension tools apply.

| Domain | Skill | Extension tools | Trigger symptoms |
|--------|-------|----------------|-----------------|
| Native build | `skills/native-build/` | `toolchain_check`, `native_build` | CMake failure, missing SDL2, LP64 crashes |
| WASM/Emscripten | `skills/emscripten/` | `wasm_build`, `wasm_validate`, `wasm_screenshot`, `run_e2e_test` | EM_ASM silent, black screen, garbled audio |
| E2E testing | `skills/e2e-testing/` | `serve_wasm`, `serve_assets`, `run_e2e_test` | pageerror, `__wasmReady` timeout, blank Xvfb |
| Wine testing | `skills/wine-testing/` | `wine_check`, `wine_capture` | Wine prefix failure, DirectDraw blank |
| VQA codec | `skills/vqa-codec/` | `vqa_pixel_diff` | Block corruption, palette errors, CI failure |
| Parity comparison | `skills/parity-comparison/` | `data_verify`, `wine_capture`, `parity_compare`, `vqa_pixel_diff` | SSIM regression, parity failure |
| CI/CD | `skills/ci-cd/` | `wasm_build`, `wasm_validate`, `native_build`, `run_e2e_test` | CI failure, release broken, deploy stuck |
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
   valid WASM magic (`\x00asm`). Run `wasm_validate(target: "both")` or
   `nix run .#ci-wasm` to verify.

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
   run `nix run .#shim`.

8. **Never use `git add -A` (or `git add .` / `git add --all`).** Always stage
   specific files with explicit paths. Blind `-A` picks up unrelated changes and
   risks committing garbage (node_modules/ logs, build artifacts, generated files).

---

## Key Scripts Reference

All reusable scripts live in `scripts/`. Historical build-pass scripts have been
moved to `scripts/archive/`.

| Script / Tool | Purpose |
|---------------|---------|
| `native_build` tool / `skill-native-build.sh` | One-command native Linux build (ra + td) |
| `wasm_build` + `wasm_validate` / `skill-ci-wasm-smoke.sh` | Full WASM CI cycle |
| `run_e2e_test` tool / `skill-run-e2e.sh` | Xvfb + WASM server + Playwright test |
| `serve_wasm` tool / `skill-wasm-serve.sh` | WASM dev server with COOP/COEP |
| `toolchain_check` tool / `skill-dev-check.sh` | Toolchain prerequisite check |
| `vqa_pixel_diff` tool / `vqa-pixel-diff.py` | VQA pixel diff against ffmpeg |
| `parity_compare` tool / `parity-compare.py` | SSIM + fill% + p99 pixel diff |
| `data_verify` tool / `*-data-verify.py` | MIX checksum verification |
| `wine_check` tool / `skill-wine-check.sh` | Wine prerequisite check |
| `wine_capture` tool / `wine-ra.sh` / `wine-td.sh` | Wine OG screenshot capture |
| `skill-xvfb-ensure.sh` | Idempotent Xvfb launcher (source it) |
| `skill-vqa-check.sh` | VQA CI gate: regenerate → diff → pixel-diff |
| `parity-report.sh` | Three-way parity report (vqa + gameplay modes) |
| `lint-lp64.py` | LP64 static hazard audit |
| `cinematic-compare.py` | Cinematic/VQA batch comparison |
| `generate-include-shim.py` | Case-folding include shim generator |
| `gen-vqa-golden.py` / `gen-all-vqa-goldens.sh` | VQA golden frame generation |
| `gen-gameplay-goldens.sh` | Gameplay golden from Wine capture + manifest |
| `native-capture.sh` | Native Linux gameplay capture under Xvfb |
| `ci-local.sh` | Local CI: run all available gates |
| `wine-ra-setup.sh` / `wine-td-setup.sh` | First-time Wine prefix setup |
| `wine-allied-l1.sh` / `wine-soviet-l1.sh` | Campaign-specific Wine captures |
| `wine-vqa-capture.sh` | Wine VQA playback frame capture |
| `tools/wine-input/*` | SendInput injectors + BitBlt capture inside Wine |
| `tools/cnc-ddraw/` flake | Build cnc-ddraw with scanline_double patch — `nix build path:./tools/cnc-ddraw#cnc-ddraw` |

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
| *(below)* | Worktree protocol for concurrent multi-agent development |

---

## Worktree Protocol

All engineering agents **MUST** work in a per-issue git worktree when making
changes. This prevents filesystem collisions when multiple agents run
concurrently and keeps `master` clean.

### Create a worktree

```
EnterWorktree(name: "<ISSUE-OR-SHORT-DESCRIPTION>")
```

This creates `.claude/worktrees/<name>/` on a new branch `worktree-<name>`
and resets it to `origin/master`.

If a worktree for this name already exists, re-enter it with:

```
EnterWorktree(path: "<absolute-path-from-git-worktree-list>")
```

Check what exists:

```bash
git worktree list
```

### Working in the worktree

- `cd` into the worktree directory and do all work there.
- Commit as you go. Build and test from inside the worktree — artifacts
  don't collide with other worktrees.
- **Never** commit directly to `master` in the root worktree while an
  issue worktree is active.

### Done: PR + automerge

From inside the worktree:

```bash
git fetch origin
git rebase origin/master --autostash
git push origin HEAD
gh pr create --repo hughobrien/battlecontrol \
  --title "<short description>" \
  --body "<details>" \
  --base master
gh pr merge --auto --merge     # ⚠️ required — never skip
```

> **Automerge is mandatory.** If CI is green, the PR merges automatically.
> If CI is red, it waits. Never merge manually.

Then exit the worktree keeping the branch:

```
ExitWorktree(action: "keep")
```

### Cleanup after merge

From the root worktree:

```bash
git pull origin master
git worktree remove .claude/worktrees/<name>
git branch -d worktree-<name>
```

### Cancel / abandon

```bash
git worktree remove .claude/worktrees/<name> --force
git branch -D worktree-<name>
```

### Quick reference

| Item | Value |
|------|-------|
| Remote | `origin` (not `battlecontrol`) |
| Worktree path | `.claude/worktrees/<name>/` (gitignored) |
| Local branch | `worktree-<name>` |
| Base branch | `origin/master` |
| PR base | `master` |
| Automerge method | `--merge` |

