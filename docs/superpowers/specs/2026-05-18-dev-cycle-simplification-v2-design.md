# Dev Cycle Simplification v2 — Split lint/check, rename smoke/test

## Goal

Evolve the existing four-tier workflow (`lint → build → smoke → test`) to:
- Move heavy static analysis (clang-tidy, cppcheck) out of `lint` into a standalone `check` tier
- Make `lint` fast enough to run automatically in the pre-commit hook (<10s)
- Rename `smoke` → `test` and `test` → `regression` for clarity
- Keep `check` as an on-demand deep-analysis command

## Tiers

| Tier | App | Does | Time target | When |
|------|-----|------|-------------|------|
| L1 | `lint` | LP64 audit, ruff, shellcheck/shfmt, yamllint, nixfmt, /opt audit | <10s | Pre-commit hook (automatic) |
| L2 | `build` | lint + diff-gated native + WASM compile | <1 min | Dev cycle |
| L3 | `test` | build + CI-tier boot tests (T1/T2 ra-wasm/td-wasm, ra-native first-run, td-native cheat) | <2 min | Dev cycle |
| L4 | `regression` | build + full suite (test-runner.sh --full) | minutes | Before push / local CI |
| — | `check` | clang-tidy + cppcheck (~5 min) | ~5 min | On-demand |

**Chain:** `lint → build → test → regression` (each calls the previous). `check` is standalone.

## What changes

### 1. Split lint.sh

**Current** `lint.sh` runs all of:
- LP64 hazard audit
- clang-tidy (cmake configure + find + clang-tidy — ~3 min)
- cppcheck (~90s)
- ruff (check + format)
- shellcheck + shfmt
- yamllint
- nixfmt
- /opt path audit

**New** `lint.sh` (fast, <10s):
- LP64 hazard audit
- ruff (check + format)
- shellcheck + shfmt
- yamllint
- nixfmt
- /opt path audit

**New** `check.sh` (standalone, on-demand):
- clang-tidy
- cppcheck

### 2. Rename smoke → test, test → regression

| File | Rename to | App name |
|------|-----------|----------|
| `scripts/smoke.sh` | `scripts/test.sh` | `nix run .#test` |
| `scripts/test.sh` | `scripts/regression.sh` | `nix run .#regression` |

The `smoke.sh` → `test.sh` gets the `--full` forwarding that `test.sh` currently has.
The `test.sh` → `regression.sh` always runs `test-runner.sh --full`.

### 3. Flake app changes

| App | Action |
|-----|--------|
| `.#lint` | Stays, content trimmed to fast checks |
| `.#check` | **New** — runs check.sh |
| `.#smoke` | Renamed to `.#test` |
| `.#test` | Renamed to `.#regression` |
| `.#build` | Unchanged (calls lint, stays fast) |

### 4. Pre-commit hook

Installed by devShell shellHook. Calls `nix run .#lint`. Unchanged in mechanism, but now fast enough that it won't annoy.

### 5. GitHub CI (`ci.yml`)

Currently runs `nix run .#test -- --all`. Changes to `nix run .#regression -- --all` (same behavior, new name). The `gh-pages.yml` and `release.yml` are unchanged.

## Files to create

- `scripts/check.sh` — clang-tidy + cppcheck, extracted from current lint.sh

## Files to modify

- `scripts/lint.sh` — remove clang-tidy and cppcheck sections
- `scripts/smoke.sh` → rename to `scripts/test.sh`, update internal references
- `scripts/test.sh` → rename to `scripts/regression.sh`, always pass `--full`
- `flake.nix` — update app definitions, add `check` app
- `.github/workflows/ci.yml` — update app reference
- `AGENTS.md`, `workflows.md`, `scripts.md` — update documentation

## Non-goals

- Not changing the four-tier chain structure itself (each tier still calls the prev)
- Not changing diff-gating in `_gating.sh`
- Not changing `test-runner.sh`
- Not changing build-native.sh, build.sh, or the WASM build apps
