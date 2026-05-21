#!/usr/bin/env python3
"""Declarative RA95.EXE patch registry and byte patching engine."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
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

    def __post_init__(self) -> None:
        if len(self.expected) != len(self.replacement):
            raise ValueError("expected and replacement must have equal length")


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
        "frameinfo-send-guard": PatchSpec(
            id="frameinfo-send-guard",
            purpose="Diagnostic frame-info SendInput guard.",
            status="diagnostic",
            requires_allow_diagnostic=True,
        ),
        "force-normal-queue": PatchSpec(
            id="force-normal-queue",
            purpose="Diagnostic normal-queue forcing patch.",
            status="diagnostic",
            requires_allow_diagnostic=True,
        ),
        "game-in-focus": PatchSpec(
            id="game-in-focus",
            purpose="Quarantined game focus override.",
            status="quarantined",
            requires_allow_quarantined=True,
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
        ids.extend(["cd-label", "scenario", "autostart"])
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
    if not spec.edits:
        raise PatchError(f"{spec.id}: patch has no registered edits")

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
    selected = (
        list(patches)
        if patches is not None
        else mode_patch_ids(
            mode,
            scenario=scenario,
            seed=seed,
            skip_vqa=skip_vqa,
            skip_briefing=skip_briefing,
        )
    )

    patch_entries = []
    for patch_id in selected:
        try:
            spec = registry[patch_id]
        except KeyError as exc:
            raise PatchError(f"unknown RA95 patch id: {patch_id}") from exc
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
