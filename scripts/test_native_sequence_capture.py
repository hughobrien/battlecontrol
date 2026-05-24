#!/usr/bin/env python3
"""Regression checks for the native sequence capture harness."""

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "capture-native-sequence.py"


class NativeSequenceCaptureTest(unittest.TestCase):
    def test_sequence_harness_uses_native_driver_and_hash_report(self):
        text = SCRIPT.read_text()

        self.assertIn("NativeCapture", text)
        self.assertIn("native-sequence-report.json", text)
        self.assertIn("RA_CAPTURE_SEQUENCE_DIR", text)
        self.assertIn("RA_CAPTURE_SEQUENCE_START", text)
        self.assertIn("RA_CAPTURE_SEQUENCE_COUNT", text)
        self.assertIn("sha256_rgba", text)
        self.assertIn("--fps", text)
        self.assertIn('default="60"', text)
        self.assertIn("default=50", text)

    def test_native_source_defines_sequence_capture_controls(self):
        conquer = (REPO_ROOT / "REDALERT" / "CONQUER.CPP").read_text()
        init = (REPO_ROOT / "REDALERT" / "INIT.CPP").read_text()

        self.assertIn("RA_CAPTURE_SEQUENCE_DIR", conquer)
        self.assertIn("RA_CAPTURE_SEQUENCE_START", conquer)
        self.assertIn("RA_CAPTURE_SEQUENCE_COUNT", conquer)
        self.assertIn("RA_Save_Gameplay_BMP_Path", conquer)
        self.assertIn("RA_Deterministic_Color_Cycle", conquer)
        self.assertIn("RA_RANDOM_SEED", init)
        self.assertIn("RA_AUTOSTART_GAMESPEED", init)


if __name__ == "__main__":
    unittest.main()
