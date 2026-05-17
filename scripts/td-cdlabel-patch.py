#!/usr/bin/env python3
"""
TIM-747 — Fix Get_CD_Index CD-label spin-loop in C&C95.EXE (CnCNet build).

Why:
  C&C95.EXE's Get_CD_Index iterates drives A:–Z: and calls
  GetVolumeInformationA on each, comparing the volume label against the
  built-in table ["GDI95", "NOD95", "COVERT"].  Wine's DOSFS layer
  returns an empty string ("") for any drive backed by a host-filesystem
  symlink without a .windows-label file.  The comparison always fails
  → the function spins re-scanning all drives in a tight loop, burning
  CPU and leaving the primary DDraw surface all-black.

Fix:
  Zero byte 0 of "GDI95" in the string table.  The string becomes ""
  (empty — null at position 0), so stricmp("", "") == 0 for any drive
  with an empty label (i.e. our D: symlink).  Get_CD_Index immediately
  finds "GDI95" on D: and returns, allowing Init_Game to proceed.

  NOD95 and COVERT are not touched; GDI95 is checked first and its
  early match is sufficient.

Patch site:
  0xda71c  47 ('G' of "GDI95") → 00

Expected input SHA-256 (C&C95.EXE after TIM-743+TIM-747 setcoop-hwnd chain):
  935b32578dfc39d3e4bd928fe87d7703e39a974f7eb2e827a2249e119d925429

Expected output SHA-256:
  c88e74cfcee017bc7abb9fc5657f08665570162a3df13e621b6e296ee2f579ed
"""

import sys
import hashlib
import shutil

INPUT_SHA256 = "935b32578dfc39d3e4bd928fe87d7703e39a974f7eb2e827a2249e119d925429"
PATCHED_SHA256 = "c88e74cfcee017bc7abb9fc5657f08665570162a3df13e621b6e296ee2f579ed"

PATCH_OFFSET = 0xDA71C  # 'G' of "GDI95"
PATCH_ORIG = 0x47  # 'G'
PATCH_NEW = 0x00  # NUL → makes stricmp("", "") match empty drive label

GUARD_OFFSET = PATCH_OFFSET
GUARD_BYTE = PATCH_ORIG


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    if digest == PATCHED_SHA256:
        print(f"{path}: already patched ({PATCHED_SHA256[:16]}…)")
        return 0

    if digest != INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected: {INPUT_SHA256}")
        print("       apply td-focus-skip, td-game-in-focus, td-vqa-skip,")
        print("       td-activateapp, td-setcoop-hwnd patches first")
        return 1

    if data[GUARD_OFFSET] != GUARD_BYTE:
        print(
            f"ERROR: guard byte at 0x{GUARD_OFFSET:x}: "
            f"0x{data[GUARD_OFFSET]:02x} != 0x{GUARD_BYTE:02x}"
        )
        return 1

    if dry_run:
        print(
            f"{path}: DRY RUN — would zero 0x{PATCH_OFFSET:x} "
            f"(GDI95[0] = 0x{PATCH_ORIG:02x} → 0x{PATCH_NEW:02x})"
        )
        return 0

    backup = path + ".cdlabel_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[PATCH_OFFSET] = PATCH_NEW

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    print(
        f"  Patched 0x{PATCH_OFFSET:x}: GDI95[0] -> NUL (Get_CD_Index accepts empty label)"
    )
    print(f"{path}: td-cdlabel patch applied ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    dry = "--dry-run" in sys.argv
    paths = args if args else ["/opt/tiberiandawn/C&C95.EXE"]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
