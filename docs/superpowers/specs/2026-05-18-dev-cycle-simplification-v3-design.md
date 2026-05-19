# Dev Cycle Simplification v3 — Opinionated Defaults

## Goal

Simplify the developer experience further from v2's four-tier structure by making
opinionated default decisions: `regression` always runs everything, CI runs the
faster `test` tier, and the 8 per-game build/test apps are removed in favor of
the tier apps as the canonical interface.

## Changes

### 1. `regression` always runs all targets

`scripts/regression.sh` no longer sources `_gating.sh`. It calls `build.sh --all`
and always runs all 4 test suites (ra native, ra wasm, td native, td wasm) with
`--full`. No flags needed — `nix run .#regression` is the one-command full CI
locally.

`--all` and `--base REF` flags are removed from regression.sh. They are no-ops
since everything always runs.

| Before | After |
|--------|-------|
| `nix run .#regression -- --all` | `nix run .#regression` |
| diff-gates, may skip targets | always runs all targets |

### 2. CI runs `test` tier (not `regression`)

`.github/workflows/ci.yml` switches from `nix run .#regression -- --all` to
`nix run .#test -- --all`. CI becomes a fast gate (boot tests only). Full
regression is the local pre-push check.

Pre-push recommendation in AGENTS.md: `nix run .#test` (diff-gated boot tests),
not regression.

### 3. Remove 8 per-game build/test apps

Remove these nix apps from `flake.nix`:

- `ra-native-build` — redundant with `nix run .#build`
- `td-native-build` — redundant with `nix run .#build`
- `ra-wasm-build` — redundant with `nix run .#build`
- `td-wasm-build` — redundant with `nix run .#build`
- `ra-native-test` — redundant with `nix run .#test` / `.#regression`
- `td-native-test` — redundant with `nix run .#test` / `.#regression`
- `ra-wasm-test` — redundant with `nix run .#test` / `.#regression`
- `td-wasm-test` — redundant with `nix run .#test` / `.#regression`

For the rare case of single-target testing, `bash scripts/test-runner.sh ra native --full`
still works directly. The underlying scripts remain; only the thin nix app wrappers
are removed.

### 4. Update AGENTS.md

- Remove `ci_local()`, `nix run .#ci`, `nix run .#lint-all`, `nix run .#toolchain-check`
- "Before every push" → `nix run .#test`
- Replace function-style pseudocode with actual commands
- Edit-compile-test loop uses current tier commands
- Reference `nix run .#regression` as the "full CI locally" check

### 5. Update scripts.md

Remove references to the 8 removed apps. Update any stale messaging about flags on regression.

## Resulting App Surface

**After: 16 apps** (was 24)

| Category | Apps |
|----------|------|
| Run | `ra`, `td` |
| Tiers | `lint`, `build`, `test`, `regression` |
| Heavy analysis | `check` |
| Utility | `release`, `serve`, `screenshot`, `capture-wine`, `capture-checkpoint`, `parity-compare`, `parity-report`, `vqa-decode`, `vqa-compare` |

## Non-goals

- Not changing `lint.sh`, `build.sh`, `test.sh`, or their gating behavior
- Not changing `_gating.sh` (still used by `build.sh` and `test.sh`)
- Not changing `test-runner.sh` or the regression scripts in `scripts/regression/`
- Not archiving historical scripts (separate concern)
- Not touching `release`, `serve`, or the capture/parity utility apps

## Files to Modify

- `scripts/regression.sh` — remove `_gating.sh`, use `build.sh --all`, remove `--all`/`--base` handling
- `flake.nix` — remove 8 app definitions, drop their comment blocks
- `.github/workflows/ci.yml` — test → regression, update job name and comment
- `AGENTS.md` — remove dead references, update guidance
- `scripts.md` — remove 8 removed app entries, update regression entry
