#!/usr/bin/env python3
"""
TIM-803 — Scenario override patch for RA Soviet Mission 2.

The standard IsFromInstall + soviet-cdlabel patch chain auto-launches
SCU01EA.INI (Soviet Mission 1).  This patch overrides the scenario name
string in the binary's DGROUP so the game loads SCU02EA.INI (Soviet
Mission 2) instead.

Patch sites in DGROUP (_CD_Volume_Label / scenario name table):
  file 0x1C08B5  SCU01EA.INI  ->  SCU02EA.INI
  file 0x1C08CD  SCU01EA.INI  ->  SCU02EA.INI

Only the '1' byte is changed to '2' (0x31 -> 0x32).  This is compatible
with the soviet-cdlabel-patch (different offsets, different strings).

The game loads the scenario from MAIN.MIX where SCU02EA.INI exists
(confirmed in MAIN.MIX at offset 0xF62A14).

Accepted input SHA-256 prefixes (standard patch chain):
  4f3156f7  -- focus-skip + game-in-focus-pin
  b00745c2  -- focus-skip only
  2fde96fa  -- focus-skip + game-in-focus-pin + soviet-cdlabel
"""

import sys
import hashlib
import shutil
import os

PATCH_OFFSETS = [
    0x1C08B9,
    0x1C08D1,
]
OLD_BYTE = ord('1')
NEW_BYTE = ord('2')

GUARD = b'SCU01EA.INI'

ACCEPTED_INPUT_PREFIXES = {
    "4f3156f7",
    "b00745c2",
    "2fde96fa",
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def guard_offsets(data: bytearray):
    for off in PATCH_OFFSETS:
        start = off - 4
        if start < 0 or start + len(GUARD) > len(data):
            return False
        if bytes(data[start:start + len(GUARD)]) != GUARD:
            return False
    return True


def patch(path: str) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    digest8 = digest[:8]

    if not guard_offsets(data):
        print(f"ERROR: guard bytes do not match at one or more patch sites")
        return 1

    if data[PATCH_OFFSETS[0]] == NEW_BYTE and data[PATCH_OFFSETS[1]] == NEW_BYTE:
        print(f"{path}: soviet-m2 scenario patch already applied -- skipping")
        return 0

    if digest8 not in ACCEPTED_INPUT_PREFIXES:
        print(f"WARN: input SHA-256 {digest8}... not in accepted list -- patching anyway")

    backup = path + ".soviet_m2_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    for off in PATCH_OFFSETS:
        data[off] = NEW_BYTE

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: soviet-m2 scenario patch applied ({out_digest[:16]}...)")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <RA95.EXE> [<RA95.EXE> ...]")
        return 1
    rc = 0
    for p in sys.argv[1:]:
        rc |= patch(p)
    return rc


if __name__ == "__main__":
    sys.exit(main())
