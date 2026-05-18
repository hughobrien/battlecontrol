# Fold `nix run .#include-shim` Into Build Automation

**Date:** 2026-05-18
**Status:** Approved

## Summary

Remove the standalone `nix run .#include-shim` app from `flake.nix`. CMake already
auto-runs `scripts/generate-include-shim.py` as a build dependency (both `ra` and `td`
targets depend on the `redalert_include_shim` custom target), making the nix app
redundant.

## Motivation

- **Dead interface surface:** Every `nix run .#<name>` app is a developer-facing
  affordance. If `include-shim` is never needed by hand (CMake handles it), listing
  it creates unnecessary surface area.
- **CI already covers it:** `ci_local` runs a native build, which triggers the CMake
  target. No separate gate needed.
- **Simpler mental model:** One fewer thing to learn.

## Changes

| File | Change |
|------|--------|
| `flake.nix` | Remove the `include-shim` entry from `apps` |
| `AGENTS.md` | Replace `nix run .#include-shim` references with guidance that CMake auto-runs it, or to use the Python script directly |
| `scripts.md` | Remove/update rows referencing `include-shim` nix app |
| `workflows.md` | Remove/update references to the nix app |
| `skills/` docs | Any reference to `nix run .#include-shim` → direct Python invocation |

## Non-Changes (explicitly out of scope)

- The Python script `scripts/generate-include-shim.py` stays — CMake and build scripts
  still call it.
- No CI gate added (redundant with build).
- No pre-commit hook.
- `build-native.sh` and other build scripts are unchanged (they already trigger it via CMake).

## Verification

After implementation, confirm:
1. `nix run .#include-shim` no longer exists as a target
2. All doc references updated
3. CMake build still works (it invokes the Python script directly — no nix app involvement)
