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
        self.assertIn("sha256_rgba", text)
        self.assertIn("--fps", text)
        self.assertIn('default="60"', text)
        self.assertIn("default=50", text)


if __name__ == "__main__":
    unittest.main()
