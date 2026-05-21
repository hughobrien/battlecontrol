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
            purpose="Select effective Allied/Soviet disc label for capture.",
            status="capture-only",
            default_allowed=True,
        ),
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
            edits=(
                ByteEdit(0x0A53C4, bytes.fromhex("55"), bytes.fromhex("c3"), "Play_Movie prologue -> RET"),
            ),
        ),
        "briefing-skip": PatchSpec(
            id="briefing-skip",
            purpose="Skip text mission briefing dialog.",
            status="capture-only",
            default_allowed=True,
            edits=(
                ByteEdit(
                    va_to_file_offset(0x00542E96),
                    bytes.fromhex("e8a1110000"),
                    bytes.fromhex("9090909090"),
                    "Restate_Mission call -> NOP",
                    va=0x00542E96,
                ),
            ),
        ),
        "autostart": PatchSpec(
            id="autostart",
            purpose="Enter the selected mission directly at Normal difficulty.",
            status="capture-only",
            default_allowed=True,
            edits=(
                ByteEdit(
                    va_to_file_offset(0x004FD00E),
                    bytes.fromhex("f6050c5d650004"),
                    bytes.fromhex("800d0c5d650004"),
                    "set Special.IsFromInstall",
                    va=0x004FD00E,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FD4F5),
                    bytes.fromhex("803db8b66600007507"),
                    bytes.fromhex("c605b8b66600009090"),
                    "Session.Type = GAME_NORMAL",
                    va=0x004FD4F5,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FD4FE),
                    bytes.fromhex("be08000000"),
                    bytes.fromhex("be01000000"),
                    "SEL_NONE -> SEL_START_NEW_GAME",
                    va=0x004FD4FE,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FD505),
                    bytes.fromhex("be04000000"),
                    bytes.fromhex("be01000000"),
                    "SEL_MULTIPLAYER -> SEL_START_NEW_GAME",
                    va=0x004FD505,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FD7A5),
                    bytes.fromhex("7436"),
                    bytes.fromhex("eb36"),
                    "skip pending external/network game branch",
                    va=0x004FD7A5,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FDC67),
                    bytes.fromhex("7468"),
                    bytes.fromhex("9090"),
                    "skip Fetch_Difficulty",
                    va=0x004FDC67,
                ),
                ByteEdit(
                    va_to_file_offset(0x004FDD10),
                    bytes.fromhex("755d"),
                    bytes.fromhex("eb5d"),
                    "skip faction dialog",
                    va=0x004FDD10,
                ),
            ),
        ),
        "scenario": PatchSpec(
            id="scenario",
            purpose="Replace hardcoded L1 scenario strings.",
            status="capture-only",
            default_allowed=True,
        ),
        "random-seed": PatchSpec(
            id="random-seed",
            purpose="Use a fixed gameplay random seed.",
            status="capture-only",
            default_allowed=True,
        ),
        "frameinfo-send-guard": PatchSpec(
            id="frameinfo-send-guard",
            purpose="Diagnostic: suppress malformed frameinfo send path.",
            status="diagnostic",
            default_allowed=False,
            requires_allow_diagnostic=True,
            edits=(
                ByteEdit(
                    va_to_file_offset(0x00533AF5),
                    bytes.fromhex("e862070000"),
                    bytes.fromhex("31c0909090"),
                    "frameinfo builder",
                    va=0x00533AF5,
                ),
                ByteEdit(
                    va_to_file_offset(0x00533AFA),
                    bytes.fromhex("6aff"),
                    bytes.fromhex("9090"),
                    "frameinfo send push",
                    va=0x00533AFA,
                ),
                ByteEdit(
                    va_to_file_offset(0x00533B0D),
                    bytes.fromhex("ff5708"),
                    bytes.fromhex("909090"),
                    "frameinfo send call",
                    va=0x00533B0D,
                ),
            ),
        ),
        "force-normal-queue": PatchSpec(
            id="force-normal-queue",
            purpose="Diagnostic: force Queue_AI to dispatch as GAME_NORMAL.",
            status="diagnostic",
            default_allowed=False,
            requires_allow_diagnostic=True,
            edits=(
                ByteEdit(
                    va_to_file_offset(0x005329A3),
                    bytes.fromhex("a0b8b66600"),
                    bytes.fromhex("31c0909090"),
                    "Queue_AI Session.Type read -> GAME_NORMAL",
                    va=0x005329A3,
                ),
            ),
        ),
        "game-in-focus": PatchSpec(
            id="game-in-focus",
            purpose="Quarantined: confirmed bad Session.Type write previously mislabeled as GameInFocus.",
            status="quarantined",
            default_allowed=False,
            requires_allow_quarantined=True,
        ),
    }


def _find_all(data: bytearray, needle: bytes) -> list[int]:
    offsets: list[int] = []
    offset = 0
    while True:
        offset = data.find(needle, offset)
        if offset < 0:
            return offsets
        offsets.append(offset)
        offset += len(needle)


def _scenario_edits(data: bytearray, scenario: str) -> list[dict]:
    normalized = normalize_scenario(scenario).ljust(12, "\x00").encode("ascii")[:12]
    source_strings = (b"SCG01EA.INI\x00", b"SCU01EA.INI\x00")
    offsets = set()
    for source in source_strings:
        offsets.update(_find_all(data, source))
    offsets.update(_find_all(data, normalized))

    edits: list[dict] = []
    for offset in sorted(offsets):
        actual = bytes(data[offset : offset + 12])
        if actual == normalized:
            result = "already-applied"
        elif actual in source_strings:
            data[offset : offset + 12] = normalized
            result = "applied"
        else:
            continue
        edits.append(
            {
                "offset": f"0x{offset:08x}",
                "va": None,
                "expected": "|".join(source.hex() for source in source_strings),
                "replacement": normalized.hex(),
                "actual": actual.hex(),
                "result": result,
                "label": "scenario string replacement",
            }
        )
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
    if side not in {"allied", "soviet"}:
        raise PatchError(f"cd-label: unknown side {side!r}")

    cd1_offset = 0x1BFCB7
    cd2_offset = cd1_offset + 4
    replacements = {
        "allied": (
            (cd1_offset, b"\x00", "CD1 label first byte"),
            (cd2_offset, b"C", "CD2 label first byte"),
        ),
        "soviet": (
            (cd1_offset, b"C", "CD1 label first byte"),
            (cd2_offset, b"\x00", "CD2 label first byte"),
        ),
    }[side]
    edits: list[dict] = []
    for offset, replacement, label in replacements:
        actual = bytes(data[offset : offset + 1])
        if actual not in {b"C", b"\x00"}:
            raise PatchError(
                f"cd-label: unexpected bytes at 0x{offset:08x}: "
                f"expected 43 or 00, got {actual.hex() or '<eof>'}"
            )
        data[offset : offset + 1] = replacement
        edits.append(
            {
                "offset": f"0x{offset:08x}",
                "va": None,
                "expected": "43|00",
                "replacement": replacement.hex(),
                "actual": actual.hex(),
                "result": "already-applied" if actual == replacement else "applied",
                "label": label,
            }
        )
    return edits


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
    if side is not None and side not in {"allied", "soviet"}:
        raise PatchError(f"unknown RA95 side: {side!r}")
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
        elif patch_id == "game-in-focus":
            raise PatchError("game-in-focus: quarantined patch is non-applicable in unified patcher")
        else:
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
