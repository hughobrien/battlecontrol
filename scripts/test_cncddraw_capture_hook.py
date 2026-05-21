#!/usr/bin/env python3
"""Regression checks for the local cnc-ddraw capture hook."""

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
PATCH = REPO_ROOT / "tools" / "cnc-ddraw" / "tim780-capture-hook.patch"
FLAKE = REPO_ROOT / "flake.nix"
WINE_DRIVER = REPO_ROOT / "scripts" / "drivers" / "wine.py"
WINE_SEQUENCE = REPO_ROOT / "scripts" / "capture-wine-sequence.py"


class CncDdrawCaptureHookTest(unittest.TestCase):
    def test_patch_defines_deterministic_capture_controls(self):
        text = PATCH.read_text()

        self.assertIn("src/render_gdi.c", text)
        self.assertIn("src/screenshot.c", text)
        self.assertIn("BC_CAPTURE_FLIP", text)
        self.assertIn("BC_CAPTURE_FILE", text)
        self.assertIn("BC_CAPTURE_START", text)
        self.assertIn("BC_CAPTURE_RA_START", text)
        self.assertIn("BC_CAPTURE_COUNT", text)
        self.assertIn("BC_CAPTURE_DIR", text)
        self.assertIn("BC_CAPTURE_HALT", text)
        self.assertIn("BC_CAPTURE_RA_FRAME_ADDR", text)
        self.assertIn("ss_take_screenshot_file", text)
        self.assertIn("Sleep(100)", text)

    def test_flake_applies_capture_hook_after_scanline_patch(self):
        text = FLAKE.read_text()

        self.assertIn("tim740-scanline-double.patch", text)
        self.assertIn("tim780-capture-hook.patch", text)
        self.assertLess(
            text.index("tim740-scanline-double.patch"),
            text.index("tim780-capture-hook.patch"),
        )

    def test_wine_driver_enables_cncddraw_capture_when_requested(self):
        text = WINE_DRIVER.read_text()

        self.assertIn("WINE_CNCDDRAW_CAPTURE", text)
        self.assertIn("BC_CAPTURE_FLIP", text)
        self.assertIn("BC_CAPTURE_FILE", text)
        self.assertIn("BC_CAPTURE_COUNT", text)
        self.assertIn("BC_CAPTURE_DIR", text)
        self.assertIn("WINE_CNCDDRAW_CAPTURE_RA_START", text)
        self.assertIn("BC_CAPTURE_RA_FRAME_ADDR", text)
        self.assertIn("wine-cncddraw.png", text)
        self.assertIn("wine-sequence", text)

    def test_sequence_harness_reports_frame_hashes(self):
        text = WINE_SEQUENCE.read_text()

        self.assertIn("capture_mission_sequence", text)
        self.assertIn("wine-sequence-report.json", text)
        self.assertIn("sha256", text)
        self.assertIn("sha256_rgba", text)
        self.assertIn("--count", text)
        self.assertIn("--clock", text)


if __name__ == "__main__":
    unittest.main()
