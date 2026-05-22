#!/usr/bin/env python3
"""Regression checks for frame-sequence alignment reports."""

import json
import pathlib
import subprocess
import tempfile
import unittest

from PIL import Image

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "compare-frame-sequences.py"


def write_frame(directory: pathlib.Path, frame: int, value: int) -> None:
    image = Image.new("RGB", (4, 4), (value, value, value))
    image.save(directory / f"frame_{frame:06d}.png")


class CompareFrameSequencesTest(unittest.TestCase):
    def test_reports_best_offset_and_sample_diff(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            a_dir = root / "a"
            b_dir = root / "b"
            out_dir = root / "out"
            a_dir.mkdir()
            b_dir.mkdir()
            for frame in range(10, 15):
                write_frame(a_dir, frame, frame)
                write_frame(b_dir, frame + 2, frame)

            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--a",
                    str(a_dir),
                    "--b",
                    str(b_dir),
                    "--offset-min",
                    "-3",
                    "--offset-max",
                    "3",
                    "--out",
                    str(out_dir),
                    "--sample-frames",
                    "10,12",
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(
                (out_dir / "sequence-alignment-report.json").read_text()
            )
            self.assertEqual(report["best_offset"], 2)
            self.assertEqual(report["offsets"]["2"]["frames_compared"], 5)
            self.assertEqual(report["offsets"]["2"]["avg_mean_abs_channel_delta"], 0.0)
            self.assertTrue((out_dir / "diff-a000010-b000012.png").exists())
            self.assertIn("best_offset=2", result.stdout)


if __name__ == "__main__":
    unittest.main()
