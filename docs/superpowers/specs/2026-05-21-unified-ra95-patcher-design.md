# Unified RA95 Patcher

## Goal

Replace the scattered RA95 binary patch scripts with one auditable Python utility:

```bash
python3 scripts/ra/patch_ra95.py <mode> RA95.EXE [options]
```

The utility is RA95-only. It will make the Wine capture patch chain easier to
reason about, harder to misuse, and easier to test. It must also preserve the
current ability to patch RA95.EXE for headless Wine mission capture.

## Problems To Solve

RA95 patching is currently split across:

- `flake.nix`, which applies the base NoCD, DirectDraw, and CD-label patches.
- `scripts/drivers/wine.py`, which chooses mission patch scripts by filename.
- Many standalone `scripts/ra/ra-*-patch.py` files with inconsistent metadata.

This made it too easy for a bad patch to look legitimate. The clearest example
is `ra-game-in-focus-patch.py`: it claimed to force `GameInFocus`, but it wrote
to an address now known to behave as `Session.Type`, causing Soviet mission
captures to enter the multiplayer frameinfo path.

## Design

Create `scripts/ra/patch_ra95.py` as the single supported RA95 patch entry point.
All patches live in a declarative registry inside that utility or a sibling
module such as `scripts/ra/ra95_patches.py`.

Each patch entry records:

- Stable id, for example `nocd`, `ddscl-normal`, `vqa-skip`.
- One-line purpose.
- Audit status: `trusted`, `capture-only`, `diagnostic`, or `quarantined`.
- Exact edits: file offset, optional virtual address, expected bytes,
  replacement bytes, and a short label.
- Ordering requirements, where needed.
- Whether reapplication is idempotent.
- Whether the patch may be selected by a default mode.

The utility must validate expected bytes before writing. If bytes already match
the replacement, it records the edit as idempotently skipped. If neither expected
nor replacement bytes match, it fails with the file offset, expected bytes, actual
bytes, patch id, and current executable SHA-256.

## CLI Modes

The CLI has smart defaults so common invocations are short.

### Base Mode

Used by the Nix `ra-patched-exe` derivation:

```bash
python3 scripts/ra/patch_ra95.py base RA95.EXE
```

Applies:

- `nocd`
- `ddscl-normal`
- default CD-label normalization

This replaces the direct calls to `ra-nocd-patch.py`, `ra-ddscl-patch.py`, and
the raw `dd` byte poke in `flake.nix`.

### Mission Mode

Used by the Wine capture driver:

```bash
python3 scripts/ra/patch_ra95.py mission RA95.EXE --scenario SCU01EA.INI
```

Defaults:

- Infer side from scenario prefix: `SCG` means Allied/CD1, `SCU` means Soviet/CD2.
- Apply mission capture patches.
- Apply scenario replacement.
- Apply autostart at Normal difficulty.
- Apply fixed RNG seed using the current default capture seed, unless disabled
  with `--no-seed` or overridden with `--seed`.
- Write a manifest when `--manifest PATH` is passed.

The Wine driver calls this once instead of assembling patch script names.

### Advanced Controls

Supported but not needed for the normal path:

```bash
python3 scripts/ra/patch_ra95.py mission RA95.EXE \
  --scenario SCG02EA.INI \
  --side allied \
  --seed 0x1eed5eed \
  --no-vqa-skip \
  --no-briefing-skip \
  --manifest wine-patches.json
```

Diagnostics require an explicit flag:

```bash
python3 scripts/ra/patch_ra95.py mission RA95.EXE \
  --scenario SCU01EA.INI \
  --diagnostic frameinfo-send-guard \
  --allow-diagnostic
```

Quarantined patches require a stronger explicit flag:

```bash
python3 scripts/ra/patch_ra95.py apply RA95.EXE \
  --patch game-in-focus \
  --allow-quarantined
```

Normal modes must never apply diagnostic or quarantined patches implicitly.

## Patch Status Policy

Initial statuses:

| Patch id | Status | Notes |
| --- | --- | --- |
| `nocd` | `trusted` | Bypasses physical CD-ROM drive check. |
| `ddscl-normal` | `trusted` | Uses normal/windowed DirectDraw cooperative level. |
| `cd-label` | `capture-only` | Selects the effective Allied/Soviet disc label. |
| `focus-wait-skip` | `capture-only` | Useful today, but needs disassembly/source confirmation. |
| `vqa-skip` | `capture-only` | Global `Play_Movie` return for gameplay capture. |
| `briefing-skip` | `capture-only` | Skips text briefing dialog. |
| `scenario` | `capture-only` | Replaces hardcoded scenario strings. |
| `autostart` | `capture-only` | Enters selected mission directly at Normal difficulty. |
| `random-seed` | `capture-only` | Makes parity screenshots deterministic. |
| `force-normal-queue` | `diagnostic` | Proves queue-mode hypotheses; not a fix. |
| `frameinfo-send-guard` | `diagnostic` | Masks multiplayer frameinfo crashes; not a fix. |
| `game-in-focus` | `quarantined` | Confirmed bad address assumption. |

## Manifest

When requested, the utility writes JSON with:

- Tool version or git commit if available.
- Full CLI args.
- Input SHA-256.
- Output SHA-256.
- Scenario, inferred side, difficulty, seed, and mode.
- Every selected patch id and status.
- For each edit: offset, optional VA, expected bytes, replacement bytes, actual
  preimage, result (`applied`, `already-applied`, `rejected`), and label.
- Exact contiguous changed byte ranges.

The Wine driver continues copying or linking this manifest into the
capture session directory.

## Migration

1. Add `patch_ra95.py` and the patch registry without changing callers.
2. Add unit tests that compare the new base patch output to the existing
   `ra-patched-exe` output.
3. Add mission-mode tests for Allied and Soviet scenarios, including diagnostic
   and quarantine rejection tests.
4. Switch `flake.nix` base patching to `patch_ra95.py base`.
5. Switch `scripts/drivers/wine.py` to `patch_ra95.py mission`.
6. Replace old `ra-*-patch.py` scripts with deprecated shims or remove them once
   no callers remain.
7. Update docs that currently describe `ra-game-in-focus-patch.py` as valid.

## Testing

Required verification:

- `python3 -m py_compile scripts/ra/patch_ra95.py`
- Unit tests for expected-byte validation, idempotency, diagnostics rejection,
  quarantine rejection, scenario side inference, and manifest content.
- Existing Wine patch-chain tests migrated from script-name assertions to
  utility mode assertions.
- A build of `.#ra-patched-exe`.
- One Wine mission capture for Allied and one for Soviet after driver migration.

## Non-Goals

- Do not migrate TD patches in this change.
- Do not make the utility a general binary patch framework.
- Do not preserve the bad `game-in-focus` patch as an easy-to-run option.
- Do not change native RA behavior.
