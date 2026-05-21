# Unified RA95 Patcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace scattered RA95 binary patch scripts with one auditable RA95 patching utility and migrate the flake and Wine capture driver to it.

**Architecture:** Put patch metadata and byte-application logic in `scripts/ra/ra95_patches.py`, and keep `scripts/ra/patch_ra95.py` as a thin CLI. The registry owns patch status, exact byte edits, mode defaults, scenario side inference, idempotency, and manifest data. Existing callers move from script chains to one mode-based command.

**Tech Stack:** Python 3 standard library, `unittest`, Nix flake derivation, existing Wine capture driver.

---

## File Structure

- Create `scripts/ra/ra95_patches.py`: patch dataclasses, registry, mode selection, byte editing, manifests.
- Create `scripts/ra/patch_ra95.py`: CLI wrapper around `ra95_patches`.
- Create `scripts/test_ra95_patcher.py`: unit tests for registry policy, byte validation, mode defaults, manifests.
- Modify `scripts/test_wine_patch_chain.py`: assert the Wine driver invokes the unified patcher behavior rather than standalone scripts.
- Modify `scripts/drivers/wine.py`: replace `mission_patch_scripts()` script-chain execution with one `patch_ra95.py mission` invocation.
- Modify `flake.nix`: replace direct `ra-nocd-patch.py`, `ra-ddscl-patch.py`, and `dd` CD-label poke with `patch_ra95.py base`.
- Modify `docs/wine-rendering-explainer.md` and `AGENTS.md`: document the unified utility and mark `game-in-focus` as quarantined.
- Keep old `scripts/ra/ra-*-patch.py` files during this plan as deprecated compatibility shims only after callers are migrated.

---

### Task 1: Add Failing RA95 Patcher Tests

**Files:**
- Create: `scripts/test_ra95_patcher.py`

- [ ] **Step 1: Write the failing test file**

Create `scripts/test_ra95_patcher.py` with this content:

```python
#!/usr/bin/env python3
"""Tests for the unified RA95 patcher registry and mode selection."""

import json
import tempfile
import unittest
from pathlib import Path

from ra.ra95_patches import (
    PatchError,
    apply_mode,
    infer_side,
    mode_patch_ids,
    patch_registry,
)


class RA95PatcherRegistryTest(unittest.TestCase):
    def test_mission_mode_has_smart_defaults(self):
        ids = mode_patch_ids("mission", scenario="SCU01EA.INI", seed=0x1EED5EED)

        self.assertIn("focus-wait-skip", ids)
        self.assertIn("vqa-skip", ids)
        self.assertIn("briefing-skip", ids)
        self.assertIn("scenario", ids)
        self.assertIn("autostart", ids)
        self.assertIn("random-seed", ids)
        self.assertNotIn("game-in-focus", ids)
        self.assertNotIn("frameinfo-send-guard", ids)
        self.assertNotIn("force-normal-queue", ids)

    def test_side_inference_uses_scenario_prefix(self):
        self.assertEqual(infer_side("SCG02EA.INI"), "allied")
        self.assertEqual(infer_side("SCU03EA"), "soviet")
        with self.assertRaisesRegex(ValueError, "SCG or SCU"):
            infer_side("BAD01EA.INI")

    def test_diagnostic_and_quarantine_statuses_are_not_defaultable(self):
        registry = patch_registry()

        self.assertEqual(registry["frameinfo-send-guard"].status, "diagnostic")
        self.assertFalse(registry["frameinfo-send-guard"].default_allowed)
        self.assertEqual(registry["force-normal-queue"].status, "diagnostic")
        self.assertFalse(registry["force-normal-queue"].default_allowed)
        self.assertEqual(registry["game-in-focus"].status, "quarantined")
        self.assertFalse(registry["game-in-focus"].default_allowed)

    def test_unexpected_bytes_fail_with_offset_and_patch_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            exe.write_bytes(b"\x00" * 0x1A54A4)

            with self.assertRaises(PatchError) as raised:
                apply_mode("base", exe)

            message = str(raised.exception)
            self.assertIn("nocd", message)
            self.assertIn("0x001a54a1", message)

    def test_manifest_records_idempotent_and_applied_edits(self):
        registry = patch_registry()
        edit = registry["nocd"].edits[0]
        size = edit.offset + len(edit.expected)
        data = bytearray(b"\x00" * size)
        data[0x1A5498 : 0x1A5498 + 6] = bytes.fromhex("ff1560026e00")
        data[0x1A549E : 0x1A549E + 3] = bytes.fromhex("83f805")
        data[edit.offset : edit.offset + len(edit.expected)] = edit.expected

        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            manifest = Path(tmp) / "patches.json"
            exe.write_bytes(data)

            result = apply_mode("base", exe, manifest_path=manifest, patches=["nocd"])
            first_manifest = json.loads(manifest.read_text())

            self.assertEqual(result.output_sha256, first_manifest["output_sha256"])
            self.assertEqual(first_manifest["patches"][0]["id"], "nocd")
            self.assertEqual(first_manifest["patches"][0]["edits"][0]["result"], "applied")

            apply_mode("base", exe, manifest_path=manifest, patches=["nocd"])
            second_manifest = json.loads(manifest.read_text())
            self.assertEqual(second_manifest["patches"][0]["edits"][0]["result"], "already-applied")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
python3 scripts/test_ra95_patcher.py
```

Expected: fail with `ModuleNotFoundError: No module named 'ra.ra95_patches'`.

- [ ] **Step 3: Commit the failing tests**

```bash
git add scripts/test_ra95_patcher.py
git commit -m "test: cover unified RA95 patcher contract"
```

---

### Task 2: Implement Patch Registry Core

**Files:**
- Create: `scripts/ra/ra95_patches.py`
- Create: `scripts/ra/__init__.py` if it does not already exist
- Test: `scripts/test_ra95_patcher.py`

- [ ] **Step 1: Create the registry module**

Create `scripts/ra/ra95_patches.py` with the code below. This first version implements the core types, base patches, scenario inference, byte validation, idempotency, and manifest output.

```python
#!/usr/bin/env python3
"""Declarative RA95.EXE patch registry and byte patching engine."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import struct
import sys
from pathlib import Path
from typing import Iterable


DEFAULT_RANDOM_SEED = 0x1EED5EED


class PatchError(RuntimeError):
    """Raised when an RA95 patch cannot be safely applied."""


@dataclass(frozen=True)
class ByteEdit:
    offset: int
    expected: bytes
    replacement: bytes
    label: str
    va: int | None = None


@dataclass(frozen=True)
class PatchSpec:
    id: str
    purpose: str
    status: str
    edits: tuple[ByteEdit, ...] = ()
    default_allowed: bool = False
    requires_allow_diagnostic: bool = False
    requires_allow_quarantined: bool = False


@dataclass
class PatchResult:
    input_sha256: str
    output_sha256: str
    changed_ranges: list[dict[str, str]]
    manifest: dict


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def va_to_file_offset(va: int) -> int:
    if 0x00410000 <= va < 0x005CCE00:
        return 0x00000400 + (va - 0x00410000)
    if 0x005D0000 <= va < 0x00605000:
        return 0x001BD200 + (va - 0x005D0000)
    raise ValueError(f"VA 0x{va:08x} not in mapped RA95 sections")


def infer_side(scenario: str) -> str:
    stem = scenario.upper().strip()
    if stem.endswith(".INI"):
        stem = stem[:-4]
    if stem.startswith("SCG"):
        return "allied"
    if stem.startswith("SCU"):
        return "soviet"
    raise ValueError(f"scenario must start with SCG or SCU: {scenario!r}")


def normalize_scenario(scenario: str) -> str:
    value = scenario.upper().strip()
    if not value.endswith(".INI"):
        value += ".INI"
    if len(value) > 12:
        raise ValueError(f"scenario name too long: {value!r}")
    infer_side(value)
    return value


def patch_registry() -> dict[str, PatchSpec]:
    return {
        "nocd": PatchSpec(
            id="nocd",
            purpose="Bypass physical CD-ROM drive type check.",
            status="trusted",
            default_allowed=True,
            edits=(
                ByteEdit(
                    offset=0x1A54A1,
                    expected=bytes.fromhex("75dd"),
                    replacement=bytes.fromhex("9090"),
                    label="GetDriveTypeA != DRIVE_CDROM branch -> NOP",
                ),
            ),
        ),
        "ddscl-normal": PatchSpec(
            id="ddscl-normal",
            purpose="Use DDSCL_NORMAL for Wine/cnc-ddraw windowed capture.",
            status="trusted",
            default_allowed=True,
            edits=(
                ByteEdit(
                    offset=0x1A4A34,
                    expected=bytes.fromhex("51"),
                    replacement=bytes.fromhex("08"),
                    label="DDSCL_EXCLUSIVE|FULLSCREEN|ALLOWMODEX -> DDSCL_NORMAL",
                ),
                ByteEdit(
                    offset=0x1A4A3F,
                    expected=bytes.fromhex("11"),
                    replacement=bytes.fromhex("08"),
                    label="DDSCL_EXCLUSIVE|FULLSCREEN -> DDSCL_NORMAL",
                ),
            ),
        ),
        "cd-label": PatchSpec(
            id="cd-label",
            purpose="Normalize embedded CD-label bytes for capture disc selection.",
            status="capture-only",
            default_allowed=True,
            edits=(
                ByteEdit(
                    offset=0x1BFCB7,
                    expected=b"C",
                    replacement=b"\x00",
                    label="default base CD1 label first byte -> NUL",
                ),
            ),
        ),
    }


def mode_patch_ids(
    mode: str,
    *,
    scenario: str | None = None,
    seed: int | None = None,
    skip_vqa: bool = True,
    skip_briefing: bool = True,
) -> list[str]:
    if mode == "base":
        return ["nocd", "ddscl-normal", "cd-label"]
    if mode == "mission":
        if not scenario:
            raise ValueError("mission mode requires --scenario")
        ids = ["focus-wait-skip"]
        if skip_vqa:
            ids.append("vqa-skip")
            if skip_briefing:
                ids.append("briefing-skip")
        ids.extend(["scenario", "autostart"])
        if seed is not None:
            ids.append("random-seed")
        return ids
    raise ValueError(f"unknown RA95 patch mode: {mode}")


def diff_byte_ranges(before: bytes, after: bytes) -> list[dict[str, str]]:
    ranges: list[dict[str, str]] = []
    index = 0
    limit = max(len(before), len(after))
    while index < limit:
        old = before[index : index + 1] if index < len(before) else b""
        new = after[index : index + 1] if index < len(after) else b""
        if old == new:
            index += 1
            continue
        start = index
        while index < limit:
            old = before[index : index + 1] if index < len(before) else b""
            new = after[index : index + 1] if index < len(after) else b""
            if old == new:
                break
            index += 1
        ranges.append(
            {
                "offset": f"0x{start:08x}",
                "before": before[start : min(index, len(before))].hex(),
                "after": after[start : min(index, len(after))].hex(),
            }
        )
    return ranges


def _apply_static_patch(data: bytearray, spec: PatchSpec) -> list[dict]:
    edit_results: list[dict] = []
    for edit in spec.edits:
        actual = bytes(data[edit.offset : edit.offset + len(edit.expected)])
        if actual == edit.replacement:
            result = "already-applied"
        elif actual == edit.expected:
            data[edit.offset : edit.offset + len(edit.replacement)] = edit.replacement
            result = "applied"
        else:
            raise PatchError(
                f"{spec.id}: unexpected bytes at 0x{edit.offset:08x}: "
                f"expected {edit.expected.hex()} or {edit.replacement.hex()}, got {actual.hex()}"
            )
        edit_results.append(
            {
                "offset": f"0x{edit.offset:08x}",
                "va": f"0x{edit.va:08x}" if edit.va is not None else None,
                "expected": edit.expected.hex(),
                "replacement": edit.replacement.hex(),
                "actual": actual.hex(),
                "result": result,
                "label": edit.label,
            }
        )
    return edit_results


def apply_mode(
    mode: str,
    exe_path: Path | str,
    *,
    scenario: str | None = None,
    side: str | None = None,
    seed: int | None = None,
    patches: Iterable[str] | None = None,
    skip_vqa: bool = True,
    skip_briefing: bool = True,
    allow_diagnostic: bool = False,
    allow_quarantined: bool = False,
    manifest_path: Path | str | None = None,
) -> PatchResult:
    exe = Path(exe_path)
    before = exe.read_bytes()
    data = bytearray(before)
    registry = patch_registry()
    selected = list(patches) if patches is not None else mode_patch_ids(
        mode,
        scenario=scenario,
        seed=seed,
        skip_vqa=skip_vqa,
        skip_briefing=skip_briefing,
    )

    patch_entries = []
    for patch_id in selected:
        spec = registry[patch_id]
        if spec.status == "diagnostic" and not allow_diagnostic:
            raise PatchError(f"{patch_id}: diagnostic patch requires --allow-diagnostic")
        if spec.status == "quarantined" and not allow_quarantined:
            raise PatchError(f"{patch_id}: quarantined patch requires --allow-quarantined")
        if not spec.default_allowed and patches is None:
            raise PatchError(f"{patch_id}: patch is not allowed in default mode {mode}")
        edits = _apply_static_patch(data, spec)
        patch_entries.append(
            {
                "id": spec.id,
                "purpose": spec.purpose,
                "status": spec.status,
                "edits": edits,
            }
        )

    exe.write_bytes(data)
    after = bytes(data)
    manifest = {
        "tool": "patch_ra95.py",
        "mode": mode,
        "argv": sys.argv[:],
        "input_sha256": sha256_bytes(before),
        "output_sha256": sha256_bytes(after),
        "scenario": normalize_scenario(scenario) if scenario else None,
        "side": side or (infer_side(scenario) if scenario else None),
        "seed": seed,
        "patches": patch_entries,
        "changed_ranges": diff_byte_ranges(before, after),
    }
    if manifest_path is not None:
        Path(manifest_path).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return PatchResult(
        input_sha256=manifest["input_sha256"],
        output_sha256=manifest["output_sha256"],
        changed_ranges=manifest["changed_ranges"],
        manifest=manifest,
    )
```

- [ ] **Step 2: Make `scripts/ra` importable if needed**

If `scripts/ra/__init__.py` does not exist, create it with:

```python
"""RA tooling package."""
```

- [ ] **Step 3: Run tests and verify partial progress**

Run:

```bash
python3 scripts/test_ra95_patcher.py
```

Expected: failures for missing mission patch ids such as `focus-wait-skip`, while base validation tests pass.

- [ ] **Step 4: Commit the core**

```bash
git add scripts/ra/ra95_patches.py scripts/ra/__init__.py scripts/test_ra95_patcher.py
git commit -m "feat: add RA95 patch registry core"
```

---

### Task 3: Add Mission, Diagnostic, and Quarantine Patch Support

**Files:**
- Modify: `scripts/ra/ra95_patches.py`
- Test: `scripts/test_ra95_patcher.py`

- [ ] **Step 1: Extend tests for mission defaults and policy rejection**

Append these tests to `RA95PatcherRegistryTest` in `scripts/test_ra95_patcher.py`:

```python
    def test_diagnostic_patch_requires_allow_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            exe.write_bytes(b"\x00" * 0x200000)

            with self.assertRaisesRegex(PatchError, "allow-diagnostic"):
                apply_mode(
                    "mission",
                    exe,
                    scenario="SCU01EA.INI",
                    patches=["frameinfo-send-guard"],
                )

    def test_quarantined_patch_requires_allow_flag(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            exe.write_bytes(b"\x00" * 0x200000)

            with self.assertRaisesRegex(PatchError, "allow-quarantined"):
                apply_mode(
                    "mission",
                    exe,
                    scenario="SCU01EA.INI",
                    patches=["game-in-focus"],
                )
```

- [ ] **Step 2: Add dynamic patch helpers**

Add these helper functions to `scripts/ra/ra95_patches.py` below `patch_registry()`:

```python
def _scenario_edits(data: bytearray, scenario: str) -> list[dict]:
    normalized = normalize_scenario(scenario).ljust(12, "\x00").encode("ascii")[:12]
    edits: list[dict] = []
    for source in (b"SCG01EA.INI\x00", b"SCU01EA.INI\x00"):
        offset = 0
        while True:
            offset = data.find(source, offset)
            if offset < 0:
                break
            actual = bytes(data[offset : offset + 12])
            if actual == normalized:
                result = "already-applied"
            else:
                data[offset : offset + 12] = normalized
                result = "applied"
            edits.append(
                {
                    "offset": f"0x{offset:08x}",
                    "va": None,
                    "expected": source.hex(),
                    "replacement": normalized.hex(),
                    "actual": actual.hex(),
                    "result": result,
                    "label": "scenario string replacement",
                }
            )
            offset += 12
    if not edits:
        raise PatchError("scenario: could not find SCG01EA.INI or SCU01EA.INI")
    return edits


def _seed_edits(data: bytearray, seed: int) -> list[dict]:
    if seed < 0 or seed > 0xFFFFFFFF:
        raise PatchError(f"random-seed: seed out of 32-bit range: {seed}")
    va = 0x004FF345
    offset = va_to_file_offset(va)
    expected = bytes.fromhex("31c0e8856d0b00e8dd6d0b00e8b46d0b00")
    replacement = b"\xb8" + struct.pack("<I", seed) + b"\x90" * 12
    actual = bytes(data[offset : offset + len(expected)])
    if actual == replacement:
        result = "already-applied"
    elif actual == expected:
        data[offset : offset + len(replacement)] = replacement
        result = "applied"
    else:
        raise PatchError(
            f"random-seed: unexpected bytes at 0x{offset:08x}: "
            f"expected {expected.hex()} or {replacement.hex()}, got {actual.hex()}"
        )
    return [
        {
            "offset": f"0x{offset:08x}",
            "va": f"0x{va:08x}",
            "expected": expected.hex(),
            "replacement": replacement.hex(),
            "actual": actual.hex(),
            "result": result,
            "label": "single-player Init_Random seed",
        }
    ]


def _cd_label_edits(data: bytearray, side: str) -> list[dict]:
    cd1_offset = 0x1BFCB7
    cd2_offset = cd1_offset + 4
    replacements = {
        "allied": ((cd1_offset, b"\x00", "CD1 label first byte"), (cd2_offset, b"C", "CD2 label first byte")),
        "soviet": ((cd1_offset, b"C", "CD1 label first byte"), (cd2_offset, b"\x00", "CD2 label first byte")),
    }[side]
    edits: list[dict] = []
    for offset, replacement, label in replacements:
        actual = bytes(data[offset : offset + 1])
        data[offset : offset + 1] = replacement
        edits.append(
            {
                "offset": f"0x{offset:08x}",
                "va": None,
                "expected": "",
                "replacement": replacement.hex(),
                "actual": actual.hex(),
                "result": "already-applied" if actual == replacement else "applied",
                "label": label,
            }
        )
    return edits
```

- [ ] **Step 3: Extend the registry with static mission patches**

Add these entries to the dictionary returned by `patch_registry()`:

```python
        "focus-wait-skip": PatchSpec(
            id="focus-wait-skip",
            purpose="Skip Wine headless focus wait branches.",
            status="capture-only",
            default_allowed=True,
            edits=(
                ByteEdit(0x154005, bytes.fromhex("0f8455ffffff"), b"\x90" * 6, "focus wait branch 1"),
                ByteEdit(0x15F2F1, bytes.fromhex("0f847bffffff"), b"\x90" * 6, "focus wait branch 2"),
                ByteEdit(0x15F583, bytes.fromhex("0f847affffff"), b"\x90" * 6, "focus wait branch 3"),
            ),
        ),
        "vqa-skip": PatchSpec(
            id="vqa-skip",
            purpose="Make Play_Movie return immediately for gameplay capture.",
            status="capture-only",
            default_allowed=True,
            edits=(ByteEdit(0x0A53C4, bytes.fromhex("55"), bytes.fromhex("c3"), "Play_Movie prologue -> RET"),),
        ),
        "briefing-skip": PatchSpec(
            id="briefing-skip",
            purpose="Skip text mission briefing dialog.",
            status="capture-only",
            default_allowed=True,
            edits=(ByteEdit(va_to_file_offset(0x00542E96), bytes.fromhex("e8a1110000"), bytes.fromhex("9090909090"), "Restate_Mission call -> NOP", va=0x00542E96),),
        ),
        "autostart": PatchSpec(
            id="autostart",
            purpose="Enter the selected mission directly at Normal difficulty.",
            status="capture-only",
            default_allowed=True,
            edits=(
                ByteEdit(va_to_file_offset(0x004FD00E), bytes.fromhex("f6050c5d650004"), bytes.fromhex("800d0c5d650004"), "set Special.IsFromInstall", va=0x004FD00E),
                ByteEdit(va_to_file_offset(0x004FD4F5), bytes.fromhex("803db8b66600007507"), bytes.fromhex("c605b8b66600009090"), "Session.Type = GAME_NORMAL", va=0x004FD4F5),
                ByteEdit(va_to_file_offset(0x004FD4FE), bytes.fromhex("be08000000"), bytes.fromhex("be01000000"), "SEL_NONE -> SEL_START_NEW_GAME", va=0x004FD4FE),
                ByteEdit(va_to_file_offset(0x004FD505), bytes.fromhex("be04000000"), bytes.fromhex("be01000000"), "SEL_MULTIPLAYER -> SEL_START_NEW_GAME", va=0x004FD505),
                ByteEdit(va_to_file_offset(0x004FD7A5), bytes.fromhex("7436"), bytes.fromhex("eb36"), "skip pending external/network game branch", va=0x004FD7A5),
                ByteEdit(va_to_file_offset(0x004FDC67), bytes.fromhex("7468"), bytes.fromhex("9090"), "skip Fetch_Difficulty", va=0x004FDC67),
                ByteEdit(va_to_file_offset(0x004FDD10), bytes.fromhex("755d"), bytes.fromhex("eb5d"), "skip faction dialog", va=0x004FDD10),
            ),
        ),
        "scenario": PatchSpec("scenario", "Replace hardcoded L1 scenario strings.", "capture-only", default_allowed=True),
        "random-seed": PatchSpec("random-seed", "Use a fixed gameplay random seed.", "capture-only", default_allowed=True),
        "force-normal-queue": PatchSpec(
            id="force-normal-queue",
            purpose="Diagnostic: force Queue_AI to dispatch as GAME_NORMAL.",
            status="diagnostic",
            default_allowed=False,
            requires_allow_diagnostic=True,
            edits=(ByteEdit(va_to_file_offset(0x005329A3), bytes.fromhex("a0b8b66600"), bytes.fromhex("31c0909090"), "Queue_AI Session.Type read -> GAME_NORMAL", va=0x005329A3),),
        ),
        "frameinfo-send-guard": PatchSpec(
            id="frameinfo-send-guard",
            purpose="Diagnostic: suppress malformed frameinfo send path.",
            status="diagnostic",
            default_allowed=False,
            requires_allow_diagnostic=True,
            edits=(
                ByteEdit(va_to_file_offset(0x00533AF5), bytes.fromhex("e862070000"), bytes.fromhex("31c0909090"), "frameinfo builder", va=0x00533AF5),
                ByteEdit(va_to_file_offset(0x00533AFA), bytes.fromhex("6aff"), bytes.fromhex("9090"), "frameinfo send push", va=0x00533AFA),
                ByteEdit(va_to_file_offset(0x00533B0D), bytes.fromhex("ff5708"), bytes.fromhex("909090"), "frameinfo send call", va=0x00533B0D),
            ),
        ),
        "game-in-focus": PatchSpec(
            id="game-in-focus",
            purpose="Quarantined: confirmed bad Session.Type write previously mislabeled as GameInFocus.",
            status="quarantined",
            default_allowed=False,
            requires_allow_quarantined=True,
        ),
```

- [ ] **Step 4: Route dynamic patches inside `apply_mode()`**

Replace this line in `apply_mode()`:

```python
        edits = _apply_static_patch(data, spec)
```

with:

```python
        effective_side = side or (infer_side(scenario) if scenario else "allied")
        if patch_id == "scenario":
            if not scenario:
                raise PatchError("scenario patch requires --scenario")
            edits = _scenario_edits(data, scenario)
        elif patch_id == "random-seed":
            if seed is None:
                raise PatchError("random-seed patch requires --seed")
            edits = _seed_edits(data, seed)
        elif patch_id == "cd-label":
            edits = _cd_label_edits(data, effective_side if mode == "mission" else "allied")
        elif patch_id == "autostart":
            edits = _apply_static_patch(data, spec)
            side_offset = va_to_file_offset(0x004FDD8F)
            side_expected = bytes.fromhex("7507")
            side_replacement = bytes.fromhex("eb07") if effective_side == "soviet" else bytes.fromhex("9090")
            actual = bytes(data[side_offset : side_offset + 2])
            if actual == side_replacement:
                result = "already-applied"
            elif actual == side_expected:
                data[side_offset : side_offset + 2] = side_replacement
                result = "applied"
            else:
                raise PatchError(
                    f"autostart: unexpected side bytes at 0x{side_offset:08x}: "
                    f"expected {side_expected.hex()} or {side_replacement.hex()}, got {actual.hex()}"
                )
            edits.append(
                {
                    "offset": f"0x{side_offset:08x}",
                    "va": "0x004fdd8f",
                    "expected": side_expected.hex(),
                    "replacement": side_replacement.hex(),
                    "actual": actual.hex(),
                    "result": result,
                    "label": f"select {effective_side} scenario path",
                }
            )
        else:
            edits = _apply_static_patch(data, spec)
```

- [ ] **Step 5: Run tests**

Run:

```bash
python3 scripts/test_ra95_patcher.py
```

Expected: all tests pass.

- [ ] **Step 6: Commit mission support**

```bash
git add scripts/ra/ra95_patches.py scripts/test_ra95_patcher.py
git commit -m "feat: add RA95 mission patch modes"
```

---

### Task 4: Add the Unified CLI

**Files:**
- Create: `scripts/ra/patch_ra95.py`
- Test: `scripts/test_ra95_patcher.py`

- [ ] **Step 1: Add CLI smoke tests**

Append this test class to `scripts/test_ra95_patcher.py`:

```python
class RA95PatcherCLITest(unittest.TestCase):
    def test_cli_help_imports(self):
        import subprocess

        result = subprocess.run(
            ["python3", "scripts/ra/patch_ra95.py", "--help"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("base", result.stdout)
        self.assertIn("mission", result.stdout)
```

- [ ] **Step 2: Create CLI file**

Create `scripts/ra/patch_ra95.py`:

```python
#!/usr/bin/env python3
"""Unified RA95.EXE binary patcher."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ra.ra95_patches import DEFAULT_RANDOM_SEED, PatchError, apply_mode, patch_registry


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)

    base = sub.add_parser("base", help="apply base RA95 Wine patches")
    base.add_argument("exe_path")
    base.add_argument("--manifest")

    mission = sub.add_parser("mission", help="apply default Wine mission capture patches")
    mission.add_argument("exe_path")
    mission.add_argument("--scenario", required=True)
    mission.add_argument("--side", choices=("allied", "soviet"))
    mission.add_argument("--seed", type=lambda value: int(value, 0), default=DEFAULT_RANDOM_SEED)
    mission.add_argument("--no-seed", action="store_true")
    mission.add_argument("--no-vqa-skip", action="store_true")
    mission.add_argument("--no-briefing-skip", action="store_true")
    mission.add_argument("--diagnostic", action="append", default=[])
    mission.add_argument("--allow-diagnostic", action="store_true")
    mission.add_argument("--allow-quarantined", action="store_true")
    mission.add_argument("--manifest")

    apply = sub.add_parser("apply", help="apply explicit patch ids")
    apply.add_argument("exe_path")
    apply.add_argument("--patch", action="append", required=True, choices=sorted(patch_registry()))
    apply.add_argument("--scenario")
    apply.add_argument("--side", choices=("allied", "soviet"))
    apply.add_argument("--seed", type=lambda value: int(value, 0))
    apply.add_argument("--allow-diagnostic", action="store_true")
    apply.add_argument("--allow-quarantined", action="store_true")
    apply.add_argument("--manifest")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.mode == "base":
            result = apply_mode("base", args.exe_path, manifest_path=args.manifest)
        elif args.mode == "mission":
            seed = None if args.no_seed else args.seed
            patches = None
            if args.diagnostic:
                from ra.ra95_patches import mode_patch_ids

                patches = mode_patch_ids(
                    "mission",
                    scenario=args.scenario,
                    seed=seed,
                    skip_vqa=not args.no_vqa_skip,
                    skip_briefing=not args.no_briefing_skip,
                )
                patches.extend(args.diagnostic)
            result = apply_mode(
                "mission",
                args.exe_path,
                scenario=args.scenario,
                side=args.side,
                seed=seed,
                patches=patches,
                skip_vqa=not args.no_vqa_skip,
                skip_briefing=not args.no_briefing_skip,
                allow_diagnostic=args.allow_diagnostic,
                allow_quarantined=args.allow_quarantined,
                manifest_path=args.manifest,
            )
        elif args.mode == "apply":
            result = apply_mode(
                "apply",
                args.exe_path,
                scenario=args.scenario,
                side=args.side,
                seed=args.seed,
                patches=args.patch,
                allow_diagnostic=args.allow_diagnostic,
                allow_quarantined=args.allow_quarantined,
                manifest_path=args.manifest,
            )
        else:
            raise AssertionError(args.mode)
    except (PatchError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"{args.exe_path}: patched {result.input_sha256[:12]} -> {result.output_sha256[:12]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 3: Run CLI tests**

Run:

```bash
python3 scripts/test_ra95_patcher.py
python3 -m py_compile scripts/ra/patch_ra95.py scripts/ra/ra95_patches.py
```

Expected: both commands pass.

- [ ] **Step 4: Commit CLI**

```bash
git add scripts/ra/patch_ra95.py scripts/test_ra95_patcher.py
git commit -m "feat: add unified RA95 patch CLI"
```

---

### Task 5: Migrate Flake Base Patching

**Files:**
- Modify: `flake.nix`
- Test: `scripts/test_ra95_patcher.py`

- [ ] **Step 1: Add a base-mode equivalence test**

Add this test to `RA95PatcherRegistryTest`:

```python
    def test_base_mode_selects_only_base_patches(self):
        self.assertEqual(mode_patch_ids("base"), ["nocd", "ddscl-normal", "cd-label"])
```

- [ ] **Step 2: Update `flake.nix`**

In the `ra-patched-exe` derivation, replace:

```nix
                python3 ${./scripts/ra/ra-nocd-patch.py} "$out"
                python3 ${./scripts/ra/ra-ddscl-patch.py} "$out"
                # cdlabel: zero the first byte of the "CD1" volume label string
                printf '\x00' | dd of="$out" bs=1 seek=$((0x1BFCB7)) conv=notrunc 2>/dev/null
```

with:

```nix
                python3 ${./scripts/ra/patch_ra95.py} base "$out"
```

- [ ] **Step 3: Verify the Nix package builds**

Run:

```bash
nix build .#ra-patched-exe --impure --print-out-paths
```

Expected: command prints one Nix store path and exits 0.

- [ ] **Step 4: Run Python tests**

```bash
python3 scripts/test_ra95_patcher.py
```

Expected: tests pass.

- [ ] **Step 5: Commit flake migration**

```bash
git add flake.nix scripts/test_ra95_patcher.py
git commit -m "build: use unified RA95 base patcher"
```

---

### Task 6: Migrate Wine Driver to One Patcher Invocation

**Files:**
- Modify: `scripts/drivers/wine.py`
- Modify: `scripts/test_wine_patch_chain.py`
- Test: `scripts/test_wine_patch_chain.py`

- [ ] **Step 1: Replace patch-chain tests**

Replace `scripts/test_wine_patch_chain.py` with:

```python
#!/usr/bin/env python3
"""Tests for Wine RA95 unified patcher command selection."""

import os
import unittest

from drivers.wine import mission_patch_command


class WinePatchCommandTest(unittest.TestCase):
    def setUp(self):
        self.old_guard = os.environ.get("WINE_FRAMEINFO_GUARD")
        os.environ.pop("WINE_FRAMEINFO_GUARD", None)

    def tearDown(self):
        if self.old_guard is None:
            os.environ.pop("WINE_FRAMEINFO_GUARD", None)
        else:
            os.environ["WINE_FRAMEINFO_GUARD"] = self.old_guard

    def test_mission_command_uses_smart_defaults(self):
        command = mission_patch_command(
            "RA95.EXE",
            "wine-patches.json",
            scenario="SCU01EA.INI",
            skip_vqa=True,
            autostart=True,
            random_seed=0x1EED5EED,
        )

        self.assertEqual(command[:4], ["python3", "scripts/ra/patch_ra95.py", "mission", "RA95.EXE"])
        self.assertIn("--scenario", command)
        self.assertIn("SCU01EA.INI", command)
        self.assertIn("--manifest", command)
        self.assertIn("wine-patches.json", command)
        self.assertNotIn("--diagnostic", command)

    def test_frameinfo_guard_is_opt_in(self):
        command = mission_patch_command(
            "RA95.EXE",
            "wine-patches.json",
            scenario="SCU01EA.INI",
            skip_vqa=True,
            autostart=True,
            random_seed=0x1EED5EED,
        )

        self.assertNotIn("frameinfo-send-guard", command)

    def test_frameinfo_guard_can_be_enabled_for_diagnostics(self):
        os.environ["WINE_FRAMEINFO_GUARD"] = "1"

        command = mission_patch_command(
            "RA95.EXE",
            "wine-patches.json",
            scenario="SCU01EA.INI",
            skip_vqa=True,
            autostart=True,
            random_seed=0x1EED5EED,
        )

        self.assertIn("--diagnostic", command)
        self.assertIn("frameinfo-send-guard", command)
        self.assertIn("--allow-diagnostic", command)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Add `mission_patch_command()` to `scripts/drivers/wine.py`**

Replace `mission_patch_scripts()` with this helper:

```python
def mission_patch_command(
    exe_path,
    manifest_path,
    *,
    scenario=None,
    skip_vqa=True,
    autostart=True,
    random_seed=None,
) -> list[str]:
    """Return the unified RA95 patch command used for Wine mission capture."""
    if not autostart:
        raise ValueError("Wine mission capture requires autostart")
    if not scenario:
        raise ValueError("Wine mission capture requires scenario")

    command = [
        "python3",
        "scripts/ra/patch_ra95.py",
        "mission",
        str(exe_path),
        "--scenario",
        scenario,
        "--manifest",
        str(manifest_path),
    ]
    if not skip_vqa:
        command.append("--no-vqa-skip")
    if random_seed is None:
        command.append("--no-seed")
    else:
        command.extend(["--seed", f"0x{int(random_seed):08x}"])
    if os.environ.get("WINE_FRAMEINFO_GUARD", "0") not in ("", "0"):
        command.extend(["--diagnostic", "frameinfo-send-guard", "--allow-diagnostic"])
    if os.environ.get("WINE_FORCE_NORMAL_QUEUE", "0") not in ("", "0"):
        command.extend(["--diagnostic", "force-normal-queue", "--allow-diagnostic"])
    return command
```

- [ ] **Step 3: Replace script loop in `_setup_staging()`**

In `scripts/drivers/wine.py`, replace the loop that calls each script in `mission_patch_scripts()` with:

```python
        patch_command = mission_patch_command(
            exe,
            self._patch_manifest_path(output_dir),
            scenario=scenario,
            skip_vqa=skip_vqa,
            autostart=autostart,
            random_seed=self.random_seed,
        )
        r = subprocess.run(
            patch_command,
            cwd=self.root,
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            raise RuntimeError(
                "patch_ra95.py mission failed "
                f"(rc={r.returncode}):\nSTDOUT:\n{r.stdout}\nSTDERR:\n{r.stderr}"
            )
```

Use the existing staging output directory variable that currently receives `wine-patches.json`; if the current method computes the manifest path differently, pass that same path to `mission_patch_command()`.

- [ ] **Step 4: Remove duplicated CD-label and random-seed patch calls**

Delete or bypass these now-redundant Wine driver steps:

```python
_patch_cd_label(...)
subprocess.run([... "ra-random-seed-patch.py", ...])
```

The unified mission mode now owns side inference, CD-label selection, scenario patching, autostart, and random seed.

- [ ] **Step 5: Run tests**

```bash
python3 scripts/test_wine_patch_chain.py
python3 scripts/test_ra95_patcher.py
```

Expected: both pass.

- [ ] **Step 6: Commit Wine migration**

```bash
git add scripts/drivers/wine.py scripts/test_wine_patch_chain.py
git commit -m "refactor: route Wine RA95 patching through unified utility"
```

---

### Task 7: Deprecate Old RA Patch Scripts and Update Docs

**Files:**
- Modify: `AGENTS.md`
- Modify: `docs/wine-rendering-explainer.md`
- Modify: old `scripts/ra/ra-*-patch.py` files only if compatibility shims are kept

- [ ] **Step 1: Update docs to point at the unified patcher**

In `AGENTS.md`, replace the old auto-launch patch chain commands with:

```bash
python3 scripts/ra/patch_ra95.py base RA95.EXE
python3 scripts/ra/patch_ra95.py mission RA95.EXE --scenario SCG02EA.INI
```

Add this note:

```markdown
`ra-game-in-focus-patch.py` is quarantined. It writes to an address now known to
behave as `Session.Type`, not `GameInFocus`, and must not be used for normal
captures.
```

- [ ] **Step 2: Update `docs/wine-rendering-explainer.md`**

Replace the binary patch table entries for standalone scripts with a short table describing unified patch ids:

```markdown
| Patch id | Purpose |
| --- | --- |
| `nocd` | Bypass physical CD-ROM drive detection. |
| `ddscl-normal` | Use normal/windowed DirectDraw cooperative level. |
| `cd-label` | Select effective Allied/Soviet disc label for capture. |
| `focus-wait-skip` | Skip focus wait branches under headless Wine; still under audit. |
| `vqa-skip` | Make `Play_Movie` return immediately for gameplay capture. |
| `briefing-skip` | Skip text mission briefing dialog. |
| `scenario` | Replace hardcoded L1 scenario strings with the requested mission. |
| `autostart` | Enter the requested mission at Normal difficulty. |
| `random-seed` | Use deterministic gameplay RNG for parity screenshots. |
| `game-in-focus` | Quarantined bad patch; do not use. |
```

- [ ] **Step 3: Decide shim policy and apply it consistently**

Keep old scripts for one release as compatibility shims. In each old script, add this warning immediately after `import sys`:

```python
print(
    "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
    file=sys.stderr,
)
```

Do not add this warning to `patch_ra95.py` or `ra95_patches.py`.

- [ ] **Step 4: Run documentation and Python checks**

```bash
python3 -m py_compile scripts/ra/patch_ra95.py scripts/ra/ra95_patches.py scripts/ra/ra-nocd-patch.py scripts/ra/ra-ddscl-patch.py scripts/ra/ra-autostart-patch.py
python3 scripts/test_ra95_patcher.py
python3 scripts/test_wine_patch_chain.py
```

Expected: all pass.

- [ ] **Step 5: Commit docs and shims**

```bash
git add AGENTS.md docs/wine-rendering-explainer.md scripts/ra/ra-*-patch.py
git commit -m "docs: deprecate standalone RA95 patch scripts"
```

---

### Task 8: End-to-End Verification

**Files:**
- No source edits expected unless verification exposes a bug.

- [ ] **Step 1: Run unit tests**

```bash
python3 scripts/test_ra95_patcher.py
python3 scripts/test_wine_patch_chain.py
```

Expected: both pass.

- [ ] **Step 2: Build patched RA95 executable**

```bash
nix build .#ra-patched-exe --impure --print-out-paths
```

Expected: prints one store path.

- [ ] **Step 3: Capture one Allied and one Soviet mission**

```bash
python3 scripts/capture-checkpoint.py mission allied-l1 --targets wine --frame 120
python3 scripts/capture-checkpoint.py mission soviet-l1 --targets wine --frame 120
```

Expected: both sessions contain `wine.png`, `wine-driver.log`, and `wine-patches.json`; the manifest lists `patch_ra95.py` mode `mission` and does not list `game-in-focus`.

- [ ] **Step 4: Inspect manifests**

Run:

```bash
python3 - <<'PY'
import json
from pathlib import Path
for path in sorted(Path("/tmp/battlecontrol").glob("*mission-*/*wine-patches.json"))[-2:]:
    data = json.loads(path.read_text())
    ids = [patch["id"] for patch in data["patches"]]
    print(path)
    print(ids)
    assert "game-in-focus" not in ids
    assert "frameinfo-send-guard" not in ids
    assert "force-normal-queue" not in ids
PY
```

Expected: prints two manifest paths and patch id lists without assertions.

- [ ] **Step 5: Run project gate if the dev shell exposes all tools**

```bash
nix run .#test
```

Expected: pass. If it fails because the current shell cannot find `ruff`, `yamllint`, `shfmt`, or `nixfmt`, record that environment failure in the final report and include the unit and capture verification from Steps 1 through 4.

- [ ] **Step 6: Commit verification fixes if any were needed**

If Step 3 or Step 4 required source changes, stage only those explicit files. For example, if the Wine driver command needed a correction:

```bash
git add scripts/drivers/wine.py scripts/test_wine_patch_chain.py
git commit -m "fix: stabilize unified RA95 patcher migration"
```

If no source changes were needed, do not create an empty commit.

---

## Self-Review

- Spec coverage: the plan creates one utility, adds smart defaults, records manifests, quarantines `game-in-focus`, gates diagnostics, migrates flake and Wine driver callers, updates docs, and verifies Allied/Soviet captures.
- Scope: RA95-only; TD is not touched except existing unrelated lint output may appear during project-wide gates.
- Testing: starts with failing tests, adds implementation in small commits, and ends with unit, Nix build, and Wine capture checks.
- Ambiguity check: normal users run `patch_ra95.py base RA95.EXE` or `patch_ra95.py mission RA95.EXE --scenario SCU01EA.INI`; diagnostics require explicit allow flags.
