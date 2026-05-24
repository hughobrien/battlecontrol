#!/usr/bin/env python3
"""Tests for native capture driver helpers."""

import pathlib
import tempfile
import unittest

from drivers.native import capture_timeout_seconds, stage_data_dir


class NativeDriverTest(unittest.TestCase):
    def test_stage_data_dir_creates_writable_directory_with_data_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            data_dir = root / "data"
            data_dir.mkdir()
            (data_dir / "REDALERT.MIX").write_text("redalert")
            (data_dir / "MAIN.MIX").write_text("main")

            staged = stage_data_dir(data_dir, root)
            (staged / "REDALERT.INI").write_text("[Options]\n")

            self.assertTrue(staged.is_dir())
            self.assertTrue((staged / "REDALERT.MIX").is_symlink())
            self.assertEqual((staged / "MAIN.MIX").read_text(), "main")
            self.assertEqual((staged / "REDALERT.INI").read_text(), "[Options]\n")

    def test_stage_data_dir_overlays_soviet_data_on_base_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            base_dir = root / "cd1"
            soviet_dir = root / "cd2"
            base_dir.mkdir()
            soviet_dir.mkdir()
            (base_dir / "REDALERT.INI").write_text("[Intro]\nPlayIntro=no\n")
            (base_dir / "EXPAND.MIX").write_text("expand")
            (base_dir / "MAIN.MIX").write_text("cd1-main")
            (soviet_dir / "MAIN.MIX").write_text("cd2-main")

            staged = stage_data_dir(soviet_dir, root, base_dir)

            self.assertEqual(
                (staged / "REDALERT.INI").read_text(), "[Intro]\nPlayIntro=no\n"
            )
            self.assertEqual((staged / "EXPAND.MIX").read_text(), "expand")
            self.assertEqual((staged / "MAIN.MIX").read_text(), "cd2-main")

    def test_capture_timeout_scales_with_requested_frame(self):
        self.assertEqual(capture_timeout_seconds(frame=1, fps=10), 45)
        self.assertEqual(capture_timeout_seconds(frame=500, fps=10), 130)


if __name__ == "__main__":
    unittest.main()
