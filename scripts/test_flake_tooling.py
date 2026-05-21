#!/usr/bin/env python3
"""Regression checks for flake developer-tooling wrappers."""

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
FLAKE = REPO_ROOT / "flake.nix"


class FlakeToolingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flake = FLAKE.read_text()

    def test_developer_apps_supply_their_tool_path(self):
        self.assertIn("appRuntimePath = pkgs.lib.makeBinPath", self.flake)
        self.assertRegex(self.flake, re.compile(r"mkApp = name: script: rec \{"))
        self.assertIn("export PATH=\"${appRuntimePath}:''${PATH:-}\"", self.flake)

    def test_pre_commit_hook_finds_nix_after_login_shell_path_reset(self):
        self.assertIn('NIX_BIN="$(command -v nix || true)"', self.flake)
        self.assertIn("/nix/var/nix/profiles/default/bin/nix", self.flake)
        self.assertIn('"$NIX_BIN" run .#lint', self.flake)
        self.assertNotIn("\n          nix run .#lint\n", self.flake)


if __name__ == "__main__":
    unittest.main()
