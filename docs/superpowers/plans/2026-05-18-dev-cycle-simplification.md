# Dev Cycle Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse 26-app flake into four-tier `lint` → `build` → `smoke` → `test` workflow with diff-gating, remove dead scripts, and make local the primary CI.

**Architecture:** Four shell scripts, each a nix app. `_gating.sh` is sourced by build/smoke/test to compute which targets changed. `test-runner.sh` is the single backend for all 4 `{game}-{platform}-test` apps, replacing the 4 deleted regression scripts. GitHub CI collapses to a single `nix run .#test` job.

**Tech Stack:** Bash, Nix flakes, Playwright, clang-tidy, cppcheck, ruff, shellcheck, shfmt, yamllint, nixfmt

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `scripts/lint.sh` | All linters + `/opt` audit, extracted from flake.nix inline |
| Create | `scripts/_gating.sh` | Diff analysis helper, sourced by build/smoke/test |
| Create | `scripts/build.sh` | Lint + diff-gated compile orchestrator |
| Create | `scripts/smoke.sh` | Build + CI-tier boot tests |
| Create | `scripts/test.sh` | Build + full-tier regression tests |
| Create | `scripts/test-runner.sh` | Single backend for all `{game}-{platform}-test` apps; understands `--full` |
| Modify | `flake.nix` | Add lint/build/smoke/test apps; rewire test apps to test-runner.sh; remove ci + regression apps; simplify pre-commit hook |
| Modify | `.github/workflows/ci.yml` | Collapse to single `nix run .#test` job |
| Delete | `scripts/ci-local.sh` | Buggy, overlapped with lint |
| Delete | `scripts/regression/ra-native.sh` | Absorbed by test-runner.sh via `--full` |
| Delete | `scripts/regression/td-native.sh` | Same |
| Delete | `scripts/regression/ra-wasm.sh` | Same |
| Delete | `scripts/regression/td-wasm.sh` | Same |

---

### Task 1: Create `scripts/lint.sh`

**Files:**
- Create: `scripts/lint.sh`

Extract the inline shell from the `lint` app in `flake.nix` lines 515-554, add the `/opt` path audit gate from `ci-local.sh`, and make it a standalone script.

- [ ] **Step 1: Write `scripts/lint.sh`**

```bash
#!/usr/bin/env bash
# Lint — all static analysis and format checks.
# Usage: bash scripts/lint.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FAIL=0

echo "=== LP64 hazard audit ==="
python3 scripts/lint-lp64.py --errors-only || FAIL=1

echo ""
echo "=== clang-tidy ==="
cmake --preset linux-native -DCMAKE_EXPORT_COMPILE_COMMANDS=ON 2>/dev/null || true
find REDALERT TIBERIANDAWN -type f \
  \! -path '*/WIN32LIB/*' \
  \( -name '*.cpp' -o -name '*.CPP' -o -name '*.c' -o -name '*.C' \) \
  -print0 | xargs -0 -P "$(nproc)" -I{} clang-tidy -p build --quiet {} 2>&1 \
  | tee /tmp/clang-tidy-report.txt
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
echo "=== Python (ruff check + format) ==="
ruff check scripts/ e2e/ wasm/ 2>&1 || FAIL=1
ruff format --check --diff scripts/ e2e/ wasm/ 2>&1 || FAIL=1

echo ""
echo "=== YAML (yamllint) ==="
yamllint .github/workflows/ 2>&1 || FAIL=1

echo ""
echo "=== Shell (shellcheck + shfmt) ==="
find scripts/ -name '*.sh' -exec shellcheck {} + 2>&1 || FAIL=1
find scripts/ -name '*.sh' -exec shfmt -d {} + 2>&1 || FAIL=1

echo ""
echo "=== Nix (nixfmt) ==="
find . -name '*.nix' -not -path './build/*' -exec nixfmt --check {} + 2>&1 || FAIL=1

echo ""
echo "=== /opt path audit ==="
HITS=$(rg -n '/opt/(redalert|tiberiandawn)' scripts/ | grep -v 'lint.sh' || true)
if [[ -n "$HITS" ]]; then
  echo "FAIL: scripts/ still contains /opt/redalert or /opt/tiberiandawn"
  echo "$HITS"
  FAIL=1
else
  echo "  OK: no /opt paths in scripts/"
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "✗ Lint failed"
  exit 1
fi
echo ""
echo "✓ Lint passed"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/lint.sh
```

- [ ] **Step 3: Verify it runs (will show findings but not fail on findings — informational gates)**

```bash
bash scripts/lint.sh
echo "exit=$?"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/lint.sh
git commit -m "Add lint.sh — extract all linters from flake.nix inline shell

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 2: Create `scripts/_gating.sh`

**Files:**
- Create: `scripts/_gating.sh`

Shared diff-analysis helper sourced by `build.sh`, `smoke.sh`, and `test.sh`. Sets boolean vars for which targets to build/test.

- [ ] **Step 1: Write `scripts/_gating.sh`**

```bash
# _gating.sh — diff-gating helper.
# Source this script to determine which targets are affected by current changes.
#
# Usage: source scripts/_gating.sh [--all] [--base REF]
#
# Sets these variables (true/false):
#   GATE_RA_NATIVE  GATE_TD_NATIVE  GATE_RA_WASM  GATE_TD_WASM
#
# Default base: origin/master. Falls back to HEAD~1.

GATE_RA_NATIVE=false
GATE_TD_NATIVE=false
GATE_RA_WASM=false
GATE_TD_WASM=false

_parse_gating_args() {
  local base="origin/master"

  while [ $# -gt 0 ]; do
    case "$1" in
      --all)
        GATE_RA_NATIVE=true
        GATE_TD_NATIVE=true
        GATE_RA_WASM=true
        GATE_TD_WASM=true
        return
        ;;
      --base)
        shift
        base="${1:-origin/master}"
        ;;
    esac
    shift
  done

  if ! git rev-parse --verify "$base" &>/dev/null; then
    base="HEAD~1"
  fi

  local changed
  changed=$(git diff --name-only "$base" 2>/dev/null || true)

  if [ -z "$changed" ]; then
    # No changes — default to all (safe)
    GATE_RA_NATIVE=true
    GATE_TD_NATIVE=true
    GATE_RA_WASM=true
    GATE_TD_WASM=true
    return
  fi

  if echo "$changed" | grep -qE '^(REDALERT/|linux/win32-stubs/|CMakeLists\.txt|CMakePresets\.json)'; then
    GATE_RA_NATIVE=true
    GATE_RA_WASM=true
  fi
  if echo "$changed" | grep -qE '^(TIBERIANDAWN/|linux/win32-stubs/|CMakeLists\.txt|CMakePresets\.json)'; then
    GATE_TD_NATIVE=true
    GATE_TD_WASM=true
  fi
  if echo "$changed" | grep -qE '^wasm/'; then
    GATE_RA_WASM=true
    GATE_TD_WASM=true
  fi

  # If nothing matched C++ paths, build nothing (lint-only change)
  if ! $GATE_RA_NATIVE && ! $GATE_TD_NATIVE && ! $GATE_RA_WASM && ! $GATE_TD_WASM; then
    # Lint-only change — keep all false, caller can check
    :
  fi
}

_parse_gating_args "$@"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/_gating.sh
git commit -m "Add _gating.sh — diff-based target gating helper

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 3: Create `scripts/build.sh`

**Files:**
- Create: `scripts/build.sh`

- [ ] **Step 1: Write `scripts/build.sh`**

```bash
#!/usr/bin/env bash
# Build — lint + diff-gated compile.
# Usage: bash scripts/build.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "=== Lint ==="
bash "$SCRIPT_DIR/lint.sh"

echo ""
echo "=== Build ==="

source "$SCRIPT_DIR/_gating.sh" "$@"

build_native() {
  local target="$1"
  echo "--- $target-native-build ---"
  bash scripts/build-native.sh "$target"
}

build_wasm() {
  local target="$1"
  echo "--- $target-wasm-build ---"
  if [ "$target" = "ra" ]; then
    nix run .#ra-wasm-build
  else
    nix run .#td-wasm-build
  fi
}

if $GATE_RA_NATIVE; then
  build_native ra
else
  echo "SKIP: ra-native-build (no RA changes)"
fi

if $GATE_TD_NATIVE; then
  build_native td
else
  echo "SKIP: td-native-build (no TD changes)"
fi

if $GATE_RA_WASM; then
  build_wasm ra
else
  echo "SKIP: ra-wasm-build (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
  build_wasm td
else
  echo "SKIP: td-wasm-build (no TD/wasm changes)"
fi

echo ""
echo "✓ Build complete"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/build.sh
```

- [ ] **Step 3: Verify it runs (will build whatever changed)**

```bash
bash scripts/build.sh
echo "exit=$?"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/build.sh
git commit -m "Add build.sh — diff-gated compile orchestrator

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 4: Create `scripts/test-runner.sh`

**Files:**
- Create: `scripts/test-runner.sh`

Single backend for all 4 `{game}-{platform}-test` nix apps. Replaces the 4 deleted regression scripts.

- [ ] **Step 1: Write `scripts/test-runner.sh`**

```bash
#!/usr/bin/env bash
# test-runner.sh — single backend for all {game}-{platform}-test apps.
#
# Usage: bash scripts/test-runner.sh <game> <platform> [--full]
#
#   game:     ra | td
#   platform: native | wasm
#   --full:   run full regression tier (default: CI tier = boot tests only)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

GAME="${1:-}"
PLATFORM="${2:-}"
shift 2 || true
FULL=false
for arg in "$@"; do
  case "$arg" in --full) FULL=true ;; esac
done

if [ -z "$GAME" ] || [ -z "$PLATFORM" ]; then
  echo "Usage: test-runner.sh <ra|td> <native|wasm> [--full]" >&2
  exit 1
fi

# ── WASM helpers ──────────────────────────────────────────────────────────

require_file() { [ -f "$1" ] || { echo "[test-runner] missing $1" >&2; return 1; }; }

start_servers() {
  PIDS=()
  python3 wasm/serve-coop.py 8080 &
  PIDS+=($!)
  if ! pgrep -f "Xvfb :99" >/dev/null; then
    Xvfb :99 -screen 0 1280x1024x24 -ac &
    PIDS+=($!)
  fi
  if [ "$FULL" = true ] && [ "$GAME" = "ra" ] && [ -d "${RA_ASSETS:-/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1}" ]; then
    python3 wasm/serve-assets.py "$RA_ASSETS" 9090 &
    PIDS+=($!)
  fi
  if [ "$FULL" = true ] && [ "$GAME" = "td" ] && [ -d "${TD_ASSETS:-/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1}" ]; then
    python3 wasm/serve-assets.py "$TD_ASSETS" 9091 &
    PIDS+=($!)
  fi
  sleep 3
}

cleanup_servers() {
  for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
}

run_playwright() {
  local spec="$1"
  echo "---- $spec ----"
  playwright test "$spec" --reporter=list || FAIL=$((FAIL + 1))
}

# ── Native helpers ────────────────────────────────────────────────────────

run_script() {
  local script="$1"
  echo "---- $script ----"
  bash "$script" || {
    rc=$?
    [ "$rc" -eq 77 ] || FAIL=$((FAIL + 1))
  }
}

# ── Dispatch ──────────────────────────────────────────────────────────────

FAIL=0

case "$GAME-$PLATFORM" in
  ra-wasm)
    require_file build-wasm/ra.html || exit 1
    trap cleanup_servers EXIT
    start_servers
    run_playwright e2e/regression/T1-ra-wasm-boot.spec.ts
    run_playwright e2e/regression/T11-ra-wasm-m2-boot.spec.ts
    if [ "$FULL" = true ]; then
      run_playwright e2e/regression/T3-ra-wasm-menu.spec.ts
      run_playwright e2e/regression/T4-ra-wasm-vqa.spec.ts
      run_playwright e2e/regression/T5-ra-wasm-menu-click.spec.ts
      run_playwright e2e/regression/T8-ra-audio-pitch.spec.ts
      run_playwright e2e/regression/T9-ra-wasm-mission-start.spec.ts
      run_playwright e2e/regression/T10-ra-wasm-post-game-menu.spec.ts
      run_playwright e2e/regression/T10-ra-menu-bleed.spec.ts
    fi
    ;;
  td-wasm)
    require_file build-wasm/td.html || exit 1
    trap cleanup_servers EXIT
    start_servers
    run_playwright e2e/regression/T2-td-wasm-boot.spec.ts
    run_playwright e2e/regression/T12-td-wasm-m2-boot.spec.ts
    if [ "$FULL" = true ]; then
      run_playwright e2e/regression/T3-td-wasm-menu.spec.ts
      run_playwright e2e/regression/T6-td-wasm-mission-start.spec.ts
      run_playwright e2e/regression/T7-td-audio-pitch.spec.ts
    fi
    ;;
  ra-native)
    run_script scripts/first-run-pass-94.sh
    if [ "$FULL" = true ]; then
      run_script scripts/regression/T6-ra-native-smoke.sh
      run_script scripts/regression/T11-ra-native-m2-smoke.sh
    fi
    ;;
  td-native)
    run_script scripts/run-td-cheat.sh
    if [ "$FULL" = true ]; then
      run_script scripts/regression/T5-td-native-menu.sh
      run_script scripts/regression/T12-td-native-m2-smoke.sh
    fi
    ;;
  *)
    echo "Unknown game/platform: $GAME-$PLATFORM" >&2
    exit 1
    ;;
esac

echo "==== $GAME $PLATFORM: $FAIL failures ===="
exit "$FAIL"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/test-runner.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/test-runner.sh
git commit -m "Add test-runner.sh — unified backend for all game-platform-test apps

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 5: Create `scripts/smoke.sh`

**Files:**
- Create: `scripts/smoke.sh`

- [ ] **Step 1: Write `scripts/smoke.sh`**

```bash
#!/usr/bin/env bash
# Smoke — build + CI-tier boot tests.
# Usage: bash scripts/smoke.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Build first (includes lint)
bash "$SCRIPT_DIR/build.sh" "$@"

echo ""
echo "=== Smoke ==="

source "$SCRIPT_DIR/_gating.sh" "$@"

FAIL=0

run_smoke() {
  local game="$1" platform="$2"
  echo "--- $game-$platform-test ---"
  bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" || FAIL=$((FAIL + 1))
}

if $GATE_RA_NATIVE; then
  run_smoke ra native
else
  echo "SKIP: ra-native-test (no RA changes)"
fi

if $GATE_TD_NATIVE; then
  run_smoke td native
else
  echo "SKIP: td-native-test (no TD changes)"
fi

if $GATE_RA_WASM; then
  run_smoke ra wasm
else
  echo "SKIP: ra-wasm-test (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
  run_smoke td wasm
else
  echo "SKIP: td-wasm-test (no TD/wasm changes)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ Smoke: $FAIL failure(s)"
  exit 1
fi
echo "✓ Smoke complete"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/smoke.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke.sh
git commit -m "Add smoke.sh — build + CI-tier boot test orchestrator

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 6: Create `scripts/test.sh`

**Files:**
- Create: `scripts/test.sh`

- [ ] **Step 1: Write `scripts/test.sh`**

```bash
#!/usr/bin/env bash
# Test — build + full regression.
# Usage: bash scripts/test.sh [--all] [--base REF]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Build first (includes lint)
bash "$SCRIPT_DIR/build.sh" "$@"

echo ""
echo "=== Test (full regression) ==="

source "$SCRIPT_DIR/_gating.sh" "$@"

FAIL=0

run_full() {
  local game="$1" platform="$2"
  echo "--- $game-$platform-test --full ---"
  bash "$SCRIPT_DIR/test-runner.sh" "$game" "$platform" --full || FAIL=$((FAIL + 1))
}

if $GATE_RA_NATIVE; then
  run_full ra native
else
  echo "SKIP: ra-native-test --full (no RA changes)"
fi

if $GATE_TD_NATIVE; then
  run_full td native
else
  echo "SKIP: td-native-test --full (no TD changes)"
fi

if $GATE_RA_WASM; then
  run_full ra wasm
else
  echo "SKIP: ra-wasm-test --full (no RA/wasm changes)"
fi

if $GATE_TD_WASM; then
  run_full td wasm
else
  echo "SKIP: td-wasm-test --full (no TD/wasm changes)"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ Test: $FAIL failure(s)"
  exit 1
fi
echo "✓ Test complete"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/test.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/test.sh
git commit -m "Add test.sh — build + full regression orchestrator

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 7: Delete dead scripts

**Files:**
- Delete: `scripts/ci-local.sh`
- Delete: `scripts/regression/ra-native.sh`
- Delete: `scripts/regression/td-native.sh`
- Delete: `scripts/regression/ra-wasm.sh`
- Delete: `scripts/regression/td-wasm.sh`

- [ ] **Step 1: Delete the files**

```bash
git rm scripts/ci-local.sh
git rm scripts/regression/ra-native.sh
git rm scripts/regression/td-native.sh
git rm scripts/regression/ra-wasm.sh
git rm scripts/regression/td-wasm.sh
```

- [ ] **Step 2: Commit**

```bash
git commit -m "Remove ci-local.sh and per-game regression scripts

Subsumed by lint.sh, build.sh, smoke.sh, test.sh, and test-runner.sh
with --full flag for tier selection.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 8: Rewire `flake.nix` — new tier apps

**Files:**
- Modify: `flake.nix`

Add `lint`, `build`, `smoke`, `test` apps. Remove `ci` and `*-regression` apps. Rewire `*-test` apps to `test-runner.sh`.

- [ ] **Step 1: Add new tier apps after `serve` app (around line 586)**

Locate the `serve` app definition ending around line 588. Insert the four new apps:

```nix
        lint = mkApp "lint" ''
          exec bash scripts/lint.sh
        '';

        build = mkApp "build" ''
          exec bash scripts/build.sh "$@"
        '';

        smoke = mkApp "smoke" ''
          exec bash scripts/smoke.sh "$@"
        '';

        test = mkApp "test" ''
          exec bash scripts/test.sh "$@"
        '';
```

- [ ] **Step 2: Remove `ci` app (lines 647-653)**

Remove the entire `ci = mkApp "ci-local" ...` block.

- [ ] **Step 3: Rewire the 4 `*-test` apps to use `test-runner.sh`**

Replace:

```
        ra-native-test = mkApp "ra-native-test" ''
          exec bash scripts/first-run-pass-94.sh
        '';
```

With:

```
        ra-native-test = mkApp "ra-native-test" ''
          exec bash scripts/test-runner.sh ra native "$@"
        '';
```

And similarly for the other three.

- [ ] **Step 4: Remove the 4 `*-regression` apps**

Remove `ra-wasm-regression`, `td-wasm-regression`, `ra-native-regression`, `td-native-regression` apps (around lines 659-674).

- [ ] **Step 5: Update the `lint` app to use the script**

Replace the inline shell in the `lint` app (lines 515-554) with:

```nix
        lint = mkApp "lint" ''
          exec bash scripts/lint.sh
        '';
```

- [ ] **Step 6: Remove the old `lint` app's inline script**

The old `lint` app (lines 515-554) gets fully replaced by the new one from Step 1 + Step 5 (consolidate — there should be only one `lint` app).

- [ ] **Step 7: Verify the flake evaluates**

```bash
nix flake show 2>&1 | head -40
```

Expected: `lint`, `build`, `smoke`, `test` appear. `ci`, `*-regression` do not. `*-test` apps still present.

- [ ] **Step 8: Commit**

```bash
git add flake.nix
git commit -m "Rewire flake.nix: add lint/build/smoke/test tier apps, remove ci and regression

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 9: Simplify devShell pre-commit hook

**Files:**
- Modify: `flake.nix`

Replace the ~40-line inline shell hook with a single `nix run .#lint`.

- [ ] **Step 1: Replace the pre-commit hook body**

In `flake.nix`, locate the `shellHook` in `devShells.${system}.default`. Replace the current pre-commit hook installation block (lines 353-399, from `REPO_ROOT=...` to the closing `fi`) with:

```bash
          REPO_ROOT="''$(git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$REPO_ROOT" ] && [ ! -f "$REPO_ROOT/.git/hooks/pre-commit" ]; then
            HOOK="$REPO_ROOT/.git/hooks/pre-commit"
            cat > "$HOOK" << 'PREHOOK'
#!/usr/bin/env bash
set -euo pipefail
nix run .#lint
PREHOOK
            chmod +x "$HOOK"
            echo "Installed git pre-commit hook: nix run .#lint"
          fi
```

- [ ] **Step 2: Commit**

```bash
git add flake.nix
git commit -m "Simplify devShell pre-commit hook to nix run .#lint

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 10: Collapse GitHub CI

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Replace `ci.yml` contents**

Replace the entire file with a single-job workflow:

```yaml
# CI — thin wrapper around nix run .#test.
# Primary testing happens locally; this confirms the deploy artifact.
# Local equivalent: nix run .#test

name: CI

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

env:
  CCACHE_DIR: ${{ github.workspace }}/.ccache
  EM_CACHE_DIR: ${{ github.workspace }}/.emscripten-cache

jobs:
  test:
    name: Test (build + lint + full regression)
    runs-on: ubuntu-24.04
    timeout-minutes: 60

    steps:
      - uses: actions/checkout@v6.0.2

      - name: Install Nix
        uses: cachix/install-nix-action@v31.10.6
        with:
          extra_nix_config: |
            experimental-features = nix-command flakes

      - name: Install system deps
        run: sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends cppcheck ffmpeg

      - name: Cache ccache
        uses: actions/cache@v5.0.5
        with:
          path: ${{ env.CCACHE_DIR }}
          key: ccache-${{ hashFiles('CMakeLists.txt', 'CMakePresets.json', 'installer/CMakeLists.txt') }}
          restore-keys: |
            ccache-

      - name: Cache Emscripten
        uses: actions/cache@v5.0.5
        with:
          path: ${{ env.EM_CACHE_DIR }}
          key: emcc-cache-5.0.6-${{ hashFiles('CMakeLists.txt', 'CMakePresets.json') }}
          restore-keys: |
            emcc-cache-5.0.6-

      - name: Run test suite
        env:
          RA_ASSETS_URL: ${{ vars.RA_ASSETS_URL || secrets.RA_ASSETS_URL || '' }}
          TD_ASSETS_URL: ${{ secrets.TD_ASSETS_URL || '' }}
          EM_CACHE: ${{ env.EM_CACHE_DIR }}
        run: |
          nix develop --command bash -c "
            export CCACHE_DIR=${{ env.CCACHE_DIR }}
            ccache --zero-stats
            ccache --max-size 500M
            nix run .#test -- --all
            ccache --show-stats
          "

      - name: Upload artifacts on failure
        if: failure()
        uses: actions/upload-artifact@v7.0.1
        with:
          name: test-results
          path: |
            e2e/screenshots/
            e2e/test-results/
            e2e/report/
            /tmp/clang-tidy-report.txt
            /tmp/cppcheck-report.txt
          if-no-files-found: ignore
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Collapse CI to single nix run .#test job

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

### Task 11: End-to-end smoke test

**Files:**
- None (verification only)

- [ ] **Step 1: Run `nix flake show` to confirm app list**

```bash
nix flake show 2>&1
```

Expected output should include `lint`, `build`, `smoke`, `test` and the 4 `*-test` apps. Should NOT include `ci`, `*-regression`.

- [ ] **Step 2: Run `lint` tier**

```bash
nix run .#lint
echo "exit=$?"
```

Expected: runs all linters, exits 0 (or non-zero if findings; inspect output).

- [ ] **Step 3: Run `build` tier with `--all`**

```bash
nix run .#build -- --all
echo "exit=$?"
```

Expected: lint passes, then all 4 targets build. Should take <2 min.

- [ ] **Step 4: Run individual test app**

```bash
nix run .#ra-native-test
echo "exit=$?"
```

Expected: runs `first-run-pass-94.sh`.

- [ ] **Step 5: Verify `--full` flag works**

```bash
nix run .#ra-wasm-test -- --full 2>&1 | head -20
```

Expected: runs WASM server, executes T1+T11+T3+T4+T5+T8+T9+T10.

---

### Task 12: Cleanup and final verification

**Files:**
- None (verification only)

- [ ] **Step 1: Check for any remaining references to deleted scripts**

```bash
rg -l 'ci-local\.sh|scripts/regression/ra-native\.sh|scripts/regression/td-native\.sh|scripts/regression/ra-wasm\.sh|scripts/regression/td-wasm\.sh' --type-not nix 2>/dev/null || echo "No stale references"
```

- [ ] **Step 2: Check for remaining `*-regression` references in flake.nix**

```bash
rg 'regression' flake.nix
```

Expected: no output (all removed).

- [ ] **Step 3: Run `shellcheck` on all new scripts**

```bash
shellcheck scripts/lint.sh scripts/_gating.sh scripts/build.sh scripts/smoke.sh scripts/test.sh scripts/test-runner.sh
```

Fix any warnings found.

- [ ] **Step 4: Run `shfmt` on all new scripts**

```bash
shfmt -w scripts/lint.sh scripts/_gating.sh scripts/build.sh scripts/smoke.sh scripts/test.sh scripts/test-runner.sh
```

- [ ] **Step 5: Run the full `test` tier (optional — may be slow)**

```bash
nix run .#test -- --all
echo "exit=$?"
```

Expected: lint + build + full regression for all targets. All gates pass.
