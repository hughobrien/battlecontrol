#!/usr/bin/env python3
"""Tests for capture preflight checks."""

import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock


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


if __name__ == "__main__":
    unittest.main()
