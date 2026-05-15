#!/usr/bin/env python3
"""
TIM-699 — Red Alert reference data verification.

Verifies that the game data files match the expected reference checksums
(SHA-256 of the EA/GOG Remastered Collection CD1 data set).  Runs without
Wine or the original EXE — pure file-integrity check.

Usage:
    python3 scripts/ra-data-verify.py [DATA_DIR]
    DATA_DIR defaults to /CnCRemastered/Data/CNCDATA/RED_ALERT/CD1

Exit code 0 = all checks pass.  Exit code 1 = one or more failures.
"""

import configparser
import hashlib
import os
import sys


DATA_DIR_DEFAULT = '/CnCRemastered/Data/CNCDATA/RED_ALERT/CD1'

# SHA-256 of each file in the reference CD1 dataset (Remastered Collection).
# Computed from the EA/GOG release shipped with the CnC Remastered Collection.
REFERENCE_CHECKSUMS: dict[str, str] = {
    'EXPAND.MIX':   'e144753593161f867a26428f901a09de5cb8a71bab6e690dd9ca727e76d4f724',
    'EXPAND2.MIX':  'e379b23ce6c7af9d4f7469e10b788210124cb92e8b6e3978b9569802edfdfc9a',
    'HIRES1.MIX':   '48c407f80f1fdbc86ac2689c00339927b2127a758871e998c9942b7a7d93e07d',
    'LORES1.MIX':   '5b83e8d731fc78041647f19adbb82f4e71cc09b837d2492b8f2a0520e11de641',
    'MAIN.MIX':     '512beab10095f2422498f16ce468fca613bf6bec2a6257bbc18a1d01691d1482',
    'REDALERT.INI': '430e4f14d5bde53c0172fbde14d05d5544e29c60388ba1e22ed71201e7574244',
    'REDALERT.MIX': 'ad5ad68a08d1d6bb073324e91beb02543deeb9e1b8dca922f3cef768dda07b53',
}

# Expected REDALERT.INI key-value pairs (case-insensitive).
# This is the baseline configuration shipped on the Red Alert CD.
EXPECTED_INI: dict[str, dict[str, str]] = {
    'sound':   {'card': '0', 'port': '3f8h', 'irq': '4', 'dma': '-1'},
    'options': {'hardwarefills': 'no', 'videobackbuffer': 'yes'},
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def check_checksums(data_dir: str) -> list[str]:
    errors: list[str] = []
    for filename, expected in REFERENCE_CHECKSUMS.items():
        path = os.path.join(data_dir, filename)
        if not os.path.exists(path):
            errors.append(f'MISSING  {filename}')
            continue
        actual = sha256_file(path)
        if actual == expected:
            size = os.path.getsize(path)
            print(f'  OK      {filename} ({size:,} bytes)')
        else:
            errors.append(
                f'MISMATCH {filename}\n'
                f'          expected {expected}\n'
                f'          actual   {actual}'
            )
    return errors


def check_ini(data_dir: str) -> list[str]:
    errors: list[str] = []
    ini_path = os.path.join(data_dir, 'REDALERT.INI')
    if not os.path.exists(ini_path):
        return [f'MISSING  REDALERT.INI (cannot check INI values)']

    cfg = configparser.RawConfigParser()
    cfg.optionxform = str.lower
    cfg.read(ini_path)

    # Build a case-insensitive section map.
    section_map = {s.lower(): s for s in cfg.sections()}

    for section, kvs in EXPECTED_INI.items():
        actual_section = section_map.get(section.lower())
        if actual_section is None:
            errors.append(f'INI missing section [{section}]')
            continue
        for key, expected_val in kvs.items():
            actual_val = cfg.get(actual_section, key, fallback=None)
            if actual_val is None:
                errors.append(f'INI [{section}] missing key {key!r}')
            elif actual_val.lower() != expected_val.lower():
                errors.append(
                    f'INI [{section}] {key}={actual_val!r}, '
                    f'expected {expected_val!r}'
                )
            else:
                print(f'  OK      INI [{section}] {key}={actual_val!r}')
    return errors


def main() -> int:
    data_dir = sys.argv[1] if len(sys.argv) > 1 else DATA_DIR_DEFAULT

    print(f'Red Alert reference data verification')
    print(f'Data directory: {data_dir}')
    print()

    if not os.path.isdir(data_dir):
        print(f'ERROR: data directory not found: {data_dir}')
        print('Set DATA_DIR or mount the CnC Remastered Collection assets.')
        return 1

    all_errors: list[str] = []

    print('=== MIX file checksums ===')
    all_errors += check_checksums(data_dir)
    print()

    print('=== REDALERT.INI values ===')
    all_errors += check_ini(data_dir)
    print()

    if all_errors:
        print(f'FAIL — {len(all_errors)} error(s):')
        for e in all_errors:
            print(f'  {e}')
        return 1

    print('PASS — all reference data checks OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
