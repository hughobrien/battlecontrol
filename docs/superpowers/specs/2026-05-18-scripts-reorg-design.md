# Scripts Reorganization

Reorganize the flat `scripts/` directory into game-specific subdirectories (`ra/`, `td/`) to reduce clutter and make the structure self-documenting.

## Motivation

The `scripts/` directory has grown flat with ~50 files mixing Red Alert (RA), Tiberian Dawn (TD), and shared utility scripts. This makes it harder to find what applies to which game, especially for AI agents and new contributors.

## Scope

Move existing files only — no new scripts, no functional changes. Update all internal references across the repo.

## New Structure

```
scripts/
├── ra/
│   ├── ra-autostart-patch.py
│   ├── ra-scenario-patch.py
│   ├── wine-ra.sh
│   └── regression/
│       ├── T11-ra-native-m2-smoke.sh
│       └── T6-ra-native-smoke.sh
├── td/
│   ├── td-activateapp-patch.py
│   ├── td-ddmode-patch.py
│   ├── td-focus-skip-patch.py
│   ├── td-game-in-focus-patch.py
│   ├── td-ioport-patch.py
│   ├── td-scenario-patch.py
│   ├── td-setcoop-hwnd-patch.py
│   ├── td-side-preview-skip-patch.py
│   ├── td-vqa-skip-patch.py
│   ├── wine-td.sh
│   ├── wine-gdi-m1.sh          (C&C95 alias for TD)
│   ├── wine-gdi-m2.sh
│   ├── wine-nod-l1.sh
│   ├── wine-nod-m1.sh
│   ├── setup-run-td.sh
│   ├── run-td-cheat.sh
│   └── regression/
│       ├── T12-td-native-m2-smoke.sh
│       └── T5-td-native-menu.sh
├── drivers/                     (unchanged — shared capture drivers)
├── __pycache__/                 (ignored, regenerated)
├── _gating.sh                   (shared)
├── build-native.sh              (shared)
├── build.sh                     (shared)
├── capture-checkpoint.py        (shared — orchestrator, imports from drivers/)
├── check.sh                     (shared)
├── ddscl-patch.py               (shared — applied to both RA and TD builds)
├── extract_mix.py               (shared)
├── ra/ra-native-smoke.sh        (ra — release smoke test)
├── focus-skip-patch.py          (shared)
├── game-in-focus-patch.py       (shared)
├── generate-include-shim.py     (shared)
├── lint-lp64.py                 (shared)
├── lint.sh                      (shared)
├── nocd-patch.py                (shared — applied to both RA and TD builds)
├── parity-compare.py            (shared)
├── parity-report.sh             (shared)
├── parity.sh                    (shared)
├── probe-layout.cpp             (shared)
├── regression.sh                (shared — orchestrator, calls test-runner.sh)
├── run-e2e.sh                   (shared)
├── serve-wasm.sh                (shared)
├── test-runner.sh               (shared — dispatches by game+platform)
├── test.sh                      (shared)
├── vqa-compare.py               (shared)
├── vqa-decode.py                (shared)
├── vqa-skip-patch.py            (shared — applied to both RA and TD builds)
├── xvfb-ensure.sh               (shared)
```

## References to Update

| File | What to change |
|------|---------------|
| `scripts/test-runner.sh` | `scripts/run-td-cheat.sh` → `scripts/td/run-td-cheat.sh`; `scripts/regression/*` → `scripts/{ra,td}/regression/*` |
| `scripts.md` | All path references for moved scripts |
| `AGENTS.md` | Script paths in documentation blocks |
| `AGENT-FLOW.md` | References to `scripts/setup-run-td.sh`, `scripts/xvfb-ensure.sh` (present) |
| `ARCH.md` | References to `scripts/run-td-cheat.sh`, `scripts/setup-run-td.sh` |
| `workflows.md` | Any path references to moved scripts |
| Various `docs/` | Paths in plans, specs, and findings docs |
| Various `skills/` | Paths in SKILL.md files for wine-testing, native-build, parity-comparison, etc. |

No changes needed in `flake.nix` — it only references shared scripts (lint.sh, build.sh, test.sh, check.sh, regression.sh, parity.sh, nocd-patch.py, ddscl-patch.py, generate-include-shim.py).

## Order of Operations

1. `git mv` game-specific scripts into `scripts/ra/` and `scripts/td/`
2. `git mv` regression scripts into `scripts/ra/regression/` and `scripts/td/regression/`
3. Delete empty `scripts/regression/` directory
4. Update `scripts/test-runner.sh` paths
5. Update `scripts.md` paths
6. Update docs (`AGENTS.md`, `AGENT-FLOW.md`, `ARCH.md`, `workflows.md`, `docs/`, `skills/`)
7. Verify with `git diff --stat` and `nix run .#lint`
