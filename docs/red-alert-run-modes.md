# Red Alert Run Modes

This is the current map of ways we run Red Alert in this repo.

See also: `docs/red-alert-run-modes.excalidraw`.

## 1. Original RA95 under Wine

Purpose: reference behavior for parity.

Path:

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

Outputs land under `/tmp/battlecontrol/<session>/wine.png` and related logs.

## 2. Native Linux Port

Purpose: primary native development target and parity target.

Build:

```sh
cmake --preset linux-native
cmake --build build --target ra --parallel
```

Run directly:

```sh
RA_AUTOSTART=1 RA_AUTOSTART_SCENARIO=SCG02EA.INI ./build/ra/redalert
```

Capture:

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets native
```

Key pieces:

- `build/ra`
- SDL2 port layer
- `RA_AUTOSTART*`
- `RA_CAPTURE_*`
- `scripts/drivers/native.py`

## 3. WASM Port

Purpose: browser deliverable and parity target.

Build:

```sh
emcmake cmake --preset wasm
cmake --build build-wasm --target ra --parallel
```

Run:

```sh
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

## 4. MinGW Win32 Port under Wine

Purpose: isolate Linux-host differences from ported-engine differences.

Build:

```sh
cmake --preset mingw32
cmake --build build-mingw32 --target ra --parallel
```

Run:

```sh
scripts/run-mingw-ra.sh
```

Key pieces:

- `build-mingw32/ra.exe`
- MinGW cross SDL runtime DLLs
- Wine
- Same ported engine sources as Linux native

Current status: builds and launches, but runtime currently fails during early MIX loading while reading `LOCAL.MIX` metadata. That makes it a useful next debugging target before adding it as a first-class `capture-checkpoint.py` target.

## 5. Parity Orchestrator

Purpose: compare the above targets in one workflow.

```sh
python3 scripts/capture-checkpoint.py mission allied-l2 --targets wine,native,wasm
```

Outputs:

- `wine.png`
- `native.png`
- `wasm.png`
- `diff-wine-vs-native.png`
- `diff-wine-vs-wasm.png`
- `report.json`

Potential next addition:

```text
--targets wine,native,wasm,mingw
```

