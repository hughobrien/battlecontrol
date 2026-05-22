#!/usr/bin/env python3
"""Regression checks for the frame-sequence parity workflow skill."""

import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILL = REPO_ROOT / "skills" / "frame-sequence-parity" / "SKILL.md"
AGENTS = REPO_ROOT / "AGENTS.md"


class FrameSequenceParitySkillTest(unittest.TestCase):
    def test_skill_captures_reproducible_sequence_workflow(self):
        text = SKILL.read_text()

        self.assertIn("capture-wine-sequence.py", text)
        self.assertIn("capture-native-sequence.py", text)
        self.assertIn("compare-frame-sequences.py", text)
        self.assertIn("RA-clock", text)
        self.assertIn("frames `50..149`", text)
        self.assertIn("100/100", text)
        self.assertIn("native `wine+2`", text)
        self.assertIn("python3 -m http.server 1234", text)

    def test_agents_indexes_skill(self):
        text = AGENTS.read_text()

        self.assertIn("Frame sequence parity", text)
        self.assertIn("skills/frame-sequence-parity/", text)
        self.assertIn("compare-frame-sequences.py", text)


if __name__ == "__main__":
    unittest.main()
