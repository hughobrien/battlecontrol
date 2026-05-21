#!/usr/bin/env python3
"""Tests for the unified RA95 patcher registry and mode selection."""

import json
import tempfile
import unittest
from pathlib import Path

from ra.patch_ra95 import (
    ByteEdit,
    DEFAULT_RANDOM_SEED,
    PatchError,
    apply_mode,
    infer_side,
    mode_patch_ids,
    patch_registry,
    va_to_file_offset,
)


class RA95PatcherRegistryTest(unittest.TestCase):
    def test_base_mode_uses_default_base_patch_sequence(self):
        self.assertEqual(mode_patch_ids("base"), ["nocd", "ddscl-normal", "cd-label"])

    def test_mission_mode_has_smart_defaults(self):
        ids = mode_patch_ids("mission", scenario="SCU01EA.INI", seed=0x1EED5EED)

        self.assertIn("focus-wait-skip", ids)
        self.assertIn("vqa-skip", ids)
        self.assertIn("briefing-skip", ids)
        self.assertIn("cd-label", ids)
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

    def test_explicit_placeholder_patch_cannot_noop(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            exe.write_bytes(b"\x00" * 16)

            with self.assertRaisesRegex(PatchError, "game-in-focus: .*quarantined.*non-applicable"):
                apply_mode(
                    "base",
                    exe,
                    patches=["game-in-focus"],
                    allow_quarantined=True,
                )

    def test_byte_edit_requires_equal_length_replacement(self):
        with self.assertRaisesRegex(ValueError, "expected and replacement must have equal length"):
            ByteEdit(
                offset=0,
                expected=b"\x75\xdd",
                replacement=b"\x90",
                label="invalid edit",
            )

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

    def test_dynamic_patches_are_idempotent(self):
        scenario_offset = 0x1000
        soviet_scenario_offset = 0x1020
        seed_offset = va_to_file_offset(0x004FF345)
        seed_expected = bytes.fromhex("31c0e8856d0b00e8dd6d0b00e8b46d0b00")
        cd1_offset = 0x1BFCB7
        cd2_offset = cd1_offset + 4
        data = bytearray(b"\x00" * 0x200000)
        data[scenario_offset : scenario_offset + 12] = b"SCG01EA.INI\x00"
        data[soviet_scenario_offset : soviet_scenario_offset + 12] = b"SCU01EA.INI\x00"
        data[seed_offset : seed_offset + len(seed_expected)] = seed_expected
        data[cd1_offset : cd1_offset + 1] = b"C"
        data[cd2_offset : cd2_offset + 1] = b"C"

        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            exe.write_bytes(data)

            first = apply_mode(
                "mission",
                exe,
                scenario="SCU02EA.INI",
                seed=DEFAULT_RANDOM_SEED,
                patches=["cd-label", "scenario", "random-seed"],
            )
            second = apply_mode(
                "mission",
                exe,
                scenario="SCU02EA.INI",
                seed=DEFAULT_RANDOM_SEED,
                patches=["cd-label", "scenario", "random-seed"],
            )

            first_edits = {
                patch["id"]: [edit["result"] for edit in patch["edits"]]
                for patch in first.manifest["patches"]
            }
            second_edits = {
                patch["id"]: [edit["result"] for edit in patch["edits"]]
                for patch in second.manifest["patches"]
            }
            self.assertEqual(first_edits["cd-label"], ["already-applied", "applied"])
            self.assertEqual(first_edits["scenario"], ["applied", "applied"])
            self.assertEqual(first_edits["random-seed"], ["applied"])
            self.assertEqual(second_edits["cd-label"], ["already-applied", "already-applied"])
            self.assertEqual(second_edits["scenario"], ["already-applied", "already-applied"])
            self.assertEqual(second_edits["random-seed"], ["already-applied"])

    def test_explicit_cd_label_patch_honors_side(self):
        cd1_offset = 0x1BFCB7
        cd2_offset = cd1_offset + 4
        data = bytearray(b"\x00" * (cd2_offset + 1))
        data[cd1_offset : cd1_offset + 1] = b"C"
        data[cd2_offset : cd2_offset + 1] = b"C"

        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / "RA95.EXE"
            manifest = Path(tmp) / "patches.json"
            exe.write_bytes(data)

            apply_mode(
                "apply",
                exe,
                patches=["cd-label"],
                side="soviet",
                manifest_path=manifest,
            )

            patched = exe.read_bytes()
            recorded = json.loads(manifest.read_text())
            self.assertEqual(patched[cd1_offset : cd1_offset + 1], b"C")
            self.assertEqual(patched[cd2_offset : cd2_offset + 1], b"\x00")
            self.assertEqual(recorded["side"], "soviet")


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

    def test_module_help_imports(self):
        import subprocess

        result = subprocess.run(
            ["python3", "-m", "scripts.ra.patch_ra95", "--help"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("base", result.stdout)
        self.assertIn("mission", result.stdout)


if __name__ == "__main__":
    unittest.main()
