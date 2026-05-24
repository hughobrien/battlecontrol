#!/usr/bin/env python3
"""Contracts for the RA retail/remaster behavior build switch."""

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class RABehaviorModeTest(unittest.TestCase):
    def test_cmake_exposes_retail_default_and_remaster_define(self) -> None:
        cmake = (REPO_ROOT / "CMakeLists.txt").read_text()
        self.assertIn('set(RA_BEHAVIOR "retail"', cmake)
        self.assertIn("PROPERTY STRINGS original retail remaster", cmake)
        self.assertIn("RA_REMASTER_BEHAVIOR=1", cmake)

    def test_drive_zone_check_is_guarded_by_remaster_define(self) -> None:
        drive = (REPO_ROOT / "REDALERT" / "DRIVE.CPP").read_text()
        self.assertIn("#ifdef RA_REMASTER_BEHAVIOR", drive)
        self.assertIn("should_validate_destination_zone = !Team;", drive)
        self.assertIn("should_validate_destination_zone)", drive)

    def test_nearby_location_phase_is_guarded_by_remaster_define(self) -> None:
        map_cpp = (REPO_ROOT / "REDALERT" / "MAP.CPP").read_text()
        self.assertIn("#ifdef RA_REMASTER_BEHAVIOR", map_cpp)
        self.assertIn("return(topten[(Frame+locationmod) % count]);", map_cpp)
        self.assertIn("return(topten[(Frame+locationmod+1) % count]);", map_cpp)

    def test_presets_include_remaster_builds(self) -> None:
        presets = (REPO_ROOT / "CMakePresets.json").read_text()
        self.assertIn('"name": "linux-native-remaster"', presets)
        self.assertIn('"name": "mingw32-remaster"', presets)
        self.assertIn('"RA_BEHAVIOR": "remaster"', presets)


if __name__ == "__main__":
    unittest.main()
