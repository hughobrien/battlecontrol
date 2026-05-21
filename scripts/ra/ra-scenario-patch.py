#!/usr/bin/env python3
"""
TIM-857 — Replace the hardcoded L1 scenario name in RA95.EXE with a
target mission name so the game loads that scenario directly.

The OG RA95.EXE binary hardcodes "SCG01EA.INI" and "SCU01EA.INI" in
several code paths (RA_AUTOSTART, FACTION dialog, IsFromInstall).
All references are replaced so any path that triggers Set_Scenario_Name
loads the target instead of L1.  Both campaign L1 strings are patched so
the selected autostart side and the target scenario cannot diverge.

The scenario INI data lives in MAIN.MIX as an embedded text block
(confirmed: SCG02EA.INI at MAIN.MIX raw offset 0xF60D4C,
SCU02EA.INI  at MAIN.MIX raw offset 0xF62A14).

Usage:
  python3 scripts/ra-scenario-patch.py RA95.EXE SCG02EA    # Allied M2
  python3 scripts/ra-scenario-patch.py RA95.EXE SCU02EA    # Soviet M2
  python3 scripts/ra-scenario-patch.py RA95.EXE --restore

Accepts a patched RA95.EXE with focus-skip + game-in-focus already
applied (follows the patch chain order from wine-allied-l1.sh).
"""

import argparse
import hashlib
import os
import shutil
import sys


def _warn_deprecated() -> None:
    print(
        "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
        file=sys.stderr,
    )


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, new_scenario: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    new_scenario = new_scenario.upper().strip()
    if not new_scenario.endswith(".INI"):
        new_scenario += ".INI"
    if len(new_scenario) > 12:
        print(f"ERROR: scenario name too long: '{new_scenario}' (max 12 chars)")
        return 1
    new_scenario = new_scenario.ljust(12, "\x00")
    new_bytes = new_scenario.encode("ascii")[:12]

    # Replace both L1 source strings. The autostart patch chooses the side
    # path from the target scenario; replacing both strings keeps the scenario
    # name robust even if an alternate path is reached during capture setup.
    if new_bytes[:2] == b"SC":
        faction = new_bytes[2:3].decode()
        if faction not in ("G", "U"):
            print(f"ERROR: unexpected faction prefix 'SC{faction}'")
            return 1
    else:
        print(
            f"ERROR: scenario must start with 'SCG' or 'SCU', got '{new_scenario.strip()}'"
        )
        return 1

    occurrence_count = 0
    replaced_sources = []
    for source_str in (b"SCG01EA.INI\x00", b"SCU01EA.INI\x00"):
        source_count = 0
        offset = 0
        while True:
            offset = data.find(source_str, offset)
            if offset < 0:
                break
            data[offset : offset + 12] = new_bytes
            occurrence_count += 1
            source_count += 1
            offset += 1
        if source_count:
            replaced_sources.append(
                f"{source_str.decode('ascii').rstrip(chr(0))} ({source_count})"
            )

    if occurrence_count == 0:
        print(f"ERROR: could not find SCG01EA.INI or SCU01EA.INI in {path}")
        print(f"  SHA-256: {sha256(bytes(data))[:16]}...")
        return 1

    backup = path + ".scenario_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    new_label = new_bytes.decode("ascii").rstrip("\x00")
    old_label = ", ".join(replaced_sources)
    print(f"{path}: scenario patch applied: {old_label} -> {new_label}")
    print(
        f"  replaced {occurrence_count} occurrence(s), new SHA-256: {out_digest[:16]}..."
    )
    return 0


def restore(path: str) -> int:
    backup = path + ".scenario_orig"
    if not os.path.exists(backup):
        print(f"ERROR: no backup found at {backup}")
        return 1
    shutil.copy2(backup, path)
    print(f"{path}: restored from {backup}")
    return 0


def main() -> int:
    _warn_deprecated()
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("exe_path", help="Path to RA95.EXE")
    ap.add_argument(
        "scenario",
        nargs="?",
        default=None,
        help="Target scenario name (e.g. SCG02EA, SCU02EA)",
    )
    ap.add_argument(
        "--restore", action="store_true", help="Restore from .scenario_orig backup"
    )
    args = ap.parse_args()

    if args.restore:
        return restore(args.exe_path)
    if not args.scenario:
        print("ERROR: specify a scenario name or --restore")
        return 1
    return patch(args.exe_path, args.scenario)


if __name__ == "__main__":
    sys.exit(main())
