# Dev Cycle Simplification — Four-Tier Workflow

## Goal

Collapse the 26-app flake into a four-tier hierarchy (`lint` → `build` → `smoke` → `test`)
where each tier calls the one before it. Local machine is the primary CI; GitHub is
a build-and-deploy pipeline.

## Tiers

| Tier | App | Does | Time target |
|------|-----|------|-------------|
| L1 | `lint` | static analysis, format checks, `/opt` audit | seconds |
| L2 | `build` | L1 + diff-gated compile | <1 min |
| L3 | `smoke` | L2 + boot tests (T1/T2 + first-run-pass) | <2 min |
| L4 | `test` | L3 + full regression (`--full`) | minutes |

Each backed by a shell script: `scripts/lint.sh`, `scripts/build.sh`, `scripts/smoke.sh`, `scripts/test.sh`.

## Diff gating (`build.sh`, inherited by `smoke.sh` and `test.sh`)

Files changed → targets built. Default base: `origin/master`. Falls back to `HEAD~1`.

| Changed path | Build |
|---|---|
| `REDALERT/**` | ra-native, ra-wasm |
| `TIBERIANDAWN/**` | td-native, td-wasm |
| `linux/win32-stubs/**` | all 4 |
| `CMakeLists.txt`, `CMakePresets.json` (any dir) | all 4 |
| `wasm/**` | ra-wasm, td-wasm |
| `e2e/**`, `scripts/**`, `.github/**`, `*.nix`, `docs/**`, `*.md` | lint only |
| no match | `--all` (build everything — safe default) |

Options: `--all` forces every gate, `--base REF` diff against a different ref.

## `--full` flag on test apps

The 4 `{game}-{platform}-test` apps forward `$@`. The `REGRESSION_TIER=full` env-var
path already exists in the regression scripts; expose it as a CLI flag:

```
nix run .#ra-wasm-test              # ci tier (T1+T2)
nix run .#ra-wasm-test -- --full    # full tier (T1–T10)
```

Same pattern for all 4 test apps.

## Nix apps (after)

**New (4):** `lint`, `build`, `smoke`, `test`

**Kept as-is (4):** `ra-native-build`, `td-native-build`, `ra-wasm-build`, `td-wasm-build`

**Kept, `$@` forwarding added (4):** `ra-native-test`, `td-native-test`, `ra-wasm-test`, `td-wasm-test`

**Kept unchanged:** `ra`, `td`, `release`, `serve`, `screenshot`, `capture-wine`, `capture-checkpoint`, `parity-compare`, `parity-report`, `vqa-decode`, `vqa-compare`

**Removed (5):** `ci`, `ra-native-regression`, `td-native-regression`, `ra-wasm-regression`, `td-wasm-regression`

## Removed files

- `scripts/ci-local.sh` — buggy (dead reference to nonexistent `ci-wasm-smoke.sh`, gate numbering gaps), overlapped with `lint.sh`
- `scripts/regression/ra-native.sh` — logic absorbed into `ra-native-test` with `--full`
- `scripts/regression/td-native.sh` — same
- `scripts/regression/ra-wasm.sh` — same
- `scripts/regression/td-wasm.sh` — same

## New files

- `scripts/lint.sh` — all linters + `/opt` path audit, extracted from `flake.nix` inline shell
- `scripts/build.sh` — diff-gated build orchestrator
- `scripts/smoke.sh` — build + boot tests
- `scripts/test.sh` — smoke + full regression

## devShell pre-commit hook

Current hook has ~40 lines of inline shell running linters. Replace with:

```
nix run .#lint
```

Same check, one line, no duplicated logic.

## GitHub CI

`ci.yml` collapses to a single job running `nix run .#test`. `gh-pages.yml` and
`release.yml` unchanged. CI exists to confirm the deploy artifact; it is not the
primary test surface.
