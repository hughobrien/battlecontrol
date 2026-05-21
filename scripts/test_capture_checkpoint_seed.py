#!/usr/bin/env python3
"""Tests for deterministic capture seed defaults."""

import importlib.util
import os
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).with_name("capture-checkpoint.py")


def load_capture_checkpoint():
    spec = importlib.util.spec_from_file_location("capture_checkpoint", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CaptureCheckpointSeedTest(unittest.TestCase):
    def setUp(self):
        self.old_seed = os.environ.get("RA_RANDOM_SEED")
        os.environ.pop("RA_RANDOM_SEED", None)
        self.capture_checkpoint = load_capture_checkpoint()

    def tearDown(self):
        if self.old_seed is None:
            os.environ.pop("RA_RANDOM_SEED", None)
        else:
            os.environ["RA_RANDOM_SEED"] = self.old_seed

    def test_mission_capture_sets_default_random_seed(self):
        seed = self.capture_checkpoint.apply_default_mission_seed("mission")

        self.assertEqual(seed, self.capture_checkpoint.DEFAULT_RA_RANDOM_SEED)
        self.assertEqual(os.environ["RA_RANDOM_SEED"], seed)

    def test_explicit_random_seed_is_preserved(self):
        os.environ["RA_RANDOM_SEED"] = "0x1234"

        seed = self.capture_checkpoint.apply_default_mission_seed("mission")

        self.assertEqual(seed, "0x1234")
        self.assertEqual(os.environ["RA_RANDOM_SEED"], "0x1234")

    def test_non_mission_capture_does_not_set_seed(self):
        seed = self.capture_checkpoint.apply_default_mission_seed("vqa")

        self.assertIsNone(seed)
        self.assertNotIn("RA_RANDOM_SEED", os.environ)


if __name__ == "__main__":
    unittest.main()
