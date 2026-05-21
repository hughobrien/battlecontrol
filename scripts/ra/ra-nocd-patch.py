#!/usr/bin/env python3
"""
TIM-720 — NoCD patch for RA95.EXE (Allied CD v1.08).

Wine's GetDriveType() returns DRIVE_REMOTE (4) instead of DRIVE_CDROM (5)
for symlinked or network-mounted directories, causing RA95.EXE to show
"Please insert a Red Alert CD" even when game data is present.

This patch NOPs the conditional jump at offset 0x1a54a1 that sends the
player to the CD error dialog when GetDriveType != DRIVE_CDROM, allowing
the game to boot regardless of drive type.

Patch site:
  0x1a5498  FF 15 60 02 6E 00   call  [GetDriveTypeA]
  0x1a549e  83 F8 05             cmp   eax, 5       ; DRIVE_CDROM
  0x1a54a1  75 DD                jne   <cd_dialog>  ; <- patched: 90 90 (NOP NOP)

Expected input SHA-256:
  a95e2ac85c4cc3aaacb7795e3c07b8aec7c3e10efe679766fb2ee15b12aa2d55

Expected output SHA-256:
  292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf
"""

import hashlib
import shutil
import sys


def _warn_deprecated() -> None:
    print(
        "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
        file=sys.stderr,
    )

ORIGINAL_SHA256 = "a95e2ac85c4cc3aaacb7795e3c07b8aec7c3e10efe679766fb2ee15b12aa2d55"
PATCHED_SHA256 = "292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf"

CALL_OFFSET = 0x1A5498  # call GetDriveTypeA
JNE_OFFSET = 0x1A54A1  # jne <cd_dialog>

# Expected bytes to verify we're patching the right location
CALL_BYTES = b"\xff\x15\x60\x02\x6e\x00"  # call [0x6e0260]
CMP_BYTES = b"\x83\xf8\x05"  # cmp eax, 5
JNE_BYTES = b"\x75\xdd"  # jne -35


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    if digest == PATCHED_SHA256:
        print(f"{path}: already patched ({PATCHED_SHA256[:16]}…)")
        return 0

    if digest != ORIGINAL_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected: {ORIGINAL_SHA256}")
        return 1

    # Verify patch site
    if bytes(data[CALL_OFFSET : CALL_OFFSET + 6]) != CALL_BYTES:
        print(f"ERROR: call bytes mismatch at 0x{CALL_OFFSET:x}")
        return 1
    if bytes(data[CALL_OFFSET + 6 : CALL_OFFSET + 9]) != CMP_BYTES:
        print(f"ERROR: cmp bytes mismatch at 0x{CALL_OFFSET + 6:x}")
        return 1
    if bytes(data[JNE_OFFSET : JNE_OFFSET + 2]) != JNE_BYTES:
        print(f"ERROR: jne bytes mismatch at 0x{JNE_OFFSET:x}")
        return 1

    if dry_run:
        print(f"{path}: DRY RUN — would patch offset 0x{JNE_OFFSET:x}: 75 dd -> 90 90")
        return 0

    # Backup
    backup = path + ".orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    # Apply patch
    data[JNE_OFFSET] = 0x90  # NOP
    data[JNE_OFFSET + 1] = 0x90  # NOP

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    print(f"{path}: patched OK ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    _warn_deprecated()
    if len(sys.argv) < 2:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    paths = sys.argv[1:]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
