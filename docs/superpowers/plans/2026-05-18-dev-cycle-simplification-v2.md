# Dev Cycle Simplification v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `lint` into fast `lint` (pre-commit, <10s) + standalone `check` (~5 min). Rename `smoke` → `test` and `test` → `regression`. Keep the four-tier chain but with fast components.

**Architecture:** Extract clang-tidy and cppcheck from `scripts/lint.sh` into a new `scripts/check.sh`. Rename `scripts/smoke.sh` → `scripts/test.sh` and `scripts/test.sh` → `scripts/regression.sh` (handle rename collision with two-step git mv). Update `flake.nix` apps to add `check` and rename `smoke`/`test` to `test`/`regression`. Update CI and docs to match.

**Tech Stack:** bash, Nix flake, GitHub Actions

---

### Task 1: Create scripts/check.sh

**Files:**
- Create: `scripts/check.sh`
- Reference: `scripts/lint.sh` (source for extracted content)

- [ ] **Create scripts/check.sh**

Write `scripts/check.sh` with the clang-tidy and cppcheck sections extracted from lint.sh, plus the common header:

```bash
#!/usr/bin/env bash
# Check — heavyweight static analysis (clang-tidy + cppcheck).
# Run on-demand (not in pre-commit hook).
# Usage: bash scripts/check.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== clang-tidy ==="
cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
find REDALERT TIBERIANDAWN -type f \
	\! -path '*/WIN32LIB/*' \
	\( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
	-print0 | xargs -0 -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 |
	tee /tmp/clang-tidy-report.txt || true
echo "$(grep -c 'warning:\|error:' /tmp/clang-tidy-report.txt 2>/dev/null || echo 0) clang-tidy finding(s)"

echo ""
echo "=== cppcheck ==="
cppcheck --enable=warning,performance,portability,information \
	--suppress=missingIncludeSystem \
	--suppress=unmatchedSuppression \
	--inline-suppr --error-exitcode=0 \
	-j "$(nproc)" --quiet \
	-I REDALERT -I REDALERT/WIN32LIB \
	-I TIBERIANDAWN -I TIBERIANDAWN/WIN32LIB \
	-I linux/win32-stubs \
	REDALERT TIBERIANDAWN 2>&1 | tee /tmp/cppcheck-report.txt
echo "$(grep -c 'error:\|warning:' /tmp/cppcheck-report.txt 2>/dev/null || echo 0) cppcheck finding(s)"

echo ""
echo "✓ Check complete"
```

Then `chmod +x scripts/check.sh`.

- [ ] **Commit**

```bash
git add scripts/check.sh
git commit -m "feat: add scripts/check.sh for heavyweight static analysis

Extract clang-tidy and cppcheck into a standalone check script.
These take ~5 min total and are no longer part of the pre-commit lint.
"
```

---

### Task 2: Strip clang-tidy and cppcheck from lint.sh

**Files:**
- Modify: `scripts/lint.sh`

- [ ] **Remove clang-tidy section from lint.sh**

Remove lines 15-23 (clang-tidy block). After removal, the echo/cppcheck section moves up:

Before:
```
echo ""
echo "=== clang-tidy ==="
cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
find REDALERT TIBERIANDAWN -type f \
	\! -path '*/WIN32LIB/*' \
	\( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
	-print0 | xargs -0 -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 |
	tee /tmp/clang-tidy-report.txt || true
echo "$(grep -c 'warning:\|error:' /tmp/clang-tidy-report.txt 2>/dev/null || echo 0) clang-tidy finding(s)"
```

- [ ] **Remove cppcheck section from lint.sh**

Remove the cppcheck block:

Before:
```
echo ""
echo "=== cppcheck ==="
cppcheck --enable=warning,performance,portability,information \
	--suppress=missingIncludeSystem \
	--suppress=unmatchedSuppression \
	--inline-suppr --error-exitcode=0 \
	-j "$(nproc)" --quiet \
	-I REDALERT -I REDALERT/WIN32LIB \
	-I TIBERIANDAWN -I TIBERIANDAWN/WIN32LIB \
	-I linux/win32-stubs \
	REDALERT TIBERIANDAWN 2>&1 | tee /tmp/cppcheck-report.txt
echo "$(grep -c 'error:\|warning:' /tmp/cppcheck-report.txt 2>/dev/null || echo 0) cppcheck finding(s)"
```

After both removals, lint.sh should contain: LP64, ruff, yamllint, shellcheck/shfmt, nixfmt, /opt audit.

- [ ] **Commit**

```bash
git add scripts/lint.sh
git commit -m "refactor: remove clang-tidy and cppcheck from lint.sh

Heavy static analysis moved to scripts/check.sh (on-demand).
lint.sh now completes in <10s, suitable for pre-commit hook.
"
```

---

### Task 3: Rename smoke → test, test → regression

**Files:**
- Rename: `scripts/test.sh` → `scripts/regression.sh`
- Rename: `scripts/smoke.sh` → `scripts/test.sh`
- Modify: `scripts/test.sh` (formerly smoke.sh) — update header comment
- Modify: `scripts/regression.sh` (formerly test.sh) — update header and echos

This must be a two-step rename to avoid collision:
1. `git mv scripts/test.sh scripts/regression.sh`
2. `git mv scripts/smoke.sh scripts/test.sh`

- [ ] **Step 1: mv test.sh → regression.sh, update header**

```bash
cd /home/hugh/battlecontrol
git mv scripts/test.sh scripts/regression.sh
```

Then update the docstring in `scripts/regression.sh`:

Line 1: `# Test — build + full regression.` → `# Regression — build + full regression.`
Line 3: `# Usage: bash scripts/test.sh [--all] [--base REF]` → `# Usage: bash scripts/regression.sh [--all] [--base REF]`

And rename the function from `run_full` → `run_regression`, and rename the echo line:

Line 21-24:
```bash
run_regression() {
    local game="$1" platform="$2"
    echo "--- $game-$platform-regression ---"
    bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" --full || FAIL=$((FAIL + 1))
}
```

And update calls to the renamed function — change `run_full` to `run_regression` at lines 27, 33, 39, 45.

- [ ] **Step 2: mv smoke.sh → test.sh, update header**

```bash
cd /home/hugh/battlecontrol
git mv scripts/smoke.sh scripts/test.sh
```

Update the docstring in `scripts/test.sh`:

Line 1: `# Smoke — build + CI-tier boot tests.` → `# Test — build + CI-tier boot tests.`
Line 3: `# Usage: bash scripts/smoke.sh [--all] [--base REF]` → `# Usage: bash scripts/test.sh [--all] [--base REF]`

- [ ] **Commit**

```bash
git add scripts/test.sh scripts/regression.sh
git commit -m "refactor: rename smoke→test, test→regression

smoke.sh is now test.sh (CI-tier boot tests, <2 min).
test.sh is now regression.sh (full suite with --full, minutes).
"
```

---

### Task 4: Update flake.nix apps

**Files:**
- Modify: `flake.nix` — lines 523-535 (four-tier workflow apps), line 484-487 (lint app comment), add check app

- [ ] **Update lint app comment**

Line 484: change `# nix run .#lint — runs all linters (LP64 + clang-tidy + cppcheck + ...)` to `# nix run .#lint — fast static analysis and format checks (<10s). Heavy: nix run .#check`

- [ ] **Rename smoke → test**

Change lines 529-531:
```nix
        smoke = mkApp "smoke" ''
          exec bash scripts/smoke.sh "$@"
        '';
```
to:
```nix
        test = mkApp "test" ''
          exec bash scripts/test.sh "$@"
        '';
```

- [ ] **Rename test → regression**

Change lines 533-535:
```nix
        test = mkApp "test" ''
          exec bash scripts/test.sh "$@"
        '';
```
to:
```nix
        regression = mkApp "regression" ''
          exec bash scripts/regression.sh "$@"
        '';
```

- [ ] **Add check app**

After the `test` entry (or after `regression`), add:
```nix
        # Heavy static analysis (on-demand). Fast lint: nix run .#lint
        check = mkApp "check" ''
          exec bash scripts/check.sh
        '';
```

- [ ] **Update four-tier comment**

Line 523: change `# ── Four-tier workflow: lint → build → smoke → test ──────` to `# ── Four-tier workflow: lint → build → test → regression ──────`

- [ ] **Commit**

```bash
git add flake.nix
git commit -m "feat(flake): add check app, rename smoke→test, test→regression
"
```

---

### Task 5: Update CI workflow

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Change test → regression**

In `.github/workflows/ci.yml`, line 65:
```
nix run .#test -- --all
```
change to:
```
nix run .#regression -- --all
```

- [ ] **Update comment that references test**

Line 1-3 in ci.yml:
```
# CI — thin wrapper around nix run .#test.
```
change to:
```
# CI — thin wrapper around nix run .#regression.
```

- [ ] **Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: update to use nix run .#regression
"
```

---

### Task 6: Update scripts.md

**Files:**
- Modify: `scripts.md`

- [ ] **Update Cross-Reference Matrix (lines 8-13)**

Replace the matrix rows:

| Action | Nix App | Script(s) | CI Job | npm Script |
|--------|---------|-----------|--------|------------|
| Lint | `lint` | `scripts/lint.sh` | pre-commit hook | — |
| Check | `check` | `scripts/check.sh` | — | — |
| Build | `build` | `scripts/build.sh` | `ci.yml → regression` | — |
| Test | `test` | `scripts/test.sh` | `ci.yml → regression` | — |
| Regression | `regression` | `scripts/regression.sh` | `ci.yml → regression` | — |

- [ ] **Update Lint section (line 48-49)**

Change:
```
| Lint | `nix run .#lint` | All linters (LP64, clang-tidy, cppcheck, ruff, shellcheck, yamllint, nixfmt, /opt audit). |
```
to:
```
| Lint | `nix run .#lint` | Fast linters (LP64, ruff, shellcheck, yamllint, nixfmt, /opt audit). <10s. |
```

- [ ] **Update Smoke/Test rows (lines 50-51)**

Change:
```
| Smoke | `nix run .#smoke [--all] [--base REF]` | Build + CI-tier boot tests (T1/T2, first-run-pass). |
| Test (full) | `nix run .#test [--all] [--base REF]` | Build + full regression. |
```
to:
```
| Test | `nix run .#test [--all] [--base REF]` | Build + CI-tier boot tests (T1/T2, first-run-pass). |
| Regression | `nix run .#regression [--all] [--base REF]` | Build + full regression. |
```

- [ ] **Add Check row to CI/Gate section (after line 62)**

```
| Deep static analysis | `nix run .#check` | clang-tidy + cppcheck (~5 min, on-demand). |
```

- [ ] **Update CI/Gate section (lines 60-62)**

Change:
```
| Full CI locally | `nix run .#test -- --all` | Run every gate: lint → build → full regression. Same as GitHub CI. |
| Pre-push check | `nix run .#smoke` | Diff-gated: build + boot tests for changed targets. |
| Pre-commit check | `nix run .#lint` | All static analysis + format checks (installed as git hook). |
```
to:
```
| Full CI locally | `nix run .#regression -- --all` | Run every gate: lint → build → full regression. Same as GitHub CI. |
| Pre-push check | `nix run .#test` | Diff-gated: build + boot tests for changed targets. |
| Pre-commit check | `nix run .#lint` | Fast linters (<10s, installed as git hook). |
```

- [ ] **Update Lint/Audit section (lines 98-101)**

Change:
```
| Full lint | `nix run .#lint` | All linters: LP64 + clang-tidy + cppcheck + ruff + yamllint + shellcheck + shfmt + nixfmt + /opt audit. |
| | `bash scripts/lint.sh` | Same, directly. |
```
to:
```
| Lint | `nix run .#lint` | Fast linters: LP64 + ruff + yamllint + shellcheck + shfmt + nixfmt + /opt audit. <10s. |
| | `bash scripts/lint.sh` | Same, directly. |
| Check | `nix run .#check` | Heavy static analysis: clang-tidy + cppcheck. ~5 min, on-demand. |
| | `bash scripts/check.sh` | Same, directly. |
```

- [ ] **Update Iteration Loops (lines 114-116)**

Change:
```
| Full test | `nix run .#test -- --all` | Lint → build → full regression for all targets. |
| Smoke check | `nix run .#smoke` | Diff-gated: lint → build → boot tests for changed targets. |
```
to:
```
| Full regression | `nix run .#regression -- --all` | Lint → build → full regression for all targets. |
| Test | `nix run .#test` | Diff-gated: lint → build → boot tests for changed targets. |
```

- [ ] **Update Flat Alphabetical Index (lines 188-205)**

Change entries:
```
| `lint` | nix app | Lint | All static analysis + format checks + /opt audit. |
| `lint.sh` | script | Lint | All linters in one script (sourced by build/smoke/test). |
```
to:
```
| `lint` | nix app | Lint | Fast linters: LP64, ruff, yamllint, shellcheck, shfmt, nixfmt, /opt audit. Pre-commit hook. |
| `lint.sh` | script | Lint | Fast linters in one script (sourced by build/test/regression). |
| `check` | nix app | Check | Heavy static analysis: clang-tidy + cppcheck (~5 min, on-demand). |
| `check.sh` | script | Check | Same, directly. |
```

Change:
```
| `smoke` | nix app | CI | Build + CI-tier boot tests. |
| `smoke.sh` | script | CI | Diff-gated build + boot test orchestrator. |
| `test` | nix app | CI | Build + full regression. |
| `test-runner.sh` | script | Test | Unified backend for all `{game}-{platform}-test` apps. |
| `test.sh` | script | CI | Diff-gated build + full regression orchestrator. |
```
to:
```
| `test` | nix app | Test | Build + CI-tier boot tests. |
| `test.sh` | script | Test | Diff-gated build + boot test orchestrator. |
| `regression` | nix app | Regression | Build + full regression. |
| `regression.sh` | script | Regression | Diff-gated build + full regression orchestrator. |
| `test-runner.sh` | script | Test | Unified backend for all `{game}-{platform}-test` apps. |
```

- [ ] **Update Call Graph (bottom matter, especially the nix run examples)**

Change any references to `.#smoke` → `.#test` and `.#test` (when meaning full regression) → `.#regression`.

- [ ] **Commit**

```bash
git add scripts.md
git commit -m "docs: update scripts.md for lint/check split and smoke→test→regression rename
"
```

---

### Task 7: Update workflows.md

**Files:**
- Modify: `workflows.md`

- [ ] **Update all references**

| Line(s) | Change |
|---------|--------|
| 74, 174, 434 | `nix run .#test` (running spec) stays — these refer to the existing game-specific test apps which aren't renamed |
| 76 | `nix run .#test` (running spec) stays — same as above |
| 78, 80, 185, 188, 442, 443 | `nix run .#smoke-ra` and `nix run .#smoke-td` — these don't exist as apps. Leave them (they're documented examples of non-existent shortcuts, out of scope) |
| 432 | `nix run .#lint-all` — doesn't exist either, leave it |
| 435 | `nix run .#test -- <spec>` — this refers to the `.#test` app, which after rename runs boot tests not full regression. This is ambiguous in the original; leave as-is (it's about running a single spec via the chain) |

Actually, looking more carefully at the lines — many refer to `nix run .#test` when they mean running a specific e2e spec. The `.#test` app (now `.#regression`) doesn't take spec arguments — the `{game}-{platform}-test` apps do. These docs have pre-existing inaccuracies. Leave them; they're not part of this change.

No changes needed to workflows.md for this rename.

- [ ] **Commit**

No commit needed for workflows.md — no changes required.

---

### Verification

- [ ] **Verify lint completes in <10s**

Run: `time nix run .#lint`

Expected: completes in <10s, no clang-tidy or cppcheck output. If it fails on pre-existing ruff issues, that's expected (not caused by this change).

- [ ] **Verify check runs clang-tidy and cppcheck**

Run: `time nix run .#check`

Expected: runs clang-tidy and cppcheck, produces output.

- [ ] **Verify test runs boot tests**

Run: `nix run .#test -- --all` (or just `nix run .#build` to verify the chain works)

Expected: lint → build → boot tests run.

- [ ] **Verify regression runs full suite**

Run: `nix run .#regression -- --all`

Expected: lint → build → full regression runs.

- [ ] **Verify CI reference is updated**

Read `.github/workflows/ci.yml` and confirm it says `nix run .#regression -- --all`.

- [ ] **Final review of the diff**

Run: `git diff master --stat` — should show 2 files created (check.sh), 4 files modified (lint.sh, flake.nix, ci.yml, scripts.md), 2 files renamed (smoke.sh→test.sh, test.sh→regression.sh).
