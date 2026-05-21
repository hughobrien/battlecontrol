#!/usr/bin/env python3
"""Tests for Wine RA95 patch-chain selection."""

import os
import unittest

from drivers.wine import mission_patch_scripts


class WinePatchChainTest(unittest.TestCase):
    def setUp(self):
        self.old_guard = os.environ.get("WINE_FRAMEINFO_GUARD")
        os.environ.pop("WINE_FRAMEINFO_GUARD", None)

    def tearDown(self):
        if self.old_guard is None:
            os.environ.pop("WINE_FRAMEINFO_GUARD", None)
        else:
            os.environ["WINE_FRAMEINFO_GUARD"] = self.old_guard

    def test_frameinfo_guard_is_opt_in(self):
        patches = mission_patch_scripts(
            skip_vqa=True, scenario="SCU01EA", autostart=True
        )

        self.assertNotIn("ra/ra-frameinfo-send-guard-patch.py", patches)

    def test_frameinfo_guard_can_be_enabled_for_diagnostics(self):
        os.environ["WINE_FRAMEINFO_GUARD"] = "1"

        patches = mission_patch_scripts(
            skip_vqa=True, scenario="SCU01EA", autostart=True
        )

        self.assertIn("ra/ra-frameinfo-send-guard-patch.py", patches)


if __name__ == "__main__":
    unittest.main()
