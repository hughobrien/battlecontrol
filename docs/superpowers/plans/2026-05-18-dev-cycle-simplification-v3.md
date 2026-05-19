# Dev Cycle Simplification v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make opinionated defaults: `regression` always runs everything, CI uses `test` tier, remove 8 per-game apps, lint auto-fixes, update docs.

**Architecture:** Six independent tasks across scripts, flake, CI config, and docs. Each task is self-contained and can be committed independently.

**Tech Stack:** bash, Nix flake, GitHub Actions, Markdown

---

### Task 1: Make lint.sh auto-fix

**Files:**
- Modify: `scripts/lint.sh` lines 17-18, 25-27, 29-31

- [ ] **Change `ruff check` → `ruff check --fix`**

Line 17: `ruff check scripts/ e2e/ wasm/ 2>&1 || FAIL=1`
→ `ruff check --fix scripts/ e2e/ wasm/ 2>&1 || FAIL=1`

- [ ] **Change `ruff format --check --diff` → `ruff format`**

Lines 18:
```
ruff format --check --diff scripts/ e2e/ wasm/ 2>&1 || FAIL=1
```
→
```
ruff format scripts/ e2e/ wasm/ 2>&1 || FAIL=1
```

- [ ] **Change `shfmt -d` → `shfmt -w`**

Line 27: `find scripts/ -name '*.sh' -exec shfmt -d {} + 2>&1 || FAIL=1`
→ `find scripts/ -name '*.sh' -exec shfmt -w {} + 2>&1 || FAIL=1`

- [ ] **Change `nixfmt --check` → `nixfmt`**

Line 31:
```
find . -name '*.nix' -not -path './build/*' -exec nixfmt --check {} + 2>&1 || FAIL=1
```
→
```
find . -name '*.nix' -not -path './build/*' -exec nixfmt {} + 2>&1 || FAIL=1
```

- [ ] **Commit**

```bash
git add scripts/lint.sh
git commit -m "feat(lint): auto-fix instead of check-only

ruff check --fix, ruff format (in-place), shfmt -w, nixfmt (in-place).
Pre-commit hook now auto-formats staged files.
"
```

---

### Task 2: Simplify regression.sh — always run all targets

**Files:**
- Modify: `scripts/regression.sh`

- [ ] **Rewrite regression.sh to remove gating and always run all targets**

Replace the current content with:

```bash
#!/usr/bin/env bash
# Regression — build + full regression (all targets, no diff-gating).
# Usage: bash scripts/regression.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Build all ==="
bash "$SCRIPT_DIR/build.sh" --all
echo ""

echo "=== Regression ==="

FAIL=0

run_regression() {
	local game="$1" platform="$2"
	echo "--- $game-$platform-regression ---"
	bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" --full || FAIL=$((FAIL + 1))
}

run_regression ra native
run_regression ra wasm
run_regression td native
run_regression td wasm

echo ""
if [ "$FAIL" -gt 0 ]; then
	echo "✗ Regression: $FAIL failure(s)"
	exit 1
fi
echo "✓ Regression complete"
```

Key changes from current:
- No `source "$SCRIPT_DIR/_gating.sh"` — always runs everything
- Calls `build.sh --all` instead of plain `build.sh`
- Removed `--all` / `--base REF` flag parsing
- Removed game/platform gate checks — always runs all 4

- [ ] **Commit**

```bash
git add scripts/regression.sh
git commit -m "refactor(regression): always run all targets, no diff-gating

nix run .#regression is now the one-command full CI locally.
No --all flag needed — it always builds and tests all 4 targets.
"
```

---

### Task 3: Remove 8 per-game apps from flake.nix

**Files:**
- Modify: `flake.nix` — lines 425-480

- [ ] **Remove 4 build app definitions (ra-native-build, td-native-build, ra-wasm-build, td-wasm-build)**

Delete lines 425-462 (the entire "Build shortcuts" section block including the comment header):

```nix
        # ── Build shortcuts (combinatorial: {game}-{platform}-build) ──────
        ra-native-build = mkApp "ra-native-build" ''
          exec nix build .#redalert -L --no-link
        '';

        td-native-build = mkApp "td-native-build" ''
          exec nix build .#tiberiandawn -L --no-link
        '';

        ra-wasm-build = mkApp "ra-wasm-build" ''
            set -e
            emcmake cmake --preset wasm
            cmake --build build-wasm --target ra --parallel
            python3 -c "
          import os, struct
          fn='build-wasm/ra.wasm'
          with open(fn,'rb') as f:
              assert f.read(4)==b'\\x00asm', f'{fn}: bad magic'
          sz=os.path.getsize(fn)
          assert sz>1_000_000, f'{fn}: too small ({sz} bytes)'
          print(f'  ra.wasm: {sz//1024} KB OK')
          "
        '';

        td-wasm-build = mkApp "td-wasm-build" ''
            set -e
            emcmake cmake --preset wasm
            cmake --build build-wasm --target td --parallel
            python3 -c "
          import os, struct
          fn='build-wasm/td.wasm'
          with open(fn,'rb') as f:
              assert f.read(4)==b'\\x00asm', f'{fn}: bad magic'
          sz=os.path.getsize(fn)
          assert sz>1_000_000, f'{fn}: too small ({sz} bytes)'
          print(f'  td.wasm: {sz//1024} KB OK')
          "
        '';
```

- [ ] **Remove 4 test app definitions (ra-native-test, td-native-test, ra-wasm-test, td-wasm-test)**

Delete lines 464-480 (the "Test shortcuts" section):

```nix
        # ── Test shortcuts (combinatorial: {game}-{platform}-test) ────────
        # Each forwards $@ so --full triggers the full regression tier.
        ra-native-test = mkApp "ra-native-test" ''
          exec bash scripts/test-runner.sh ra native "$@"
        '';

        td-native-test = mkApp "td-native-test" ''
          exec bash scripts/test-runner.sh td native "$@"
        '';

        ra-wasm-test = mkApp "ra-wasm-test" ''
          exec bash scripts/test-runner.sh ra wasm "$@"
        '';

        td-wasm-test = mkApp "td-wasm-test" ''
          exec bash scripts/test-runner.sh td wasm "$@"
        '';
```

- [ ] **Remove the generic e2e runner comment (now orphaned)**

Delete line 482: `        # ── Generic e2e runner ────────────────────────────────────────────`

- [ ] **Commit**

```bash
git add flake.nix
git commit -m "refactor(flake): remove 8 per-game build/test apps

Tier apps (nix run .#build/test/regression) are the canonical interface.
Single-target testing still works via bash scripts/test-runner.sh directly.
"
```

---

### Task 4: Update CI to use test tier

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Change regression → test and update job name**

In `.github/workflows/ci.yml`:

Line 1: `# CI — thin wrapper around nix run .#regression.` → `# CI — thin wrapper around nix run .#test.`
Line 2: `# Primary testing happens locally; this confirms the deploy artifact.` → `# Primary testing happens locally; this confirms the deploy artifact.`
Line 3: `# Local equivalent: nix run .#regression` → `# Local equivalent: nix run .#test`

Line 23: `name: Test (build + lint + full regression)` → `name: Test (build + lint + boot tests)`

Line 65: `nix run .#regression -- --all` → `nix run .#test -- --all`

- [ ] **Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: use test tier instead of regression

CI runs boot tests (nix run .#test), not full regression.
Full regression is the local pre-push check.
"
```

---

### Task 5: Update AGENTS.md

**Files:**
- Modify: `AGENTS.md`

- [ ] **Fix line 70: `nix run .#lint-all` → `nix run .#lint`**

Replace line 70: `nix run .#lint-all` → `nix run .#lint`

- [ ] **Replace "Before every push: run ci_local first" section (lines 96-115)**

Replace the entire section (lines 96-116) with:

```markdown
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
```

- [ ] **Fix Quickstart section (line 135)**

Replace line 135: `nix run .#toolchain-check` → `nix run .#test`

Let it be a valid command. The quickstart should show the most useful first command.

- [ ] **Replace Canonical Build Commands (lines 141-195)**

Replace the pseudocode section (lines 141-197) with actual commands:

```markdown
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

> ⚠️ **Stale CMake cache.** If build fails with `include could not find
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
```

- [ ] **Replace Canonical Test Commands (lines 199-230)**

Replace the `run_e2e_test` pseudocode (lines 199-230) with actual commands:

```markdown
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
nix run .#vqa-decode -- --vqa NAME --mix PATH --out DIR [--duration N] [--engine {ffmpeg,native}]
nix run .#vqa-compare -- <dirA> <dirB>
```

### Parity comparison (Wine OG vs WASM/Linux)

```bash
nix run .#parity-compare -- <imageA> <imageB> [--label LABEL] [--threshold-ssim 0.90]
```

### Data integrity

```bash
python3 scripts/ra-data-verify.py /path/to/data
```
```

- [ ] **Fix Edit-Compile-Test Loop (lines 232-246)**

Replace lines 232-246 with:

```markdown
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
```

- [ ] **Fix Skill Index extension tools (lines 385-393)**

Replace pseudocode references with actual commands or remove the extension tools column content that contains them:

Line 387: `\`toolchain_check\`, \`build_native\`` → `scripts/build-native.sh, nix run .#build`
Line 388: `\`build_wasm\`, \`wasm_validate\`, \`wasm_screenshot\`, \`run_e2e_test\`` → `emcmake cmake --preset wasm, python3 scripts/validate-wasm.py`
Line 389: `\`serve_wasm\`, \`serve_assets\`, \`run_e2e_test\`` → `scripts/serve-wasm.sh, bash scripts/run-e2e.sh`
Line 393: `\`build_wasm\`, \`wasm_validate\`, \`build_native\`, \`run_e2e_test\`` → `nix run .#build, nix run .#test`

- [ ] **Fix invariant 3 WASM validation command (line 414)**

Line 414: `nix run .#ci-wasm` → `scripts/validate-wasm.sh` (or remove the specific command and just reference the tier apps)

Actually, the WASM binary validation is done by the wasm-build scripts inline. Change line 414 to:

```
valid WASM magic (\`\\x00asm\`). Run the WASM build to verify.
```

- [ ] **Fix Key Scripts Reference (line 458)**

Line 458: `\`build-wasm\` / \`ci-wasm-smoke.sh\`` → remove the reference to `ci-wasm-smoke.sh` which doesn't exist. Change to just \`build-wasm/\`.

- [ ] **Commit**

```bash
git add AGENTS.md
git commit -m "docs: update AGENTS.md for v3 dev cycle

Remove dead references (ci_local, nix run .#ci, pseudocode functions).
Update commands to reflect current four-tier workflow.
"
```

---

### Task 6: Update scripts.md

**Files:**
- Modify: `scripts.md`

- [ ] **Remove 8 removed app entries from Cross-Reference Matrix**

In the matrix (lines 7-17):
- Line 15: Change `| Build (single) | \`ra-native-build\` etc. | ...` to remove the references. Replace the row with something like `| Build (single) | (use tier app) | \`scripts/build-native.sh\` | — | — |`
- Actually, let's just remove the two rows that reference the removed apps:
  - Line 15: `| Build (single) | \`ra-native-build\` etc. | \`scripts/build-native.sh\`, inline WASM | — | — |`
  - Line 16: `| Test (single) | \`ra-native-test\` etc. | \`scripts/test-runner.sh\` (+ \`--full\` for regression) | — | — |`

- [ ] **Remove 4 build app entries from Build section (lines 40-45)**

Lines 40-42 (Native build row referencing ra-native-build/td-native-build):
Replace with a note that the tier apps handle building.

Actually, keep the build information but remove the nix app names. Change lines 40-42:

```
| Native build | `nix run .#ra-native-build` / `.#td-native-build` | Build RA or TD native Linux with cmake + ninja. |
```
→
```
| Native build | `nix run .#build` | Build RA and/or TD native Linux (diff-gated). |
| | `cmake --preset linux-native && cmake --build build --target ra --parallel` | Direct single-target build. |
```

Line 42 (WASM build row):
```
| WASM build | `nix run .#ra-wasm-build` / `.#td-wasm-build` | Build ra.wasm and/or td.wasm via emcmake + cmake + ninja. |
```
→
```
| WASM build | `nix run .#build` | Build ra.wasm and/or td.wasm (diff-gated). |
| | `emcmake cmake --preset wasm && cmake --build build-wasm --target ra --parallel` | Direct single-target WASM build. |
```

- [ ] **Remove 4 test app entries from Test section (lines 53-56)**

Lines 53-56 (single game test rows):
Replace with a note about direct invocation:

```
| Test (single game) | `nix run .#ra-wasm-test [--full]` | ... |
| | `nix run .#td-native-test [--full]` | ... |
| | `nix run .#ra-native-test [--full]` | ... |
| | `nix run .#td-wasm-test [--full]` | ... |
```
→
```
| Test (single game) | `bash scripts/test-runner.sh <game> <platform> [--full]` | Run boot or full regression for a single game+platform. |
```

- [ ] **Remove 8 entries from Flat Alphabetical Index (lines 199-208, 224-225)**

Remove these lines:
- Line 199: `| \`ra-native-build\` | nix app | Build | Build RA native Linux. |`
- Line 200: `| \`ra-native-test\` | nix app | Test | RA native tests. ...`
- Line 201: `| \`ra-wasm-build\` | nix app | Build | Build RA WASM. |`
- Line 202: `| \`ra-wasm-test\` | nix app | Test | RA WASM tests ...`
- Line 205: `| \`td-native-build\` | nix app | Build | Build TD native Linux. |`
- Line 206: `| \`td-native-test\` | nix app | Test | TD native tests. ...`
- Line 207: `| \`td-wasm-build\` | nix app | Build | Build TD WASM. |`
- Line 208: `| \`td-wasm-test\` | nix app | Test | TD WASM tests ...`
- Line 224: `| \`ra-native-test\` | nix app | Test | ...`
- Line 225: `| \`td-native-test\` | nix app | Test | ...`

- [ ] **Update regression command reference (line 61, line 119)**

Line 61: `| Full CI locally | \`nix run .#regression -- --all\` | ...` → `| Full CI locally | \`nix run .#regression\` | Run every gate: lint → build → full regression for all targets. |`
Line 119: Same change.

- [ ] **Commit**

```bash
git add scripts.md
git commit -m "docs: update scripts.md for v3 dev cycle

Remove 8 removed per-game apps, update regression to reflect no-flag usage.
"
```

---

### Verification

- [ ] **Verify lint auto-fixes**

Create a temporary formatting issue:
```bash
echo 'import os, sys' > /tmp/test_fix.py
cp /tmp/test_fix.py scripts/test_fix.py
nix run .#lint
```
Expected: the file should be auto-fixed (no lint error), then clean up:
```bash
rm scripts/test_fix.py
```

- [ ] **Verify regression runs all targets**

Run: `nix run .#regression`

Expected: builds all 4 targets, runs all 4 regression suites. No `--all` needed.

- [ ] **Verify test still works with gating**

Run: `nix run .#test`

Expected: diff-gated build + boot tests for changed targets only.

- [ ] **Verify CI config references test**

Read `.github/workflows/ci.yml` — confirm it says `nix run .#test -- --all`.

- [ ] **Verify no stale nix apps**

Read `flake.nix` apps section — confirm no `ra/wasm/{native/wasm}-{build/test}` entries remain.

- [ ] **Verify AGENTS.md has no dead references**

```bash
grep -c 'ci_local\|nix run .#ci\|nix run .#lint-all\|nix run .#toolchain' AGENTS.md
```
Expected: 0 matches.
