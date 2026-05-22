# battlecontrol Project Overview

This document and `docs/red-alert-run-modes.excalidraw` are a compact map of
the project: where the code came from, what the port is trying to preserve, how
we run each target, and how parity work is supposed to converge.

## North Star

`battlecontrol` ports the C&C Remastered Collection Red Alert and Tiberian Dawn
engine sources to Linux and WebAssembly while keeping behavior close to the
original 1990s games.

The primary deliverable is browser-playable RA and TD using legally acquired
local game data. Native Linux is the fast development and debugging target.
Original Windows binaries under Wine are the behavioral reference, not the final
product.

## Source Lineage

Inputs:

- Remastered Collection engine sources for Red Alert and Tiberian Dawn.
- User-supplied original game data such as MIX archives, scenarios, movies, and
  audio.
- Original Windows binaries (`RA95.EXE` and C&C95/TD equivalents) when we need a
  reference capture under Wine.

Porting layer:

- Win32/DOS compatibility shims for types, APIs, filesystem behavior, and input.
- LP64 fixes so Linux `long` and pointer widths do not corrupt 1990s binary data
  structures.
- Case-folding include shims for the original mixed-case source layout.
- Platform replacements for DirectDraw, DirectSound, Windows input, and process
  assumptions.

Outputs:

- Native Linux RA and TD executables.
- WASM/browser RA and TD artifacts for GitHub Pages.
- Wine reference screenshots and logs for parity investigations.
- A developing MinGW Win32 build of the ported engine, intended to run under Wine
  as a third lens between original Windows behavior and native Linux behavior.

## Runtime Modes

### 1. Original RA95 under Wine

Purpose: reference behavior for parity.

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets wine
```

Key pieces:

- Original `RA95.EXE`
- `scripts/ra/patch_ra95.py`
- `scripts/drivers/wine.py`
- `tools/cnc-ddraw`
- `tools/wine-input/*`
- Xvfb/Openbox/Wine

Outputs land under `/tmp/battlecontrol/<session>/wine.png` with driver logs,
diffs, and `report.json`.

### 2. Native Linux Port

Purpose: primary development target and parity target.

```sh
cmake --preset linux-native
cmake --build build --target ra --parallel
RA_AUTOSTART=1 RA_AUTOSTART_SCENARIO=SCG02EA.INI ./build/ra/redalert
```

Capture:

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets native
```

Key pieces:

- `build/ra`
- SDL2 graphics, audio, and input paths
- `RA_AUTOSTART*`
- `RA_CAPTURE_*`
- `scripts/drivers/native.py`

### 3. WASM Browser Port

Purpose: user-facing deliverable and parity target.

```sh
emcmake cmake --preset wasm
cmake --build build-wasm --target ra --parallel
scripts/serve-wasm.sh
```

Capture:

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets wasm
```

Key pieces:

- `build-wasm/ra.html`
- `build-wasm/ra.js`
- `build-wasm/ra.wasm`
- `wasm/preloader.js`
- Playwright capture driver

### 4. MinGW Win32 Port under Wine

Purpose: isolate Linux-host differences from ported-engine differences.

```sh
cmake --preset mingw32
cmake --build build-mingw32 --target ra --parallel
scripts/run-mingw-ra.sh
```

Key pieces:

- `build-mingw32/ra.exe`
- MinGW cross SDL runtime DLLs
- Wine
- The same ported engine sources used by native Linux

Current status: builds, launches, and enters autostarted gameplay under Wine.
It is available as a `capture-checkpoint.py` probe target:

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets mingw --frame 60
```

The first MinGW/Wine blocker was MIX corruption caused by MinGW text-mode file
I/O: reads stopped at `0x1A` inside binary MIX files. The shared POSIX file-I/O
substrate now forces `O_BINARY`, so `LOCAL.MIX` and other encrypted MIX files
decode with the same metadata as native Linux. The target uses the ported
engine's internal `RA_CAPTURE_FRAME` BMP trap when possible; current captures
are frame-exact but low-colour/grayscale under Wine, which is a known follow-up
divergence.

## Verification Loop

The parity loop is:

```sh
python3 scripts/capture-checkpoint.py mission <id> --targets wine,native,wasm
```

The orchestrator produces:

- `wine.png`, `native.png`, and `wasm.png`
- `diff-wine-vs-native.png`
- `diff-wine-vs-wasm.png`
- `diff-native-vs-wasm.png`
- `report.json`
- per-target driver logs

Important debugging controls:

- fixed gameplay seed
- target frame capture traps
- FPS limiting
- system time control where useful
- cnc-ddraw reference capture
- framebuffer and process-memory probing
- scenario sampling across Allied, Soviet, GDI, and Nod campaigns

The goal is not just "looks close"; the loop should expose exact, reproducible
divergences that can be traced back to real source differences or intentionally
documented environmental differences.

## Capture Stack Details

The Wine reference path was the hardest part to make trustworthy because the
original game is a closed Windows binary running in a headless Linux test
environment.

The final stack is:

- `patch_ra95.py` prepares `RA95.EXE` for headless mission launch, scenario
  selection, fixed seed, and briefing/VQA skipping.
- Xvfb provides the virtual X11 display.
- Openbox gives Wine a normal window-management environment.
- Wine runs the original binary.
- cnc-ddraw replaces the game's DirectDraw path with a controllable software
  rendering path, FPS limiting, and a stable CPU-visible frame.
- `tools/wine-input/*` provides Win32-side SendInput and BitBlt helpers when
  ordinary X11 input or screenshots do not reach the same path as the game.
- `scripts/drivers/wine.py` probes process state so the harness can tell
  gameplay from menus, score screens, error dialogs, and black loading frames.

The native and WASM paths mirror the same intent with source-level controls:
`RA_AUTOSTART*` selects the scenario, `RA_CAPTURE_*` traps frames, and Playwright
or Xvfb captures the presented surface.

## Issue Classes We Hit

Useful failures from the parity effort:

- Missing UI text and counters: mission instructions, timer, and credits were
  absent until the port restored the Win95 high-resolution tab/text paths.
- Coordinate-space mistakes: clipped terrain/template drawing treated source
  coordinates and destination-window coordinates differently, creating apparent
  one-cell or one-stamp terrain shifts.
- Palette and blend fidelity: a portable shroud fade-table replacement did not
  preserve the original x86 signed 8-bit math and tie behavior, reducing fog
  grades and changing revealed-edge blending.
- Dirty-rectangle order: sidebar parent redraws could overwrite child strips or
  powerbar edges, producing vertical and horizontal line artifacts.
- Asset/decode parity: native-only saturated purple/green pixels exposed a shape
  delta decoding bug and an overlay visibility difference.
- Time and determinism: Wine and native can present captures at slightly
  different simulation boundaries; fixed seeds help, but object animation, ore
  phase, palette cycling, and capture-frame semantics still need explicit probes.
- Harness misroutes: invalid Soviet captures often landed in main menu,
  top-scores, score, black loading, or low-disk dialog states rather than
  gameplay, so state classification became part of the root of trust.

These issue classes are why the workflow now favors paired screenshots, region
diffs, process/frame probes, and source-level instrumentation over visual
inspection alone.

## Why Nix Helped

Nix turned out to be part of the debugging infrastructure, not just a packaging
choice.

It helped by making the strange toolchain mix reproducible:

- native CMake builds for Linux
- Emscripten builds for WASM
- MinGW cross-builds for Win32-under-Wine experiments
- Wine, Xvfb, Openbox, cnc-ddraw, Python, Playwright, image tools, and linters
- fixed flake inputs for vendored or patched dependencies such as cnc-ddraw

That mattered because parity debugging is sensitive to environment drift. If a
capture changes, we need to know whether the cause is source, data, frame timing,
Wine behavior, a rendering shim, or the host environment. The Nix shell made it
possible to hand the same command set to agents and CI, add missing tools in one
place, pin local patches, and keep the capture loop reproducible enough to trust.

## Project History

Milestone shape:

- v0.1: toolchain bootstrap, Win32 shim, LP64 audit, portable graphics/audio
  replacements, first visible menu/game frame, ASAN-clean smoke tests.
- v0.2: RA and TD playable in browser/WASM with Emscripten, pthreads, SDL2,
  VQA/audio fixes, and Playwright smoke tests.
- v0.3: Wine original-game parity gates for representative RA and TD missions,
  release artifacts, and CI validation.
- v0.3+: mission parity expansion, deterministic capture tooling, divergence
  cleanup, and MinGW-under-Wine investigation.
- v0.4 target: broader TD parity, M2+ mission coverage, save/load through
  browser storage, and harder e2e reliability.
- v0.5+ target: native performance, accelerated rendering, full-campaign parity,
  multiplayer, mod support, map/editor work, and more platforms.

## Current Frontiers

The active engineering fronts are:

- Keep reducing visual divergences in `divergences.md` with reproducible
  screenshot pairs.
- Promote capture tooling from ad hoc debugging into a root of trust.
- Extend MinGW-under-Wine from a gameplay probe into a frame-exact comparison
  target.
- Expand parity from hand-reviewed scenes to broad campaign sampling.
- Harden browser save/load and long-session behavior.
