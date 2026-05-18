# Scripts & Commands Reference
Comprehensive catalog of all commands across two invocation surfaces:
- **Nix apps** (`nix run .#<name>`) — primary CLI interface
- **Scripts** (`scripts/`, `wasm/`) — implementation layer


## Cross-Reference Matrix
| Action | Nix App | Script(s) | CI Job | npm Script |
|--------|---------|-----------|--------|------------|
|Build native|`build-native`|`scripts/build-native.sh`|`ci.yml → build`|—|
|Build WASM|`build-wasm`|inline (flake.nix)|`ci.yml → build-wasm`|—|
|Validate WASM|`validate-wasm`|inline (flake.nix)|`ci.yml → build-wasm`|—|
|Serve (WASM+assets)|`serve`|`wasm/serve-coop.py` + `wasm/serve-assets.py`|—|—|
|WASM screenshot|`screenshot`|inline (flake.nix)|—|—|
|Run e2e test|`test`|`scripts/run-e2e.sh`|—|`test:e2e`|
|Run T1 (RA boot)|`test-t1`|`scripts/run-e2e.sh`|`ci.yml → build-wasm`|—|
|Run T2 (TD boot)|`test-t2`|`scripts/run-e2e.sh`|`ci.yml → build-wasm`|—|
|CI gate (local)|`ci`|`scripts/ci-local.sh`|—|—|
|CI native build|`build-native`|`scripts/build-native.sh`|`ci.yml → build`|—|
|WASM loop (CI)|`wasm-loop`|inline (flake.nix)|`ci.yml → build-wasm`|—|
|WASM loop smoke|`wasm-loop`|`scripts/run-e2e.sh` (via test-t1+test-t2)|called by wasm-loop|—|
|CI test run|`test`|`scripts/run-e2e.sh`|`ci.yml → build-wasm` (T3/T6/T7/T8/T9)|—|
|CI VQA pixel-diff|`vqa-check`|`scripts/vqa-check.sh`|`ci.yml → vqa-pixel-diff`|—|
|CI ccache setup|`ci-cc-setup`|inline (flake.nix)|`gh-pages.yml`|—|
|CI gate + static analysis|`ci`|`scripts/ci-local.sh`|`ci.yml → ci`|—|
|Toolchain check|`toolchain-check`|`scripts/toolchain-check.sh`|—|—|
|Wine check|`wine-check`|`scripts/wine-check.sh`|—|—|
|Wine capture|`capture-wine`|`scripts/wine-cnc-capture.sh`|`ci.yml → wine-comparison`|—|
|Capture orchestrator|`capture-checkpoint`|`scripts/capture-checkpoint.py`|—|—|
|Parity compare|`parity-compare`|`scripts/parity-compare.py`|—|—|
|Parity report|`parity-report`|`scripts/parity-report.sh`|—|—|
|VQA pixel diff|`vqa-check`|`scripts/vqa-pixel-diff.py`|—|—|
|VQA golden frames|`vqa-golden`|`scripts/gen-vqa-golden.py`|—|—|
|VQA cinematic compare|`vqa-cinematic`|`scripts/cinematic-compare.py`|—|`cinematic-compare`|
|LP64 lint|`lint-lp64`|`scripts/lint-lp64.py`|—|—|
|Full lint suite|`lint-all`|inline (flake.nix)|—|—|
|Include shim|`include-shim`|`scripts/generate-include-shim.py`|—|—|
|Edit loop (native)|`edit-loop`|inline (flake.nix)|—|—|
|WASM loop|`wasm-loop`|inline (flake.nix)|—|—|
|Release (RA+TD native)|`release`|`scripts/first-run-pass-94.sh` + cmake + tar|`release.yml`|—|
|Build stub THIPX|`build-stub-thipx`|`scripts/build-stub-thipx.sh`|—|—|
|Regression suite|`regression`|`scripts/regression-suite.sh`|—|—|
|Smoke test (RA)|`smoke-ra`|`scripts/first-run-pass-94.sh`|—|—|
|Smoke test (TD)|`smoke-td`|`scripts/run-td-cheat.sh`|—|—|
|Run RA|`redalert`|(cmake target)|—|—|
|Run TD|`tiberiandawn`|(cmake target)|—|—|
|E2E RA gameplay|—|—|—|`test:e2e:ra`|
|E2E TD gameplay|—|—|—|`test:e2e:td`|
|E2E WASM parity|—|—|—|`test:e2e:wasm-parity`|
|E2E TD compare|—|—|—|`test:e2e:td-compare`|
|E2E TIM-705 eq.|—|—|—|`test:e2e:tim705`|


## By Category
### Build
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Native build | `nix run .#build-native [ra\|td\|both] [clang]` | Configure + build RA and/or TD native Linux with cmake + ninja. Calls `scripts/build-native.sh`. |
| | `scripts/ci-local.sh` | Also runs native build as G1. |
| WASM build | `nix run .#build-wasm [ra\|td\|both]` | Build ra.wasm and/or td.wasm via emcmake + cmake + ninja. |
| THIPX stub | `nix run .#build-stub-thipx` | Build stub THIPX32.DLL for Wine 11 wow64 compat. |
| | `scripts/build-stub-thipx.sh` | Same, directly. |
| Release (RA+TD) | `nix run .#release` | Build + strip + tarball both binaries. |
### Test / QA
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Run e2e test | `nix run .#test -- <spec> [args]` | Run any Playwright e2e spec under Xvfb + WASM server. |
| | `npx playwright test <spec>` | Same, directly (if servers already running). |
| T1 RA boot | `nix run .#test-t1` | Shorthand for RA WASM boot smoke test. |
| T2 TD boot | `nix run .#test-t2` | Shorthand for TD WASM boot smoke test. |
| Regression suite | `nix run .#regression [tier]` | Run T1-T12 regression suite. Set `REGRESSION_TIER=ci\|full`. |
| | `scripts/regression-suite.sh` | Same, directly. |
| Smoke RA | `nix run .#smoke-ra` | Run RA native for 30s with `RA_AUTOSTART=1`, verify 100+ frames. |
| | `scripts/first-run-pass-94.sh` | Same, directly. |
| Smoke TD | `nix run .#smoke-td` | Run TD native with `TD_CHEAT=1`, verify debug cheat progression. |
| | `scripts/run-td-cheat.sh` | Same, directly. |
| WASM screenshot | `wasm_screenshot(target, waitMs, ...)` | Build WASM, serve, open headless Chromium, capture screenshot. |
| | `nix run .#screenshot` | Same, via nix. |
### CI / Gate
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Local CI | `nix run .#ci [--wasm-only\|--native-only]` | Run all local CI gates (native build, LP64, WASM, VQA, /opt audit). |
| | `scripts/ci-local.sh [--wasm-only\|--native-only]` | Same, directly. |
| CI native build | `nix run .#build-native` | Native build with integrated ELF 64-bit validation. |
| WASM loop | `nix run .#wasm-loop` | Build → validate → smoke T1+T2. |
| CI WASM smoke | `nix run .#ci-wasm-smoke` | Xvfb + serve-coop + T1+T2 Playwright tests. |
| CI test run | `nix run .#test -- <spec>` | Run one Playwright spec under Xvfb + WASM (for asset-gated tests). |
| CI VQA | `nix run .#vqa-check` | Generate test VQA + pixel-diff (for CI). |
### Capture / Screenshot
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Wine capture | `nix run .#capture-wine -- <exe> <data> <out>` | Generic RA95.EXE capture via cnc-ddraw under Wine + Xvfb. |
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
| Capture checkpoint | `nix run .#capture-checkpoint -- <mode> <id> --targets <t>` | Unified orchestrator: run any mission/VQA at any frame across Wine/native/WASM. |
| | `scripts/capture-checkpoint.py` | Same, directly. |
| | `scripts/drivers/wine.py` | Wine capture driver (class `WineCapture`). |
| | `scripts/drivers/native.py` | Native capture driver (class `NativeCapture`). |
| | `scripts/drivers/wasm.py` | WASM capture driver (class `WasmCapture`). |
| | `scripts/drivers/compare.py` | Compare driver (wraps `parity-compare.py`). |
| | `scripts/drivers/common.py` | Shared helpers (Xvfb, ffmpeg, screenshot validation, process cleanup). |
### Parity / Comparison
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Parity compare | `nix run .#parity-compare -- <imgA> <imgB> [--label] [--threshold-ssim]` | SSIM + fill% + p99 pixel diff between two PNGs. |
| | `scripts/parity-compare.py` | Same, directly. |
| Parity report | `nix run .#parity-report -- --mode <vqa\|gameplay> --targets <t> <scene>` | Three-way parity report: compare golden frames against wine/native/wasm captures. |
| | `scripts/parity-report.sh` | Same, directly. |
| VQA pixel diff | `nix run .#vqa-check [--threshold N]` | Compare our VQA decoder vs ffmpeg golden frames via p99 pixel-delta. |
| | `scripts/vqa-pixel-diff.py` | Same, directly. |
| VQA golden | `nix run .#vqa-golden -- <vqaFile> <numFrames> [outDir]` | Decode VQA into N evenly-spaced golden PNGs for reference. |
| | `scripts/gen-vqa-golden.py` | Same, directly. |
| | `scripts/gen-all-vqa-goldens.sh` | Generate golden frames for all intro VQAs at once. |
| VQA cinematic | `nix run .#vqa-cinematic -- <MIX> [--threshold N]` | Scan MAIN.MIX for embedded VQAs, decode and compare vs ffmpeg. |
| | `scripts/cinematic-compare.py` | Same, directly. |
| TD cinematic | `scripts/td-cinematic-compare.py` | TD variant — extracts VQAs from MOVIES.MIX (no Blowfish). |
| Golden gen (archived) | `scripts/archive/gen-gameplay-goldens.sh` | ⚠️ Subsumed by `capture-checkpoint.py` + `drivers/`. |
### Lint / Audit
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| LP64 lint | `nix run .#lint-lp64` | Scan C++ for LP64 hazards (`sizeof(long)==8` bugs). Must exit 0. |
| | `scripts/lint-lp64.py [--errors-only]` | Same, directly. |
| Full lint | `nix run .#lint-all` | LP64 + clang-tidy + cppcheck + ruff + yamllint + shellcheck + shfmt + nixfmt. |
| Include shim | `nix run .#include-shim` | Regenerate case-folding include shim after adding #include or headers. |
| | `scripts/generate-include-shim.py` | Same, directly. |
| Toolchain check | `nix run .#toolchain-check` | Verify toolchain + game data integrity. |
| | `scripts/toolchain-check.sh` | Same, directly. |
| Data verify (direct) | `python3 scripts/ra-data-verify.py <dir>` | Verify game data MIX checksums directly. |
| | `scripts/toolchain-check.sh` | Same, directly. |
| Wine check | `wine_check()` | Check Wine + xdotool + ffmpeg + ImageMagick installed. |
| | `scripts/wine-check.sh` | Same, directly. |
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
| Edit loop (native) | `nix run .#edit-loop` | shim → lint → native build → smoke T1. |
| WASM loop | `nix run .#wasm-loop` | WASM build → validate → smoke T1+T2. |
### Utility
| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Extract MIX | `python3 scripts/extract_mix.py` | Westwood MIX file extractor (classic + extended headers). |
| Generate test VQA | `python3 scripts/gen_test_vqa.py` | Generate minimal synthetic 8×8 3-frame VQA for decoder testing. |
| VQA decode verify | `python3 scripts/vqa_decode_verify.py` | Python port of vqa_player.cpp decoding logic for cross-validation. |
| Setup RA remastered | `scripts/setup-run-ra-remastered.sh` | Create RA run dir with symlinks to CD1 assets and binary. |
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
| `build-native` | nix app | Build | Build RA + TD native Linux. |
| `build-stub-thipx` | nix app | Build | Build stub THIPX32.DLL for Wine. |
| `build-td.sh` | script | Build | Configure CMake and build TD. |
| `build-wasm` | nix app | Build | Build RA and/or TD WASM targets. |
| `capture-checkpoint` | nix app | Capture | Unified capture orchestrator. |
| `capture-native` | nix app | Capture | Removed — use `capture-checkpoint --targets native`. |
| `capture-wine` | nix app | Capture | Wine OG baseline capture. |
| `cdlabel-patch.py` | script | Patch (RA) | Zero CD1 label for Wine. |
| `toolchain-check` | nix app | Lint | Toolchain prerequisite check. |
| `ci` | nix app | CI | Run all local CI gates. |
| `ci-build-native` | nix app | CI | Removed — merged into `build-native`. |
| `ci-build-wasm` | nix app | CI | Removed — use `wasm-loop` instead. |
| `ci-cc-setup` | nix app | CI | Removed — inline in `gh-pages.yml`. |
| `ci-clang-tidy` | nix app | CI | Removed — folded into `ci`. |
| `ci-cppcheck` | nix app | CI | Removed — folded into `ci`. |
| `ci-local.sh` | script | CI | Run all local CI gates. |
| `ci-run-test` | nix app | CI | Removed — use `test` instead. |
| `ci-vqa` | nix app | CI | Removed — use `vqa-check` instead. |
| `ci-wasm-smoke` | nix app | CI | Removed — use `wasm-loop` instead. |
| `cinematic-compare.py` | script | Parity | VQA batch comparison against ffmpeg. |
| `parity-compare` | nix app | Parity | SSIM compare two images. |
| `ddscl-patch.py` | script | Patch (RA) | DDSCL_EXCLUSIVE → DDSCL_NORMAL. |
| `edit-loop` | nix app | Loop | shim → lint → build → smoke. |
| `extract_mix.py` | script | Utility | Westwood MIX file extractor. |
| `first-run-pass-94.sh` | script | Test | RA native smoke test. |
| `focus-skip-patch.py` | script | Patch (RA) | NOP GameInFocus spin loops. |
| `game-in-focus-patch.py` | script | Patch (RA) | Pin GameInFocus=TRUE. |
| `gen-vqa-golden.py` | script | Parity | Generate golden VQA frames. |
| `gen-all-vqa-goldens.sh` | script | Parity | Generate golden frames for all intro VQAs. |
| `gen_test_vqa.py` | script | Utility | Generate synthetic test VQA. |
| `generate-include-shim.py` | script | Lint | Regenerate case-folding include shim. |
| `lint-lp64` | nix app | Lint | LP64 hazard audit. |
| `lint-all` | nix app | Lint | Full multi-tool lint suite. |
| `lint-lp64.py` | script | Lint | LP64 static hazard scanner. |
| `nocd-patch.py` | script | Patch (RA) | Skip CD error dialog. |
| `parity-compare.py` | script | Parity | SSIM + fill% + p99 pixel diff. |
| `parity-report.sh` | script | Parity | Three-way parity report shell. |
| `probe-layout.cpp` | script | Lint | C++ struct layout probe. |
| `ra-autostart-patch.py` | script | Patch (RA) | Zero-click auto-boot at Normal difficulty. |
| `ra-data-verify.py` | script | Lint | Verify RA MIX checksums. |
| `ra-scenario-patch.py` | script | Patch (RA) | Replace mission name in EXE. |
| `redalert` | nix app | Run | Run native RA binary. |
| `regression` | nix app | Test | Run regression suite (T1-T12). |
| `regression-suite.sh` | script | Test | Orchestrate E2E regression tests. |
| `release-build-ra` | nix app | Build | Removed — merged into `release`. |
| `release-build-td` | nix app | Build | Removed — merged into `release`. |
| `parity-report` | nix app | Parity | Three-way parity report. |
| `run-td-cheat.sh` | script | Test | TD native smoke with TD_CHEAT=1. |
| `screenshot` | nix app | Test | WASM screenshot capture. |
| `serve` | nix app | Serve | Start both WASM + asset servers. |
| `serve-assets` | nix app | Serve | Removed — use `serve` instead. |
| `serve-wasm` | nix app | Serve | Removed — use `serve` instead. |
| `setup-run-ra-remastered.sh` | script | Utility | Create RA run directory. |
| `setup-run-td.sh` | script | Utility | Create TD run directory. |
| `include-shim` | nix app | Lint | Regenerate include shim. |
| `ci-wasm-smoke.sh` | script | CI | Removed — use `wasm-loop` instead. |
| `build-native.sh` | script | Build | Single-command native build. |
| `run-e2e.sh` | script | Test | Xvfb + WASM server + Playwright test. |
| `serve-wasm.sh` | script | Serve | WASM dev server helper. |
| `toolchain-check.sh` | script | Lint | Toolchain prerequisite check. |
| `vqa-check.sh` | script | Parity | VQA codec CI gate. |
| `wine-check.sh` | script | Lint | Wine toolchain check. |
| `xvfb-ensure.sh` | script | Utility | Idempotent Xvfb launcher. |
| `smoke-ra` | nix app | Test | RA native smoke test. |
| `smoke-td` | nix app | Test | TD native smoke test. |
| `soviet-cdlabel-patch.py` | script | Patch (RA) | Zero CD2 label for Soviet. |
| `soviet-m2-scenario-patch.py` | script | Patch (RA) | Override Soviet M2 scenario. |
| `td-activateapp-patch.py` | script | Patch (TD) | Prevent WM_ACTIVATEAPP clearing focus. |
| `td-cdlabel-patch.py` | script | Patch (TD) | Zero GDI95 label. |
| `td-cinematic-compare.py` | script | Parity | TD VQA batch comparison. |
| `td-ddmode-patch.py` | script | Patch (TD) | Stub SetDisplayMode. |
| `td-focus-skip-patch.py` | script | Patch (TD) | NOP GameInFocus spin loops. |
| `td-game-in-focus-patch.py` | script | Patch (TD) | Pin GameInFocus=1. |
| `td-ioport-patch.py` | script | Patch (TD) | NOP VGA port-I/O polling. |
| `td-scenario-patch.py` | script | Patch (TD) | Replace scenario name in EXE. |
| `td-setcoop-hwnd-patch.py` | script | Patch (TD) | Fix SetCooperativeLevel HWND. |
| `td-side-preview-skip-patch.py` | script | Patch (TD) | NOP side-preview animation. |
| `td-vqa-skip-patch.py` | script | Patch (TD) | Skip TD cutscenes. |
| `test` | nix app | Test | Run e2e test spec. |
| `test-t1` | nix app | Test | Run T1 RA boot smoke test. |
| `test-t2` | nix app | Test | Run T2 TD boot smoke test. |
| `tiberiandawn` | nix app | Run | Run native TD binary. |
| `validate-wasm` | nix app | Build | Validate WASM magic + size. |
| `data-verify` | nix app | Lint | Removed — folded into `toolchain-check`. |
| `vqa-check` | nix app | Parity | VQA pixel-diff gate. |
| `vqa-cinematic` | nix app | Parity | Cinematic/VQA batch comparison. |
| `vqa-golden` | nix app | Parity | Generate golden VQA frames. |
| `vqa_decode_verify.py` | script | Utility | Python VQA decoder. |
| `vqa-pixel-diff.py` | script | Parity | VQA decoder vs ffmpeg comparison. |
| `wasm-loop` | nix app | Loop | WASM build → validate → smoke. |
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
| `cinematic-compare` | `python3 scripts/cinematic-compare.py` |


## Naming Convention Summary
| Surface | Convention | Example |
|---------|-----------|---------|
| Nix apps | `kebab-case` | `build-native`, `parity-compare` |
| Shell scripts | `kebab-case.sh` | `ci-local.sh`, `run-e2e.sh` |
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
