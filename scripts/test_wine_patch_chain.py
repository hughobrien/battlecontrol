#!/usr/bin/env python3
"""Tests for Wine RA95 unified patcher command selection."""

import os
import unittest

from drivers.wine import mission_patch_command


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
        self.assertIn("wine-patches.json", command)
        self.assertIn("--no-seed", command)
        self.assertNotIn("--diagnostic", command)
        self.assertNotIn("--allow-diagnostic", command)

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


if __name__ == "__main__":
    unittest.main()
