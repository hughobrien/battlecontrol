#!/usr/bin/env python3
"""
TIM-776 — Soviet variant of the CD-label patch for RA95.EXE.

The standard cdlabel-patch (TIM-739) zeros the first byte of "CD1" in
_CD_Volume_Label[], so Wine's empty volume label matches index 0 →
Get_CD_Index returns 0 → CurrentCD = 0 → SCG01EA.INI (Allied L1).

This Soviet variant zeros the first byte of "CD2" instead, leaving "CD1"
intact.  Wine's empty volume label then fails to match index 0 (still
"CD1") and matches index 1 (now ""), so Get_CD_Index returns 1 →
CurrentCD = 1 → SCU01EA.INI (Soviet L1) via INIT.CPP:1032-1036.

This patch is **mutually exclusive** with the standard cdlabel-patch.
Apply this one instead, not in addition.  If both were applied, both
labels would be "" and Get_CD_Index would return the first match (0,
Allied).

Patch site (DGROUP section):
  file 0x1BFCB7  C  D  1 \\0  C  D  2 \\0
                                ^
                              0x1BFCBB

After patch:
  file 0x1BFCB7  C  D  1 \\0 \\0 D  2 \\0
                                ^
                              0x1BFCBB → 0x00

Accepted input SHA-256 prefixes (focus-skip + game-in-focus chain):
  4f3156f7  — probe-skip + game-in-focus-pin applied
"""

import sys
import hashlib
import os
import shutil

PATCH_OFFSET = 0x1BFCBB  # First byte of "CD2"
OLD_BYTE = ord("C")  # 0x43
NEW_BYTE = 0x00

# Guard: ensure we're at the start of "CD2\0" and "CD1\0" still precedes it
GUARD_BYTES_AT_CD1 = b"CD1\x00"
GUARD_BYTES_AT_CD2 = b"CD2\x00"
CD1_OFFSET = 0x1BFCB7

ACCEPTED_INPUT_PREFIXES = {
    "4f3156f7",  # focus-skip + game-in-focus-pin
    "b00745c2",  # focus-skip only
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    digest8 = digest[:8]

    # Idempotency: already patched if first byte of CD2 is null
    if data[PATCH_OFFSET] == NEW_BYTE and data[CD1_OFFSET] == ord("C"):
        print(f"{path}: soviet cd-label patch already applied — skipping")
        return 0

    # Refuse to run on a binary that already had the Allied cdlabel-patch
    # applied (CD1[0] zeroed) — that would leave both labels empty and the
    # game would still launch Allied L1 (first match wins).
    if data[CD1_OFFSET] != ord("C"):
        print(
            f"ERROR: CD1 label at 0x{CD1_OFFSET:x} already zeroed — the "
            f"Allied cdlabel-patch was applied first.  Restore from .cdlabel_orig "
            f"backup and apply soviet-cdlabel-patch alone."
        )
        return 1

    # Verify guard bytes at both sites
    cd1_bytes = bytes(data[CD1_OFFSET : CD1_OFFSET + 4])
    cd2_bytes = bytes(data[PATCH_OFFSET : PATCH_OFFSET + 4])
    if cd1_bytes != GUARD_BYTES_AT_CD1:
        print(f"ERROR: CD1 guard at 0x{CD1_OFFSET:x} unexpected: {cd1_bytes!r}")
        return 1
    if cd2_bytes != GUARD_BYTES_AT_CD2:
        print(f"ERROR: CD2 guard at 0x{PATCH_OFFSET:x} unexpected: {cd2_bytes!r}")
        return 1

    if digest8 not in ACCEPTED_INPUT_PREFIXES:
        print(f"WARN: input SHA-256 {digest8}… not in accepted list — patching anyway")

    backup = path + ".soviet_cdlabel_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    data[PATCH_OFFSET] = NEW_BYTE

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: soviet cd-label patch applied ({out_digest[:16]}…)")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <RA95.EXE> [<RA95.EXE> ...]")
        return 1
    rc = 0
    for path in sys.argv[1:]:
        rc |= patch(path)
    return rc


if __name__ == "__main__":
    sys.exit(main())
