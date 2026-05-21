#!/usr/bin/env python3
"""Tests for capture preflight checks."""

import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from PIL import Image, ImageDraw


SCRIPT = pathlib.Path(__file__).parent / "drivers" / "common.py"


def load_common():
    spec = importlib.util.spec_from_file_location("drivers_common", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CapturePreflightTest(unittest.TestCase):
    def setUp(self):
        self.old_min = os.environ.get("RA_MIN_TMP_FREE_MB")
        os.environ.pop("RA_MIN_TMP_FREE_MB", None)
        self.common = load_common()

    def tearDown(self):
        if self.old_min is None:
            os.environ.pop("RA_MIN_TMP_FREE_MB", None)
        else:
            os.environ["RA_MIN_TMP_FREE_MB"] = self.old_min

    def test_default_free_space_floor_prevents_ra95_low_disk_dialog(self):
        usage = mock.Mock(free=3 * 1024 * 1024 * 1024)

        with mock.patch.object(self.common.shutil, "disk_usage", return_value=usage):
            with self.assertRaisesRegex(
                self.common.PreflightError, "RA95 may show.*low-disk warning"
            ):
                self.common.check_tmp_free_space("/tmp")

    def test_sweep_state_removes_generated_wine_cache_dirs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            stale_prefix = root / "wine-prefix-old"
            stale_capture = root / "wine-capture-old"
            keep = root / "ra-frameprobe.exe"
            stale_prefix.mkdir()
            stale_capture.mkdir()
            keep.write_text("keep")

            with (
                mock.patch.object(self.common, "_CACHE_DIR", str(root)),
                mock.patch.object(self.common, "_kill_capture_orphans", return_value=0),
                mock.patch.object(self.common, "_SWEEP_DISPLAY_RANGE", range(0)),
            ):
                dirs_removed, locks_removed, procs_killed, files_removed = (
                    self.common.sweep_state()
                )

            self.assertEqual(dirs_removed, 2)
            self.assertEqual(locks_removed, 0)
            self.assertEqual(procs_killed, 0)
            self.assertEqual(files_removed, 0)
            self.assertFalse(stale_prefix.exists())
            self.assertFalse(stale_capture.exists())
            self.assertTrue(keep.exists())

    def test_classifies_all_white_transition_as_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            screenshot = pathlib.Path(tmp) / "white.png"
            Image.new("RGB", (640, 400), (255, 255, 255)).save(screenshot)

            screen = self.common.classify_ra_screen(str(screenshot))

            self.assertEqual(screen["state"], "unknown")

    def test_classifies_windows_application_error_dialog(self):
        with tempfile.TemporaryDirectory() as tmp:
            screenshot = pathlib.Path(tmp) / "error-dialog.png"
            image = Image.new("RGB", (640, 400), (0, 0, 0))
            draw = ImageDraw.Draw(image)
            draw.rectangle((480, 16, 639, 176), fill=(140, 0, 0))
            draw.rectangle((150, 132, 487, 275), fill=(245, 245, 245))
            draw.rectangle((150, 132, 487, 156), fill=(84, 125, 177))
            draw.rectangle((153, 157, 484, 272), outline=(90, 90, 90))
            draw.ellipse((170, 180, 202, 212), fill=(230, 45, 45))
            image.save(screenshot)

            screen = self.common.classify_ra_screen(str(screenshot))

            self.assertEqual(screen["state"], "error-dialog")


if __name__ == "__main__":
    unittest.main()
