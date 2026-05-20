# GCC vs clang drift — 2026-05-19 survey

User noted "we had standardised on clang" but something is using GCC. This is the survey.

## Headline

GCC is used in **three** places — `packages.redalert`, `packages.tiberiandawn`, and `packages.vqa-dump` Nix derivations all build with the default GCC stdenv. Only `devShells.default` and the interactive `scripts/build-native.sh` workflow use clang. **Released binaries (via `nix build .#redalert` etc.) are GCC-compiled.** The most recent dev-shell build at commit `19964fd` did use clang (confirmed via `build/CMakeCache.txt:28` and every entry in `build/compile_commands.json`).

## Evidence

1. **`flake.nix:52`** — `redalert = pkgs.stdenv.mkDerivation { ... }`. No stdenv override → nixpkgs default GCC.
2. **`flake.nix:100`** — `tiberiandawn = pkgs.stdenv.mkDerivation { ... }`. Same.
3. **`flake.nix:212`** — `cnc-ddraw = pkgs.stdenv.mkDerivation { ... }`. Same, but **intentional**: this builds a Win32 DLL via `pkgs.pkgsCross.mingw32.buildPackages.gcc`. Out of scope for the "standardised on clang" policy unless that policy explicitly covers mingw cross.
4. **`flake.nix:247`** — `vqa-dump` `buildPhase` hardcodes `g++ -std=c++17 -O2 ...`. Bypasses any stdenv toolchain choice.
5. **`flake.nix:259`** — `devShells.default` uses `pkgs.mkShell.override { stdenv = pkgs.clangStdenv; }`. ✅ clang here only.
6. **`flake.nix:309-334`** (shellHook) — does NOT export `CXX`. `clangStdenv` sets `CC`/`CXX` automatically, but the hook doesn't pin them for sub-processes that may not inherit cleanly.
7. **`CMakePresets.json:4-11`** — `linux-native` preset has no `CMAKE_CXX_COMPILER` entry. Falls through to `$CXX` at configure time.
8. **`scripts/build-native.sh:22-26`** — only forwards `$CXX` when set; silent fall-through to CMake autodetect (= system `c++`, usually g++) otherwise.
9. **`.github/workflows/release.yml:28`** — release calls `nix build .#redalert` / `.#tiberiandawn` → GCC-compiled binaries shipped.

## Mismatch points (ordered by impact)

1. **Release binaries are GCC.** `packages.redalert` / `packages.tiberiandawn` use `pkgs.stdenv` not `clangStdenv`. If the standardisation is meant to cover release artefacts, this is the biggest gap.
2. **`vqa-dump` hardcodes `g++`.** Even if its stdenv were clang, the buildPhase command would bypass it.
3. **`CMakePresets.json:linux-native` doesn't pin the compiler.** Makes the dev-shell build silently dependent on `$CXX` being set by the shell.
4. **`build-native.sh` silently falls through.** If run outside `nix develop` or if `clangStdenv` failed to set `CXX`, CMake autodetect picks g++ without warning.

## Fix sketch (do NOT implement without user direction)

1. `flake.nix:52,100` — change to `pkgs.clangStdenv.mkDerivation` (or `(pkgs.stdenv.override { stdenv = pkgs.clangStdenv; }).mkDerivation`). Add `-DCMAKE_CXX_COMPILER=clang++` to `cmakeFlags`.
2. `flake.nix:247` — replace literal `g++` with `${pkgs.clang}/bin/clang++` or migrate the derivation to `clangStdenv`.
3. `CMakePresets.json:linux-native` — add `"CMAKE_CXX_COMPILER": "clang++"` to `cacheVariables` so the preset is self-contained.
4. `scripts/build-native.sh:22-26` — once the preset pins the compiler, this conditional can simplify; at minimum hard-fail when `$CXX` is unset rather than silently using system default.

## Open questions for the user

- **Does the clang standardisation cover release artefacts?** Right now only dev-shell builds use clang; `nix build .#redalert` and `nix run .#redalert` use GCC. May be intentional for reproducibility with upstream.
- **`cnc-ddraw` and `wine-input`** use MinGW GCC to cross-compile Win32 code. Should mingw-clang be considered? Possible but unusual.
- **`vqa-dump`** — throw-away tool or maintained artefact? The hardcoded `g++` matters more if anyone depends on the output.

---

## Update — fix shipped at 527b608

Applied fix sketch items 1-4. Verified `nix build .#redalert` succeeds with `clangStdenv`. Confirmed clean dev-shell rebuild via `scripts/build-native.sh` resolves `CMAKE_CXX_COMPILER` to clang++ (via the preset's `cacheVariables`, not via `$CXX`).

## Separate issue surfaced during validation

`nix build .#tiberiandawn` was already broken before this commit (verified by reverting and re-running). The failure:

```
CMake Error at installer/CMakeLists.txt:4 (find_package):
  By not providing "FindSDL2_ttf.cmake" in CMAKE_MODULE_PATH this project has
  asked CMake to find a package configuration file provided by "SDL2_ttf"
```

The TD nix derivation doesn't include `SDL2_ttf` in `buildInputs` or pass `-DSDL2_ttf_DIR=...` to cmake, but the top-level CMakeLists requires SDL2_ttf via `installer/CMakeLists.txt`. RA's derivation has both the buildInput and the cmakeFlag; TD's is missing them.

**Fix sketch (separate from clang standardisation):**
- Add `SDL2_ttf` to `packages.tiberiandawn.buildInputs` (matching RA at `flake.nix:67`).
- Add `-DSDL2_ttf_DIR=${pkgs.SDL2_ttf}/lib/cmake/SDL2_ttf` to the cmake invocation in `tiberiandawn.buildPhase`.

Dev-shell builds (`scripts/build-native.sh td`) work fine because the dev shell has SDL2_ttf on the cmake search path automatically. Only the nix package build path is affected.

*Pre-existing, not introduced by 527b608.*
