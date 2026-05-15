#!/usr/bin/env python3
"""
TIM-711 — Tiberian Dawn reference data verification.

Verifies that the game data files match the expected reference checksums
(SHA-256 of the EA/GOG Remastered Collection CD1 data set).  Runs without
Wine or the original EXE — pure file-integrity check.

Usage:
    python3 scripts/td-data-verify.py [DATA_DIR]
    DATA_DIR defaults to /CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1

Exit code 0 = all checks pass.  Exit code 1 = one or more failures.
"""

import hashlib
import os
import sys


DATA_DIR_DEFAULT = '/CnCRemastered/Data/CNCDATA/TIBERIAN_DAWN/CD1'

# SHA-256 of C&C95.EXE after the DDSCL Wine-compatibility patch is applied.
# scripts/wine-td-setup.sh extracts the original from archive.org
# (SHA-256 f606bee19de599daa5ccbc9586d61ee48b8f01f42a4f943196fe30d92a124d30),
# saves it as C&C95.EXE.orig, then patches byte 0x000bc6af from 0x11
# (DDSCL_EXCLUSIVE|FULLSCREEN) to 0x08 (DDSCL_NORMAL) for Wine+Xvfb compat.
# The patched binary is what wine-td.sh actually runs.
CC95_EXE_SHA256 = '3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627'
CC95_EXE_DEFAULT = '/opt/tiberiandawn/C&C95.EXE'

# SHA-256 of each file in the reference CD1 dataset (Remastered Collection).
# Computed from the EA/GOG release shipped with the CnC Remastered Collection.
REFERENCE_CHECKSUMS: dict[str, str] = {
    'AUD.MIX':      '497f410042d5f122e60eb00bb079fb5b490f79ded7fd94a1a4eb85f80fcea2c9',
    'CCLOCAL.MIX':  '6e00e19db8e8061c5eeeb5de6f628d4616f7c97e85d5ae67943df9576b48e61d',
    'CONQUER.MIX':  'b05d7d25eb51e16523088f17292096cf5bb0681946bec1c3e335ffa142817a1f',
    'DESEICNH.MIX': 'f78ee95e8b1144d3b958280b22897ac86e5f6097d766dd31d2c19a99753a39ca',
    'DESERT.MIX':   '0141d371bdb847e085984bca44a0f96cb2f2f410d5eba1410b8e498087954072',
    'GENERAL.MIX':  '99dc619fe04f911dfbe7a7d2c131582ca319785c656f1640a5febd25cd1bbca2',
    'LOCAL.MIX':    '15cc5d98c8f2af1291879d9cd4fb077d84f9e04b8b64239db2d118e1a1fa4a06',
    'MOVIES.MIX':   '0c000a597ac22c3a6942613029e45bc51b011828356e1b1e3153064194d2a65e',
    'SC-000.MIX':   'e4b358312538e42316fe55039b773dc7a3f7e5f230024165a4b9d25760fb2a9a',
    'SC-001.MIX':   '4db08a5dfae0083d916ebc197fe41ade2bb4fdd9ee5e8153868b9efae0ab4d2b',
    'SCORES.MIX':   'dc4519a043bef83f483378e69fa82766611363e5f261227b19fe9454c05af223',
    'SETUP.MIX':    'cdd242ae095fd4164b26c098f3ed10e77fbafec6450f7e3703c711f874dfa244',
    'SOUNDS.MIX':   '37dc88345e68a5514722210bef0a87d6eaf9434be8ec64bb970d03ac521df5a8',
    'SPEECH.MIX':   '4d5e730df355fed1420e85355abf18d1ef04f4015a45d9773c44e2b11e63e71d',
    'TEMPERAT.MIX': '25b41e31ea7fddc34fa18d9561ca9807b9d0124ff7340e8f3a107461d041ce81',
    'TEMPICNH.MIX': '762e1195e23fd4c4876886d54e56fdb941c52098ed7dab96e88441a5747d3bca',
    'TRANSIT.MIX':  '9ec1f850bff16430b8d7634f3de81862954fcd9b6468684397643fd1b3d85c78',
    'UPDATA.MIX':   'cccf39c032c921a951e890e505b5884f41c254e0486b03906637c09c29adc5c1',
    'UPDATE.MIX':   '15176e03bc6475bf1d65be6d80bc7b53181f034fd36f7959c5e2cd9371f2dc73',
    'UPDATEC.MIX':  '24cf38e75cc0ad6ec47fb040923f9844d34dbb56343894cc8315fe91e4d78c50',
    'WINTER.MIX':   '681f5aeb48751eb5e2c817ff9407b3176061d06c1fa3e5aeef71829a1b85a7fd',
    'WINTICNH.MIX': '64aa03e0115c40d7bee9938d2c1e92ef695f6c169716e1c069a21530993590af',
    'ZOUNDS.MIX':   'e80f033b2ae19c83e375edc646e2c91421ff36df1660f42a8af937919bb48320',
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


def check_exe(exe_path: str) -> list[str]:
    if not os.path.exists(exe_path):
        return [f'INFO: C&C95.EXE not found at {exe_path} (run scripts/wine-td-setup.sh)']
    actual = sha256_file(exe_path)
    if CC95_EXE_SHA256.startswith('PLACEHOLDER'):
        size = os.path.getsize(exe_path)
        print(f'  INFO    C&C95.EXE ({size:,} bytes) — SHA256={actual}')
        print(f'          Update CC95_EXE_SHA256 in this script with the value above.')
        return []
    if actual == CC95_EXE_SHA256:
        size = os.path.getsize(exe_path)
        print(f'  OK      C&C95.EXE ({size:,} bytes) — sha256 matches reference')
    else:
        return [
            f'MISMATCH C&C95.EXE\n'
            f'          expected {CC95_EXE_SHA256}\n'
            f'          actual   {actual}'
        ]
    return []


def main() -> int:
    data_dir = sys.argv[1] if len(sys.argv) > 1 else DATA_DIR_DEFAULT
    exe_path = sys.argv[2] if len(sys.argv) > 2 else CC95_EXE_DEFAULT

    print(f'Tiberian Dawn reference data verification')
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

    print('=== C&C95.EXE (OG Win95 binary) ===')
    errors = check_exe(exe_path)
    for e in errors:
        print(f'  {e}')
    all_errors += [e for e in errors if not e.startswith('INFO:')]
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
