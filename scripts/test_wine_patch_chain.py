#!/usr/bin/env python3
"""Tests for Wine RA95 unified patcher command selection."""

import os
import tempfile
import unittest
from unittest import mock

from drivers import wine
from drivers.wine import WineCapture, base_patch_command, mission_patch_command


class WinePatchCommandTest(unittest.TestCase):
    def setUp(self):
        self.old_guard = os.environ.get("WINE_FRAMEINFO_GUARD")
        self.old_force_normal = os.environ.get("WINE_FORCE_NORMAL_QUEUE")
        os.environ.pop("WINE_FRAMEINFO_GUARD", None)
        os.environ.pop("WINE_FORCE_NORMAL_QUEUE", None)

    def tearDown(self):
        if self.old_guard is None:
            os.environ.pop("WINE_FRAMEINFO_GUARD", None)
        else:
            os.environ["WINE_FRAMEINFO_GUARD"] = self.old_guard
        if self.old_force_normal is None:
            os.environ.pop("WINE_FORCE_NORMAL_QUEUE", None)
        else:
            os.environ["WINE_FORCE_NORMAL_QUEUE"] = self.old_force_normal

    def test_uses_unified_patcher_for_mission_capture(self):
        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest="wine-patches.json",
        )

        self.assertEqual(
            command[:4],
            ["python3", "scripts/ra/patch_ra95.py", "mission", "RA95.EXE"],
        )
        self.assertIn("--scenario", command)
        self.assertIn("SCU01EA.INI", command)
        self.assertIn("--manifest", command)
        self.assertIn(str(wine.pathlib.Path("wine-patches.json").resolve()), command)
        self.assertIn("--no-seed", command)
        self.assertNotIn("--diagnostic", command)
        self.assertNotIn("--allow-diagnostic", command)

    def test_mission_patch_command_resolves_relative_manifest_path(self):
        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest_path=wine.pathlib.Path("relative.json"),
        )

        manifest_index = command.index("--manifest") + 1
        self.assertEqual(
            command[manifest_index],
            str(wine.pathlib.Path("relative.json").resolve()),
        )

    def test_base_patch_command_uses_unified_base_mode(self):
        command = base_patch_command(
            exe="RA95.EXE",
            manifest_path=wine.pathlib.Path("relative.json"),
        )

        self.assertEqual(
            command[:4],
            ["python3", "scripts/ra/patch_ra95.py", "base", "RA95.EXE"],
        )
        self.assertNotIn("mission", command)
        self.assertNotIn("--scenario", command)
        self.assertNotIn("--seed", command)
        self.assertNotIn("--no-seed", command)
        manifest_index = command.index("--manifest") + 1
        self.assertEqual(
            command[manifest_index],
            str(wine.pathlib.Path("relative.json").resolve()),
        )

    def test_passes_random_seed_as_hex(self):
        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest="wine-patches.json",
            random_seed=0x1EED5EED,
        )

        self.assertIn("--seed", command)
        self.assertIn("0x1eed5eed", command)
        self.assertNotIn("--no-seed", command)

    def test_can_preserve_vqa_playback(self):
        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest="wine-patches.json",
            skip_vqa=False,
        )

        self.assertIn("--no-vqa-skip", command)

    def test_frameinfo_guard_can_be_enabled_for_diagnostics(self):
        os.environ["WINE_FRAMEINFO_GUARD"] = "1"

        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest="wine-patches.json",
        )

        self.assertIn("--diagnostic", command)
        self.assertIn("frameinfo-send-guard", command)
        self.assertIn("--allow-diagnostic", command)

    def test_force_normal_queue_can_be_enabled_for_diagnostics(self):
        os.environ["WINE_FORCE_NORMAL_QUEUE"] = "1"

        command = mission_patch_command(
            exe="RA95.EXE",
            scenario="SCU01EA.INI",
            manifest="wine-patches.json",
        )

        self.assertIn("--diagnostic", command)
        self.assertIn("force-normal-queue", command)
        self.assertIn("--allow-diagnostic", command)

    def test_old_patch_script_chain_helper_is_removed(self):
        self.assertFalse(hasattr(wine, "mission_patch_scripts"))

    def test_patch_failure_reports_stdout_and_stderr(self):
        capture = WineCapture.__new__(WineCapture)
        capture.scripts_dir = wine.pathlib.Path("scripts")
        capture.random_seed = None

        result = mock.Mock()
        result.returncode = 1
        result.stdout = "stdout details"
        result.stderr = "stderr details"

        with mock.patch.object(wine.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as raised:
                capture._patch_chain(
                    wine.pathlib.Path("RA95.EXE"),
                    scenario="SCU01EA.INI",
                    manifest_path=wine.pathlib.Path("wine-patches.json"),
                )

        message = str(raised.exception)
        self.assertIn("STDOUT:\nstdout details", message)
        self.assertIn("STDERR:\nstderr details", message)

    def test_patch_chain_uses_base_mode_without_scenario(self):
        capture = WineCapture.__new__(WineCapture)
        capture.scripts_dir = wine.pathlib.Path("scripts")
        capture.random_seed = 0x1EED5EED

        result = mock.Mock()
        result.returncode = 0
        result.stdout = ""
        result.stderr = ""

        with tempfile.TemporaryDirectory() as tmp:
            exe = wine.pathlib.Path(tmp) / "RA95.EXE"
            exe.write_bytes(b"")
            with mock.patch.object(wine.subprocess, "run", return_value=result) as run:
                capture._patch_chain(
                    exe,
                    scenario=None,
                    manifest_path=wine.pathlib.Path("relative.json"),
                )
            self.assertFalse((exe.parent / "RA_RANDOM_SEED.txt").exists())

        command = run.call_args.args[0]
        self.assertEqual(
            command[:4],
            ["python3", "scripts/ra/patch_ra95.py", "base", str(exe)],
        )
        self.assertNotIn("mission", command)
        self.assertNotIn("--scenario", command)
        self.assertNotIn("--seed", command)
        self.assertNotIn("--no-seed", command)


if __name__ == "__main__":
    unittest.main()
