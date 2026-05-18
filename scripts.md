# Scripts & Commands Reference

Comprehensive catalog of all commands across the three invocation surfaces:
- **Extension tools** (`.pi/extensions/battlecontrol.ts`) — used by AI agent
- **Nix apps** (`nix run .#<name>`) — primary CLI interface
- **Scripts** (`scripts/`, `wasm/`) — implementation layer

## Cross-Reference Matrix

| Action | Extension Tool | Nix App | Script(s) | CI Job | npm Script |
|--------|---------------|---------|-----------|--------|------------|
| Build native | `native_build` | `build-native` | `scripts/skill-native-build.sh` | `ci.yml → build` | — |
| Build WASM | `wasm_build` | `build-wasm` | inline (flake.nix) | `ci.yml → build-wasm` | — |
| Validate WASM | `wasm_validate` | `validate-wasm` | inline (flake.nix) | `ci.yml → build-wasm` | — |
| Serve WASM | `serve_wasm` | `serve-wasm` | `wasm/serve-coop.py` | — | — |
| Serve assets | `serve_assets` | `serve-assets` | `wasm/serve-assets.py` | — | — |
| Serve both | — | `serve` | inline (flake.nix) | — | — |
| WASM screenshot | `wasm_screenshot` | `screenshot` | inline (flake.nix) | — | — |
| Run e2e test | `run_e2e_test` | `test` | `scripts/skill-run-e2e.sh` | — | `test:e2e` |
| Run T1 (RA boot) | — | `test-t1` | `scripts/skill-run-e2e.sh` | `ci.yml → build-wasm` | — |
| Run T2 (TD boot) | — | `test-t2` | `scripts/skill-run-e2e.sh` | `ci.yml → build-wasm` | — |
| CI gate (local) | `ci_local` | `ci` | `scripts/ci-local.sh` | — | — |
| CI native build | — | `ci-build-native` | inline (flake.nix) | `ci.yml → build` | — |
| CI WASM build+smoke | — | `ci-build-wasm` | inline (flake.nix) | `ci.yml → build-wasm` | — |
| CI WASM smoke | — | `ci-wasm-smoke` | inline (flake.nix) | called by ci-build-wasm | — |
| CI run test | — | `ci-run-test` | inline (flake.nix) | `ci.yml → build-wasm` (T3/T6/T7/T8/T9) | — |
| CI VQA pixel-diff | — | `ci-vqa` | inline (flake.nix) | `ci.yml → vqa-pixel-diff` | — |
| CI ccache setup | — | `ci-cc-setup` | inline (flake.nix) | `gh-pages.yml` | — |
| CI clang-tidy | — | `ci-clang-tidy` | inline (flake.nix) | `ci.yml → clang-tidy` | — |
| CI cppcheck | — | `ci-cppcheck` | inline (flake.nix) | `ci.yml → cppcheck` | — |
| Toolchain check | `toolchain_check` | `toolchain-check` | `scripts/skill-dev-check.sh` | — | — |
| Wine check | `wine_check` | — | `scripts/skill-wine-check.sh` | — | — |
| Wine capture | `wine_capture` | `capture-wine` | `scripts/wine-cnc-capture.sh` | `ci.yml → wine-comparison` | — |
| Native capture | `native_capture` ⚠️ | `capture-native` | `scripts/capture-checkpoint.py` | — | — |
| Capture orchestrator | — | `capture-checkpoint` | `scripts/capture-checkpoint.py` | — | — |
| Parity compare | `parity_compare` | `parity-compare` | `scripts/parity-compare.py` | — | — |
| Parity report | `parity_report` | `parity-report` | `scripts/parity-report.sh` | — | — |
| VQA pixel diff | `vqa_pixel_diff` | `vqa-check` | `scripts/vqa-pixel-diff.py` | — | — |
| VQA golden frames | `gen_vqa_golden` | `vqa-golden` | `scripts/gen-vqa-golden.py` | — | — |
| VQA cinematic compare | — | `vqa-cinematic` | `scripts/cinematic-compare.py` | — | `cinematic-compare` |
| LP64 lint | `lint_lp64` | `lint-lp64` | `scripts/lint-lp64.py` | — | — |
| Full lint suite | — | `lint-all` | inline (flake.nix) | — | — |
| Include shim | `generate_include_shim` | `include-shim` | `scripts/generate-include-shim.py` | — | — |
| Data verify | `data_verify` | `data-verify` | `scripts/ra-data-verify.py` | — | — |
| Edit loop (native) | `edit_loop` | `edit-loop` | inline (flake.nix) | — | — |
| WASM loop | — | `wasm-loop` | inline (flake.nix) | — | — |
| Release build RA | — | `release-build-ra` | `scripts/first-run-pass-94.sh` + strip + tar | `release.yml` | — |
| Release build TD | — | `release-build-td` | cmake + build + tar | `release.yml` | — |
| Build stub THIPX | — | `build-stub-thipx` | `scripts/build-stub-thipx.sh` | — | — |
| Regression suite | — | `regression` | `scripts/regression-suite.sh` | — | — |
| Smoke test (RA) | — | `smoke-ra` | `scripts/first-run-pass-94.sh` | — | — |
| Smoke test (TD) | — | `smoke-td` | `scripts/run-td-cheat.sh` | — | — |
| Run RA | — | `redalert` | (cmake target) | — | — |
| Run TD | — | `tiberiandawn` | (cmake target) | — | — |
| E2E RA gameplay | — | — | — | — | `test:e2e:ra` |
| E2E TD gameplay | — | — | — | — | `test:e2e:td` |
| E2E WASM parity | — | — | — | — | `test:e2e:wasm-parity` |
| E2E TD compare | — | — | — | — | `test:e2e:td-compare` |
| E2E TIM-705 eq. | — | — | — | — | `test:e2e:tim705` |

⚠️ `native_capture` tool calls `scripts/native-capture.sh` which has been archived. Should call `nix run .#capture-native` instead.

## By Category

### Build

| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Native build | `nix run .#build-native [ra\|td\|both] [clang]` | Configure + build RA and/or TD native Linux with cmake + ninja. Calls `scripts/skill-native-build.sh`. |
| | `native_build(target, compiler, clean)` | Same, via extension tool. |
| | `scripts/ci-local.sh` | Also runs native build as G1. |
| WASM build | `nix run .#build-wasm [ra\|td\|both]` | Build ra.wasm and/or td.wasm via emcmake + cmake + ninja. |
| | `wasm_build(target, clean)` | Same, via extension tool. |
| THIPX stub | `nix run .#build-stub-thipx` | Build stub THIPX32.DLL for Wine 11 wow64 compat. |
| | `scripts/build-stub-thipx.sh` | Same, directly. |
| RA release | `nix run .#release-build-ra` | Build + strip + tarball RA for release (`redalert-linux-x86_64.tar.gz`). |
| TD release | `nix run .#release-build-td` | Build + strip + tarball TD for release (`td-linux-x86_64.tar.gz`). |

### Test / QA

| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Run e2e test | `nix run .#test -- <spec> [args]` | Run any Playwright e2e spec under Xvfb + WASM server. |
| | `run_e2e_test(spec, args)` | Same, via extension tool. |
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
| | `ci_local(mode)` | Same, via extension tool. |
| | `scripts/ci-local.sh [--wasm-only\|--native-only]` | Same, directly. |
| CI native build | `nix run .#ci-build-native` | Native build + ELF 64-bit validation (for CI). |
| CI WASM build | `nix run .#ci-build-wasm` | WASM build + validate + smoke T1+T2 (for CI). |
| CI WASM smoke | `nix run .#ci-wasm-smoke` | Xvfb + serve-coop + T1+T2 Playwright tests. |
| CI run test | `nix run .#ci-run-test -- <spec>` | Run one Playwright spec under Xvfb + WASM (for asset-gated tests). |
| CI VQA | `nix run .#ci-vqa` | Generate test VQA + pixel-diff (for CI). |
| CI ccache setup | `nix run .#ci-cc-setup` | `ccache --zero-stats --max-size 500M`. |
| CI clang-tidy | `nix run .#ci-clang-tidy` | Run clang-tidy static analysis. |
| CI cppcheck | `nix run .#ci-cppcheck` | Run cppcheck static analysis. |

### Capture / Screenshot

| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Wine capture | `nix run .#capture-wine -- <exe> <data> <out>` | Generic RA95.EXE capture via cnc-ddraw under Wine + Xvfb. |
| | `wine_capture(game, dataDir, exePath)` | Same, via extension tool. Calls `scripts/wine-ra.sh` or `scripts/wine-td.sh`. |
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
| Native capture | `nix run .#capture-native -- <mission>` | Launch native RA under Xvfb + `RA_AUTOSTART`, capture gameplay. ⚠️ Uses `scripts/capture-checkpoint.py` |
| | `native_capture(mission)` | ⚠️ **STALE** — calls archived `scripts/native-capture.sh`. Should use `capture-checkpoint.py`. |
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
| | `parity_compare(imageA, imageB, label, thresholdSsim, diffOut)` | Same, via extension tool. |
| | `scripts/parity-compare.py` | Same, directly. |
| Parity report | `nix run .#parity-report -- --mode <vqa\|gameplay> --targets <t> <scene>` | Three-way parity report: compare golden frames against wine/native/wasm captures. |
| | `parity_report(scene, mode, targets)` | Same, via extension tool. |
| | `scripts/parity-report.sh` | Same, directly. |
| VQA pixel diff | `nix run .#vqa-check [--threshold N]` | Compare our VQA decoder vs ffmpeg golden frames via p99 pixel-delta. |
| | `vqa_pixel_diff(mode, mixPath, threshold)` | Same, via extension tool. |
| | `scripts/vqa-pixel-diff.py` | Same, directly. |
| VQA golden | `nix run .#vqa-golden -- <vqaFile> <numFrames> [outDir]` | Decode VQA into N evenly-spaced golden PNGs for reference. |
| | `gen_vqa_golden(vqaPath, numFrames, outDir)` | Same, via extension tool. |
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
| | `lint_lp64(errorsOnly)` | Same, via extension tool. |
| | `scripts/lint-lp64.py [--errors-only]` | Same, directly. |
| Full lint | `nix run .#lint-all` | LP64 + clang-tidy + cppcheck + ruff + yamllint + shellcheck + shfmt + nixfmt. |
| Include shim | `nix run .#include-shim` | Regenerate case-folding include shim after adding #include or headers. |
| | `generate_include_shim()` | Same, via extension tool. |
| | `scripts/generate-include-shim.py` | Same, directly. |
| Data verify | `nix run .#data-verify -- [dir]` | Verify game data MIX files against SHA-256 checksums. |
| | `data_verify(dir)` | Same, via extension tool. |
| | `scripts/ra-data-verify.py [dir]` | Same, directly. |
| Toolchain check | `nix run .#toolchain-check` | Verify native build toolchain (clang++, cmake, ninja, SDL2, etc.). |
| | `toolchain_check()` | Same, via extension tool. |
| | `scripts/skill-dev-check.sh` | Same, directly. |
| Wine check | `wine_check()` | Check Wine + xdotool + ffmpeg + ImageMagick installed. |
| | `scripts/skill-wine-check.sh` | Same, directly. |
| Layout probe | `scripts/probe-layout.cpp` | C++ layout probe: prints sizeof/offsetof for LP64 struct audit. |

### Serve / Dev Server

| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Serve WASM | `nix run .#serve-wasm [port]` | Start HTTP server with COOP/COEP headers for SharedArrayBuffer. |
| | `serve_wasm(port, killExisting)` | Same, via extension tool. |
| | `python3 wasm/serve-coop.py <port> <build-dir>` | Same, directly. |
| Serve assets | `nix run .#serve-assets [port]` | Start HTTP server with CORS for game data MIX files. |
| | `serve_assets(game, dir, port, killExisting)` | Same, via extension tool. |
| | `python3 wasm/serve-assets.py <assetDir> <port>` | Same, directly. |
| Serve both | `nix run .#serve` | Start both servers in background. |

### Iteration Loops

| Command | Invocation | What It Does |
|---------|-----------|-------------|
| Edit loop (native) | `nix run .#edit-loop` | shim → lint → native build → smoke T1. |
| | `edit_loop(target)` | Same, via extension tool. |
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
| `capture-native` | nix app | Capture | Native Linux gameplay capture. |
| `capture-wine` | nix app | Capture | Wine OG baseline capture. |
| `cdlabel-patch.py` | script | Patch (RA) | Zero CD1 label for Wine. |
| `toolchain-check` | nix app | Lint | Toolchain prerequisite check. |
| `ci` | nix app | CI | Run all local CI gates. |
| `ci-build-native` | nix app | CI | CI native build + ELF validation. |
| `ci-build-wasm` | nix app | CI | CI WASM build + validate + smoke. |
| `ci-cc-setup` | nix app | CI | Configure ccache for CI. |
| `ci-clang-tidy` | nix app | CI | CI clang-tidy static analysis. |
| `ci-cppcheck` | nix app | CI | CI cppcheck static analysis. |
| `ci_local` | extension tool | CI | Run all local CI gates. |
| `ci-local.sh` | script | CI | Run all local CI gates. |
| `ci-run-test` | nix app | CI | Run e2e test under Xvfb+WASM (for CI). |
| `ci-vqa` | nix app | CI | CI VQA pixel-diff gate. |
| `ci-wasm-smoke` | nix app | CI | CI WASM smoke tests T1+T2. |
| `cinematic-compare.py` | script | Parity | VQA batch comparison against ffmpeg. |
| `parity-compare` | nix app | Parity | SSIM compare two images. |
| `data_verify` | extension tool | Lint | Verify game data checksums. |
| `ddscl-patch.py` | script | Patch (RA) | DDSCL_EXCLUSIVE → DDSCL_NORMAL. |
| `edit-loop` | nix app | Loop | shim → lint → build → smoke. |
| `edit_loop` | extension tool | Loop | shim → lint → build → smoke. |
| `extract_mix.py` | script | Utility | Westwood MIX file extractor. |
| `first-run-pass-94.sh` | script | Test | RA native smoke test. |
| `focus-skip-patch.py` | script | Patch (RA) | NOP GameInFocus spin loops. |
| `game-in-focus-patch.py` | script | Patch (RA) | Pin GameInFocus=TRUE. |
| `gen_vqa_golden` | extension tool | Parity | Generate golden VQA frames. |
| `gen-vqa-golden.py` | script | Parity | Generate golden VQA frames. |
| `gen-all-vqa-goldens.sh` | script | Parity | Generate golden frames for all intro VQAs. |
| `gen_test_vqa.py` | script | Utility | Generate synthetic test VQA. |
| `generate-include-shim.py` | script | Lint | Regenerate case-folding include shim. |
| `generate_include_shim` | extension tool | Lint | Regenerate include shim. |
| `lint-lp64` | nix app | Lint | LP64 hazard audit. |
| `lint-all` | nix app | Lint | Full multi-tool lint suite. |
| `lint_lp64` | extension tool | Lint | LP64 hazard audit. |
| `lint-lp64.py` | script | Lint | LP64 static hazard scanner. |
| `native_build` | extension tool | Build | Build RA + TD native Linux. |
| `native_capture` | extension tool | Capture | ⚠️ STALE — points to archived script. |
| `nocd-patch.py` | script | Patch (RA) | Skip CD error dialog. |
| `parity_compare` | extension tool | Parity | SSIM compare two images. |
| `parity-compare.py` | script | Parity | SSIM + fill% + p99 pixel diff. |
| `parity_report` | extension tool | Parity | Three-way parity report. |
| `parity-report.sh` | script | Parity | Three-way parity report shell. |
| `probe-layout.cpp` | script | Lint | C++ struct layout probe. |
| `ra-autostart-patch.py` | script | Patch (RA) | Zero-click auto-boot at Normal difficulty. |
| `ra-data-verify.py` | script | Lint | Verify RA MIX checksums. |
| `ra-scenario-patch.py` | script | Patch (RA) | Replace mission name in EXE. |
| `redalert` | nix app | Run | Run native RA binary. |
| `regression` | nix app | Test | Run regression suite (T1-T12). |
| `regression-suite.sh` | script | Test | Orchestrate E2E regression tests. |
| `release-build-ra` | nix app | Build | Build + package RA release tarball. |
| `release-build-td` | nix app | Build | Build + package TD release tarball. |
| `parity-report` | nix app | Parity | Three-way parity report. |
| `run-td-cheat.sh` | script | Test | TD native smoke with TD_CHEAT=1. |
| `run_e2e_test` | extension tool | Test | Run Playwright e2e test. |
| `screenshot` | nix app | Test | WASM screenshot capture. |
| `serve` | nix app | Serve | Start both WASM + asset servers. |
| `serve_assets` | extension tool | Serve | Start game asset server. |
| `serve_wasm` | extension tool | Serve | Start WASM dev server. |
| `serve-assets` | nix app | Serve | Start game asset server. |
| `serve-wasm` | nix app | Serve | Start WASM dev server. |
| `setup-run-ra-remastered.sh` | script | Utility | Create RA run directory. |
| `setup-run-td.sh` | script | Utility | Create TD run directory. |
| `include-shim` | nix app | Lint | Regenerate include shim. |
| `skill-ci-wasm-smoke.sh` | script | CI | Full local WASM CI smoke. |
| `skill-dev-check.sh` | script | Lint | Toolchain prerequisite check. |
| `skill-native-build.sh` | script | Build | Single-command native build. |
| `skill-run-e2e.sh` | script | Test | Xvfb + WASM server + Playwright test. |
| `skill-vqa-check.sh` | script | Parity | VQA codec CI gate. |
| `skill-wasm-serve.sh` | script | Serve | WASM dev server helper. |
| `skill-wine-check.sh` | script | Lint | Wine toolchain check. |
| `skill-xvfb-ensure.sh` | script | Utility | Idempotent Xvfb launcher. |
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
| `toolchain_check` | extension tool | Lint | Toolchain prerequisite check. |
| `validate-wasm` | nix app | Build | Validate WASM magic + size. |
| `data-verify` | nix app | Lint | Verify game data checksums. |
| `vqa-check` | nix app | Parity | VQA pixel-diff gate. |
| `vqa-cinematic` | nix app | Parity | Cinematic/VQA batch comparison. |
| `vqa-golden` | nix app | Parity | Generate golden VQA frames. |
| `vqa_decode_verify.py` | script | Utility | Python VQA decoder. |
| `vqa-pixel-diff.py` | script | Parity | VQA decoder vs ffmpeg comparison. |
| `vqa_pixel_diff` | extension tool | Parity | VQA pixel-diff gate. |
| `wasm-loop` | nix app | Loop | WASM build → validate → smoke. |
| `wasm_build` | extension tool | Build | Build WASM targets. |
| `wasm_screenshot` | extension tool | Test | WASM screenshot capture. |
| `wasm_validate` | extension tool | Build | Validate WASM binaries. |
| `wine_check` | extension tool | Lint | Wine toolchain check. |
| `wine_capture` | extension tool | Capture | Wine OG baseline capture. |
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

## Redundancy Map

Actions that have multiple invocation paths (candidates for consolidation):

| Action | Duplicate Paths | Recommendation |
|--------|----------------|---------------|
| Native build | `native_build` (tool) ↔ `build-native` (nix) ↔ `skill-native-build.sh` (script) | Pick one canonical Nix app name. Make tool and script call it. |
| WASM build | `wasm_build` (tool) ↔ `build-wasm` (nix) | Same — nix is primary. |
| CI gate | `ci_local` (tool) ↔ `ci` (nix) ↔ `ci-local.sh` (script) | Keep `ci` as canonical. |
| Edit loop | `edit_loop` (tool) ↔ `edit-loop` (nix) | Minor — both inline. |
| E2E test | `run_e2e_test` (tool) ↔ `test` (nix) ↔ `skill-run-e2e.sh` (script) | Keep `test` as canonical. |
| Parity compare | `parity_compare` (tool) ↔ `parity-compare` (nix) ↔ `parity-compare.py` (script) | ✅ Canonical |
| Parity report | `parity_report` (tool) ↔ `parity-report` (nix) ↔ `parity-report.sh` (script) | ✅ Canonical |
| VQA pixel diff | `vqa_pixel_diff` (tool) ↔ `vqa-check` (nix) ↔ `vqa-pixel-diff.py` (script) | Keep `vqa-check` as canonical. |
| LP64 lint | `lint_lp64` (tool) ↔ `lint-lp64` (nix) ↔ `lint-lp64.py` (script) | ✅ Canonical |
| Gen VQA golden | `gen_vqa_golden` (tool) ↔ `vqa-golden` (nix) ↔ `gen-vqa-golden.py` (script) | Keep `vqa-golden` as canonical. |
| Include shim | `include_shim` (tool) ↔ `include-shim` (nix) ↔ `generate-include-shim.py` (script) | ✅ Canonical |
| Data verify | `data_verify` (tool) ↔ `data-verify` (nix) ↔ `ra-data-verify.py` (script) | ✅ Canonical |
| Toolchain check | `toolchain_check` (tool) ↔ `toolchain-check` (nix) ↔ `skill-dev-check.sh` (script) | ✅ Canonical |
| Wine capture | `wine_capture` (tool) ↔ `capture-wine` (nix) | Keep `capture-wine` as canonical. |
| Native capture | `native_capture` (tool) ⚠️ | **STALE** — tool calls archived script. Fix to use `capture-native` / `capture-checkpoint.py`. |

### CI-specific duplicates (same implementation, CI-only wrappers)

| CI-specific Nix App | General Equivalent | Recommendation |
|--------------------|-------------------|----------------|
| `ci-build-native` | `build-native` | Remove. CI calls `build-native` directly. |
| `ci-build-wasm` | `build-wasm` | Remove. CI calls `build-wasm` directly. |
| `ci-vqa` | `vqa-check` | Remove. CI calls `vqa-check` directly. |
| `ci-wasm-smoke` | — | Keep (composite of build-wasm + validate-wasm + test-t1 + test-t2). |
| `ci-run-test` | `test` | Remove. CI calls `test` directly. |
| `ci-cc-setup` | — | Keep (ccache config is CI-specific). |
| `ci-clang-tidy` | — | Keep (CI-specific static analysis). |
| `ci-cppcheck` | — | Keep (CI-specific static analysis). |

## Naming Convention Summary

| Surface | Convention | Example |
|---------|-----------|---------|
| Extension tools | `snake_case` | `native_build`, `parity_compare` |
| Nix apps | `kebab-case` | `build-native`, `parity-compare` |
| Shell scripts | `kebab-case.sh` | `ci-local.sh`, `skill-run-e2e.sh` |
| Python scripts | `kebab-case.py` | `lint-lp64.py`, `parity-compare.py` |
| npm scripts | `:` delimited | `test:e2e:ra`, `test:e2e:td` |

## Call Graph

```
Extension Tool ──→ Script (direct)
                ↳ Nix App ──→ Script
CI Workflow ──→ Nix App ──→ Script
             ↳ npx playwright test
```

The project has three independent call paths that converge at the script layer:
1. **Extension tool → script**: Tools call scripts directly (e.g., `wine_capture` → `scripts/wine-ra.sh`)
2. **Extension tool → nix → script**: Some tools call `nix run .#<name>` internally
3. **CI → nix → script**: CI workflows call `nix run .#<ci-*>` which call scripts

All paths lead to the same scripts — the redundancy is in the naming and dispatch, not in the implementation.
