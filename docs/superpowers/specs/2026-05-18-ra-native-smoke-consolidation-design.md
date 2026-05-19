# RA Native Smoke Test Consolidation

Consolidate the three overlapping RA native smoke tests into a single script with mode selection, removing the stale build step from `first-run-pass-94.sh` and cleaning up the scripts tree.

## Motivation

Three scripts (`first-run-pass-94.sh`, `T6-ra-native-smoke.sh`, `T11-ra-native-m2-smoke.sh`) cover overlapping scenarios with duplicated Xvfb/crash-scan logic. The names are opaque (TIM ticket refs, T-numbering). `first-run-pass-94.sh` also contains a manual `clang++` compilation step that predates the cmake build — the same build is now handled by `build-native.sh`.

## Scope

Existing files only — no new scenarios or acceptance criteria. The behavioral contract (what gets tested, for how long, to what standard) does not change.

## New File Layout

```
scripts/ra/
├── ra-native-smoke.sh          # single entry point (replaces 3 files)
├── ra-autostart-patch.py
├── ra-scenario-patch.py
├── wine-ra.sh
└── regression/                 # DELETED (empty)

scripts/
├── first-run-pass-94.sh        # DELETED
└── ... (shared scripts unchanged)
```

## Single Script: `scripts/ra/ra-native-smoke.sh`

### Modes

| Invocation | Duration | Scenario | Acceptance |
|---|---|---|---|
| `bash scripts/ra/ra-native-smoke.sh` (default) | 30s | `RA_AUTOSTART=1` | ≥100 frames, zero crashes |
| `bash scripts/ra/ra-native-smoke.sh release` | 120s | `RA_AUTOSTART=1` | ≥1 win cycle, ≥1000 frames, zero crashes, FPS measured |
| `bash scripts/ra/ra-native-smoke.sh m2` | 120s | `RA_SCENE=SCG02EA.INI` | ≥200 frames, zero crashes |

`--help` or no arg with invalid flags → print usage (modes + description) and exit 0.

Invalid mode → error message listing valid modes, exit 1.

### ELF Resolution

Try in order, first-found wins:
1. `build/ra` (produced by `build-native.sh` / cmake)
2. `build/first-run-pass-94/redalert.elf` (old build path, backward compat)
3. Neither → `exit 77` with message suggesting `bash scripts/build-native.sh ra`

### Internal Structure

- **xvfb_start / xvfb_stop** — inline shell functions (no separate lib file). Trap stop on EXIT.
- **analysis** per mode:
  - **boot / default:** grep for max_frame + crash signals (same logic as current T6)
  - **release:** Python analysis block inlined from current `first-run-pass-94.sh` (win cycles, FPS probes, 1000-frame criterion)
  - **m2:** grep for max_frame + crash signals (same logic as current T11)
- Log written to `e2e/screenshots/ra-native-smoke-{mode}.log`
- **Skips (exit 77):** ELF not found, `build/run-172/` assets not staged

## Test Runner Dispatch

In `scripts/test-runner.sh` `ra-native)` case:

- **Boot tier (always):** `run_script scripts/ra/ra-native-smoke.sh release`
- **`--full` tier:** adds `run_script scripts/ra/ra-native-smoke.sh m2`

`boot` mode is not dispatched by test-runner — it is a dev-loop convenience only.

## References to Update

| File | Change |
|---|---|
| `scripts/test-runner.sh` | `first-run-pass-94.sh` → `scripts/ra/ra-native-smoke.sh release`; drop T6, inlines T11 → `m2` |
| `scripts/regression.sh` | No change — still calls `test-runner.sh --full` which handles dispatch |
| `scripts.md` | Update descriptor table: replace 3 entries with 1, update path references |
| `RELEASE.md` | `first-run-pass-94.sh` → `scripts/ra/ra-native-smoke.sh release` |
| `README.md` | Same update |
| `CMakeLists.txt` | Comment referencing `first-run-pass-94.sh` → update |
| `docs/smoke-test-design-rule.md` | Audit table: `first-run-pass-94.sh` → `ra-native-smoke.sh release`; T6/T11 entries → remove or point to modes |
| `docs/superpowers/plans/2026-05-18-dev-cycle-simplification.md` | Paths to `first-run-pass-94.sh` |
| `docs/superpowers/specs/2026-05-18-scripts-reorg-design.md` | References to `first-run-pass-94.sh` |
| `e2e/regression/README.md` | Refs to `build/first-run-pass-94/redalert.elf` |
| `skills/ci-cd/SKILL.md` | Path to `scripts/first-run-pass-94.sh` |

## Order of Operations

1. Write `scripts/ra/ra-native-smoke.sh`
2. Remove `scripts/first-run-pass-94.sh`
3. Remove `scripts/ra/regression/T6-ra-native-smoke.sh`
4. Remove `scripts/ra/regression/T11-ra-native-m2-smoke.sh`
5. Remove `scripts/ra/regression/` (empty)
6. Update `scripts/test-runner.sh`
7. Update all docs references
8. Verify: `bash scripts/ra/ra-native-smoke.sh --help` shows modes; each mode runs; `test-runner.sh ra native` passes
