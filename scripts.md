# Scripts & Commands Reference
Comprehensive catalog of all commands across two invocation surfaces:
- **Nix apps** (`nix run .#<name>`) — primary CLI interface
- **Scripts** (`scripts/`, `wasm/`) — implementation layer


## Cross-Reference Matrix
| Action | Nix App | Script(s) | CI Job | npm Script |
|--------|---------|-----------|--------|------------|
| Lint | `lint` | `scripts/lint.sh` | pre-commit hook | — |
| Check | `check` | `scripts/check.sh` | — | — |
| Build | `build` | `scripts/build.sh` | `ci.yml → regression` | — |
| Test | `test` | `scripts/test.sh` | `ci.yml → regression` | — |
| Regression | `regression` | `scripts/regression.sh` | `ci.yml → regression` | — |
| Serve | `serve` | `wasm/serve-coop.py` + `wasm/serve-assets.py` | — | — |
| Parity | `parity` | `scripts/parity.sh` | — | — |
| Capture (checkpoint) | — | `scripts/capture-checkpoint.py` | — | — |
| Release | `release` | `scripts/first-run-pass-94.sh` + cmake + tar | `release.yml` | — |
| Run RA | `ra` | native binary (via flake app) | — | — |
| Run TD | `td` | native binary (via flake app) | — | — |
| Default | `default` | → `ra` | — | — |
| E2E RA gameplay | — | — | — | `test:e2e:ra` |
| E2E TD gameplay | — | — | — | `test:e2e:td` |
| E2E WASM parity | — | — | — | `test:e2e:wasm-parity` |
| E2E TD compare | — | — | — | `test:e2e:td-compare` |
| E2E TIM-705 eq. | — | — | — | `test:e2e:tim705` |


## By Category
### Build
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Native build | `nix run .#build` | Build RA and/or TD native Linux (diff-gated). |
| | `cmake --preset linux-native && cmake --build build --target ra --parallel` | Direct single-target native build. |
| WASM build | `nix run .#build` | Build ra.wasm and/or td.wasm (diff-gated). |
| | `emcmake cmake --preset wasm && cmake --build build-wasm --target ra --parallel` | Direct single-target WASM build. |
| `build-stub-thipx` | nix app | Build | Build stub THIPX32.DLL for Wine 11 wow64 compat. |
| | `scripts/build-stub-thipx.sh` | Same, directly. |
| Release (RA+TD) | `nix run .#release` | Build + strip + tarball both binaries. |
### Test / QA
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Lint | `nix run .#lint` | Fast linters (LP64, ruff, shellcheck, yamllint, nixfmt, /opt audit). <10s. |
| Build | `nix run .#build [--all] [--base REF]` | Lint + diff-gated compile. |
| Test | `nix run .#test [--all] [--base REF]` | Build + CI-tier boot tests (T1/T2, first-run-pass). |
| Regression | `nix run .#regression` | Build + full regression (all targets, no flags). |
| Test (single game) | `bash scripts/test-runner.sh <game> <platform> [--full]` | Run boot or full regression for a single game+platform. |
### CI / Gate
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Full CI locally | `nix run .#regression` | Run every gate: lint → build → full regression for all targets. |
| Pre-push check | `nix run .#test` | Diff-gated: build + boot tests for changed targets. |
| Pre-commit check | `nix run .#lint` | Fast linters (<10s, installed as git hook). |
| Deep static analysis | `nix run .#check` | clang-tidy + cppcheck (~5 min, on-demand). |
### Capture / Screenshot
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Wine capture | `bash scripts/wine-cnc-capture.sh` | Generic RA95.EXE capture via cnc-ddraw under Wine + Xvfb. |
| | `scripts/wine-cnc-capture.sh` | Generic capture script. |
| | `scripts/wine-ra.sh [exePath] [dataDir]` | RA title/menu capture under Wine + Xvfb. |
| | `scripts/wine-td.sh [exePath] [dataDir]` | TD title/menu capture under Wine + Xvfb. |
| | `scripts/wine-ra-setup.sh` | Resolve RA95.EXE + DLLs from Nix store. |
| | `scripts/wine-td-setup.sh` | Resolve C&C95.EXE from explicit path. |
| | `scripts/wine-ra-difficulty-capture.sh` | Capture difficulty dialog screenshots (menu, dialog, faction). |
| | `scripts/wine-gdi-m1.sh` | C&C95.EXE → GDI Mission 1 gameplay. |
| | `scripts/wine-gdi-m2.sh` | C&C95.EXE → GDI Mission 2 gameplay. |
| | `scripts/wine-nod-l1.sh` | C&C95.EXE → Nod Mission 1 gameplay. |
| | `scripts/wine-nod-m1.sh` | C&C95.EXE → Nod Mission 1 (with side-select click). |
| Capture checkpoint | `python3 scripts/capture-checkpoint.py -- <mode> <id> --targets <t>` | Unified orchestrator: run any mission/VQA at any frame across Wine/native/WASM. |
| | `scripts/capture-checkpoint.py` | Same, directly. |
| | `scripts/drivers/wine.py` | Wine capture driver (class `WineCapture`). |
| | `scripts/drivers/native.py` | Native capture driver (class `NativeCapture`). |
| | `scripts/drivers/wasm.py` | WASM capture driver (class `WasmCapture`). |
| | `scripts/drivers/compare.py` | Compare driver (wraps `parity-compare.py`). |
| | `scripts/drivers/common.py` | Shared helpers (Xvfb, ffmpeg, screenshot validation, process cleanup). |
### Parity / Comparison
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Parity | `nix run .#parity -- check <scene> [--mode vqa|gameplay] [--targets <t>]` | Capture + compare across targets in one command. |
| | `bash scripts/parity.sh` | Same, directly. |
| | `python3 scripts/parity-compare.py` | Low-level SSIM compare (used by parity.sh internally). |
| | `python3 scripts/vqa-decode.py` | Decode VQA frames from MIX (used to generate goldens). |
| | `bash scripts/parity-report.sh` | Low-level multi-target comparison report. |
| Golden gen (archived) | `scripts/archive/gen-gameplay-goldens.sh` | ⚠️ Subsumed by `capture-checkpoint.py` + `drivers/`. |
### Lint / Audit
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Lint | `nix run .#lint` | Fast linters: LP64 + ruff + yamllint + shellcheck + shfmt + nixfmt + /opt audit. <10s. |
| | `bash scripts/lint.sh` | Same, directly. |
| Check | `nix run .#check` | Heavy static analysis: clang-tidy + cppcheck. ~5 min, on-demand. |
| | `bash scripts/check.sh` | Same, directly. |
| LP64 lint | `python3 scripts/lint-lp64.py [--errors-only]` | Scan C++ for LP64 hazards (also included in `lint`). |
| Include shim | `scripts/generate-include-shim.py` | Regenerate case-folding include shim (auto-run by CMake). |
| | `cmake --build <dir>` | Auto-regenerates as build dependency. |
| Layout probe | `scripts/probe-layout.cpp` | C++ layout probe: prints sizeof/offsetof for LP64 struct audit. |
### Serve / Dev Server
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Serve both | `nix run .#serve [port]` | Start WASM + asset dev servers. |
| | `python3 wasm/serve-coop.py <port> <build-dir>` | Same, directly. |
| Serve assets (direct) | `python3 wasm/serve-assets.py <assetDir> <port>` | Start asset server directly (no nix app — use `serve` for both). |
| Serve both | `nix run .#serve` | Start both servers in background. |
### Iteration Loops
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Full regression | `nix run .#regression` | Lint → build → full regression for all targets. |
| Test | `nix run .#test` | Diff-gated: lint → build → boot tests for changed targets. |
### Utility
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Extract MIX | `python3 scripts/extract_mix.py` | Westwood MIX file extractor (classic + extended headers). |
| Setup TD run | `scripts/setup-run-td.sh` | Create TD smoke-test run dir with symlinks and CONQUER stubs. |
### Run
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Run RA | `nix run .#redalert` | Run native RA binary (reads `RA_ASSETS` for MAIN.MIX). |
| Run TD | `nix run .#tiberiandawn` | Run native TD binary (reads `TD_ASSETS` for CONQUER.MIX). |
### Wine Binary Patches (RA95.EXE)
These Python scripts apply binary patches to RA95.EXE:
| Patch | Script | What It Does | Order |
|-------|--------|-------------|-------|
| No-CD | `scripts/nocd-patch.py` | NOPs GetDriveType check — skip CD error dialog. | 1 |
| DDSCL | `scripts/ddscl-patch.py` | DDSCL_EXCLUSIVE → DDSCL_NORMAL + stub SetDisplayMode. | 2 |
| CD label (Allied) | `scripts/cdlabel-patch.py` | Zero first byte of "CD1" label for Wine. | 3 |
| CD label (Soviet) | `scripts/soviet-cdlabel-patch.py` | Zero first byte of "CD2" label for Wine. | 3 (Soviet) |
| Focus skip | `scripts/focus-skip-patch.py` | NOP three `while(!GameInFocus)` spin loops. | 4 |
| Game in focus | `scripts/game-in-focus-patch.py` | Pin `GameInFocus=TRUE` via entry-point detour. | 5 |
| VQA skip | `scripts/vqa-skip-patch.py` | Replace `Play_Movie` prologue with `RET`. | 6 |
| Scenario | `scripts/ra-scenario-patch.py` | Replace hardcoded "SCG01EA.INI" with target mission. | 7 |
| Auto-start | `scripts/ra-autostart-patch.py` | Four patches to `Select_Game()` for zero-click auto-boot. | 8 |
| Soviet M2 | `scripts/soviet-m2-scenario-patch.py` | Override SCU01EA.INI → SCU02EA.INI. | 7 (Soviet M2) |
### Wine Binary Patches (C&C95.EXE — Tiberian Dawn)
| Patch | Script | What It Does | Order |
|-------|--------|-------------|-------|
| Focus skip | `scripts/td-focus-skip-patch.py` | NOP three `while(!GameInFocus)` spin loops. | 1 |
| Game in focus | `scripts/td-game-in-focus-patch.py` | Pin `GameInFocus=1` via entry-point detour. | 2 |
| VQA skip | `scripts/td-vqa-skip-patch.py` | Replace `Play_Movie` prologue with `RET`. | 3 |
| ActivateApp | `scripts/td-activateapp-patch.py` | NOP `WM_ACTIVATEAPP` handler clearing focus. | 4 |
| DD mode | `scripts/td-ddmode-patch.py` | Stub `SetDisplayMode` → `DD_OK`. | 5 |
| SetCoop HWND | `scripts/td-setcoop-hwnd-patch.py` | Fix `SetCooperativeLevel(hwnd=0)` via code cave. | 6 |
| CD label (TD) | `scripts/td-cdlabel-patch.py` | Zero first byte of "GDI95" label. | 7 |
| IO port | `scripts/td-ioport-patch.py` | NOP VGA port-I/O polling loops. | 8 |
| Scenario | `scripts/td-scenario-patch.py` | Replace format string with hardcoded scenario. | 9 |
| Side preview skip | `scripts/td-side-preview-skip-patch.py` | NOP side-preview animation routine. | 10 |
### Verification Data
| File | What It Contains |
|------|-----------------|
| `scripts/wine-exe-hashes.json` | SHA-256 hashes for RA95.EXE and C&C95.EXE at various patch stages. |


## Flat Alphabetical Index
Every executable entry point, listed A–Z with its surface(s).
| Name | Surface | Category | Summary |
|------|---------|----------|---------|
| `build` | nix app | CI | Diff-gated build orchestrator (calls lint first). |
| `build-native.sh` | script | Build | Single-command native build (cmake + ninja RA/TD). |
| `build.sh` | script | CI | Lint + diff-gated compile (sources _gating.sh). |
| `capture-checkpoint.py` | script | Capture | Unified capture orchestrator. |
| `capture-native` | nix app | Capture | Removed — use `capture-checkpoint --targets native`. |
| `cdlabel-patch.py` | script | Patch (RA) | Zero CD1 label for Wine. |
| `ci` | nix app | CI | Removed — replaced by `lint`/`build`/`test`/`regression` tiers. |
| `ci-local.sh` | script | CI | Removed — replaced by `lint.sh`/`build.sh`/`test.sh`/`regression.sh`. |
| `parity` | nix app | Parity | Capture + compare across targets in one command. |
| `ddscl-patch.py` | script | Patch (RA) | DDSCL_EXCLUSIVE → DDSCL_NORMAL. |
| `extract_mix.py` | script | Utility | Westwood MIX file extractor. |
| `first-run-pass-94.sh` | script | Test | RA native smoke test. |
| `focus-skip-patch.py` | script | Patch (RA) | NOP GameInFocus spin loops. |
| `game-in-focus-patch.py` | script | Patch (RA) | Pin GameInFocus=TRUE. |
| `generate-include-shim.py` | script | Build | Regenerate case-folding include shim (auto-run by CMake). |
| `lint-lp64.py` | script | Lint | LP64 static hazard scanner. |
| `nocd-patch.py` | script | Patch (RA) | Skip CD error dialog. |
| `parity-compare.py` | script | Parity | SSIM + fill% + p99 pixel diff. |
| `parity-report.sh` | script | Parity | Three-way parity report shell. |
| `probe-layout.cpp` | script | Lint | C++ struct layout probe. |
| `ra-autostart-patch.py` | script | Patch (RA) | Zero-click auto-boot at Normal difficulty. |
| `ra-data-verify.py` | script | Lint | Verify RA MIX checksums. |
| `ra-scenario-patch.py` | script | Patch (RA) | Replace mission name in EXE. |
| `redalert` | nix app | Run | Run native RA binary. |
| `lint` | nix app | Lint | Fast linters: LP64, ruff, yamllint, shellcheck, shfmt, nixfmt, /opt audit. Pre-commit hook. |
| `lint.sh` | script | Lint | Fast linters in one script (sourced by build/test/regression). |
| `check` | nix app | Check | Heavy static analysis: clang-tidy + cppcheck (~5 min, on-demand). |
| `check.sh` | script | Check | Same, directly. |
| `test` | nix app | Test | Build + CI-tier boot tests. |
| `test.sh` | script | Test | Diff-gated build + boot test orchestrator. |
| `regression` | nix app | Regression | Build + full regression. |
| `regression.sh` | script | Regression | Full regression orchestrator (all targets, no gating). |
| `release` | nix app | Build | Build + strip + tarball both RA and TD. |
| `run-td-cheat.sh` | script | Test | TD native smoke with TD_CHEAT=1. |
| `serve` | nix app | Serve | Start both WASM + asset servers. |
| `setup-run-td.sh` | script | Utility | Create TD run directory. |
| `_gating.sh` | script | CI | Diff-analysis helper sourced by build/test/regression. |
| `build-native.sh` | script | Build | Single-command native build. |
| `run-e2e.sh` | script | Test | Xvfb + WASM server + Playwright test. |
| `serve-wasm.sh` | script | Serve | WASM dev server helper. |
| `vqa-decode.py` | script | Parity | VQA decode from MIX (wraps tools/vqa_dump + ffmpeg). |
| `xvfb-ensure.sh` | script | Utility | Idempotent Xvfb launcher. |
| `soviet-cdlabel-patch.py` | script | Patch (RA) | Zero CD2 label for Soviet. |
| `soviet-m2-scenario-patch.py` | script | Patch (RA) | Override Soviet M2 scenario. |
| `td-activateapp-patch.py` | script | Patch (TD) | Prevent WM_ACTIVATEAPP clearing focus. |
| `td-cdlabel-patch.py` | script | Patch (TD) | Zero GDI95 label. |
| `vqa-compare.py` | script | Parity | Compare two VQA decode output dirs. |
| `td-ddmode-patch.py` | script | Patch (TD) | Stub SetDisplayMode. |
| `td-focus-skip-patch.py` | script | Patch (TD) | NOP GameInFocus spin loops. |
| `td-game-in-focus-patch.py` | script | Patch (TD) | Pin GameInFocus=1. |
| `td-ioport-patch.py` | script | Patch (TD) | NOP VGA port-I/O polling. |
| `td-scenario-patch.py` | script | Patch (TD) | Replace scenario name in EXE. |
| `td-setcoop-hwnd-patch.py` | script | Patch (TD) | Fix SetCooperativeLevel HWND. |
| `td-side-preview-skip-patch.py` | script | Patch (TD) | NOP side-preview animation. |
| `td-vqa-skip-patch.py` | script | Patch (TD) | Skip TD cutscenes. |
| `test` | nix app | Test | Run e2e test spec. |
| `tiberiandawn` | nix app | Run | Run native TD binary. |
| `vqa-decode.py` | script | Parity | Extract VQA from MIX and decode with --engine. |
| `wasm-loop` | nix app | Loop | Removed — use `test` or `regression`. |
| `wine-cnc-capture.sh` | script | Capture | Generic RA95 Wine capture. |
| `wine-exe-hashes.json` | data | — | SHA-256 hashes for patched EXEs. |
| `wine-gdi-m1.sh` | script | Capture | GDI M1 gameplay capture. |
| `wine-gdi-m2.sh` | script | Capture | GDI M2 gameplay capture. |
| `wine-nod-l1.sh` | script | Capture | Nod L1 gameplay capture. |
| `wine-nod-m1.sh` | script | Capture | Nod M1 gameplay capture. |
| `wine-ra.sh` | script | Capture | RA title/menu capture. |
| `wine-ra-difficulty-capture.sh` | script | Capture | RA difficulty dialog capture. |
| `wine-ra-setup.sh` | script | Setup | Resolve RA95.EXE + DLLs from Nix. |
| `wine-td.sh` | script | Capture | TD title/menu capture. |
| `wine-td-setup.sh` | script | Setup | Resolve C&C95.EXE. |


## Archived Scripts
These live in `scripts/archive/` — subsumed by the Python `capture-checkpoint.py` orchestrator + `drivers/` modules:
| Archived Script | Subsumed By |
|----------------|-------------|
| `gen-gameplay-goldens.sh` | `capture-checkpoint.py` + `drivers/compare.py` |
| `native-capture.sh` | `capture-checkpoint.py mission --targets native` + `drivers/native.py` |
| `wine-allied-l1.sh` | `capture-checkpoint.py mission allied-l1 --targets wine` + `drivers/wine.py` |
| `wine-allied-m2.sh` | `capture-checkpoint.py mission allied-m2 --targets wine` |
| `wine-gameplay.sh` | `capture-checkpoint.py mission allied-l1 --targets wine --mode gameplay` |
| `wine-soviet-l1.sh` | `capture-checkpoint.py mission soviet-l1 --targets wine` |
| `wine-soviet-m2.sh` | `capture-checkpoint.py mission soviet-m2 --targets wine` |
| `wine-vqa-capture.sh` | `capture-checkpoint.py vqa <stem> --targets wine` |


## npm Scripts
| Script | Command |
|--------|---------|
| `test:e2e` | `playwright test` |
| `test:e2e:headed` | `playwright test --headed` |
| `test:e2e:ra` | `playwright test e2e/wasm-gameplay.spec.ts` |
| `test:e2e:td` | `playwright test e2e/td-gameplay.spec.ts` |
| `test:e2e:tim705` | `playwright test e2e/tim705-equivalence.spec.ts` |
| `test:e2e:tim705:wine` | `WINE_RA_READY=1 playwright test e2e/tim705-equivalence.spec.ts --grep wine` |
| `test:e2e:wasm-parity` | `playwright test e2e/tim710-wasm-parity.spec.ts` |
| `test:e2e:wasm-parity:wine` | `WINE_RA_READY=1 playwright test e2e/tim710-wasm-parity.spec.ts` |
| `test:e2e:td-compare` | `playwright test e2e/tim711-td-compare.spec.ts` |
| `test:e2e:td-compare:wine` | `WINE_TD_READY=1 playwright test e2e/tim711-td-compare.spec.ts` |
| `test:e2e:ra:ci` | Env-var-driven RA gameplay e2e for CI |
| `test:e2e:td:ci` | Env-var-driven TD gameplay e2e for CI |
| `test:e2e:ra-gameplay-audit` | RA gameplay audit |
| `test:e2e:td-wasm-audit` | TD WASM audit |
| `vqa-compare` | `python3 scripts/vqa-compare.py` |


## Naming Convention Summary
| Surface | Convention | Example |
|---------|-----------|---------|
| Nix apps | `kebab-case` | `build-native`, `capture-checkpoint` |
| Shell scripts | `kebab-case.sh` | `lint.sh`, `run-e2e.sh` |
| Python scripts | `kebab-case.py` | `lint-lp64.py`, `parity-compare.py` |
| npm scripts | `:` delimited | `test:e2e:ra`, `test:e2e:td` |


## Call Graph
```
nix run .#<name> ──→ Script
CI Workflow ──→ nix run .#<name> ──→ Script
             ↳ npx playwright test
```
Every invocation path converges at the script layer. Nix apps are thin wrappers
that call scripts; CI workflows call the same nix apps that developers use locally.
