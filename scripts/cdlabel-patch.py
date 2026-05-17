#!/usr/bin/env python3
"""
TIM-739 — CD-label patch for RA95.EXE (Allied CD v1.08).

Root cause: RA's Get_CD_Index() (CONQUER.CPP:4675) spins forever when
Wine's GetVolumeInformationA returns an empty volume label for D:, because
the label comparison at line 4701 never matches _CD_Volume_Label[] = {"CD1","CD2"}.
The drive is a directory-backed symlink to a CIFS share, so Wine cannot store
or return the "CD1" label via xattr or SetVolumeLabel.

Patch: overwrite the first byte of the "CD1" string in DGROUP with '\x00',
making _CD_Volume_Label[0] an empty string.  Wine returns "" as the volume
label → stricmp("", "") == 0 → Get_CD_Index returns 0 → CD check passes.

Only the first byte of "CD1" is zeroed; "CD2" is unaffected (it starts at
the next offset).  _Num_Volumes remains 2.

Patch site (DGROUP section):
  file 0x1bfcb7  CD1\\0CD2\\0  →  \\0D1\\0CD2\\0

Accepted input SHA-256 prefixes (game-in-focus-patch chain):
  4f3156f7  — probe-skip + game-in-focus-pin applied
  (extend as needed when nocd or ddscl patches precede this in the chain)
"""

import sys
import hashlib
import shutil

# Patch site: file offset where "CD1\0" begins in DGROUP
PATCH_OFFSET = 0x1BFCB7
OLD_BYTE = ord("C")  # 0x43
NEW_BYTE = 0x00

# Guard: the four bytes at PATCH_OFFSET should be "CD1\0"
GUARD_BYTES = b"CD1\x00"

# Known-good input SHA-256 prefixes (first 8 hex chars)
ACCEPTED_INPUT_PREFIXES = {
    "4f3156f7",  # probe-skip + game-in-focus-pin
    "b00745c2",  # probe-skip only (for direct application in diag harness)
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    digest8 = digest[:8]

    # Idempotency: already patched if first byte at site is null
    if data[PATCH_OFFSET] == NEW_BYTE:
        print(f"{path}: cd-label patch already applied — skipping")
        return 0

    # Verify guard bytes
    if bytes(data[PATCH_OFFSET : PATCH_OFFSET + 4]) != GUARD_BYTES:
        print(
            f"ERROR: guard bytes at 0x{PATCH_OFFSET:x} unexpected: "
            f"{bytes(data[PATCH_OFFSET : PATCH_OFFSET + 4])!r}"
        )
        print(f"       expected: {GUARD_BYTES!r}")
        return 1

    if digest8 not in ACCEPTED_INPUT_PREFIXES:
        print(f"WARN: input SHA-256 {digest8}… not in accepted list — patching anyway")

    # Backup
    backup = path + ".cdlabel_orig"
    if not __import__("os").path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    # Apply patch
    data[PATCH_OFFSET] = NEW_BYTE

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: cd-label patch applied ({out_digest[:16]}…)")
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
