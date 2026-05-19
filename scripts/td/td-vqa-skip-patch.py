#!/usr/bin/env python3
"""
TIM-743 — VQA/movie-skip patch for C&C95.EXE (Tiberian Dawn).

C&C95.EXE plays intro movies (INTRO2, TRAILER.VQA, etc.) during startup via the
Play_Movie function at VA 0x42cf30. Under Wine with no audio device the VQA player
blocks on audio synchronisation, preventing the game from reaching the main menu.

This patch replaces the first byte of Play_Movie (0x51 = push %ecx, the function
prologue) with 0xC3 (RET), causing Play_Movie to return immediately for every
call. All cut-scenes are skipped. This is intentional for headless screenshot
capture; restore the backup to get normal movie playback.

Patch site:
  file=0x1d330  VA=0x42cf30
  0x51  push %ecx   <- patched: 0xc3 (ret)
  0x56  push %esi
  0x57  push %edi
  0x55  push %ebp

Expected input SHA-256 (after td-game-in-focus-patch.py):
    460bf72d18447a935f9269f85bef0c27ba56953e12aed3b52bdcb28e75822ee6
Output SHA-256:
    5f0f37829a7db69dcb601f920e4b24d079d878ede90d8a7a662119ba4d39273b
"""

import sys
import hashlib
import shutil

# Accept any of the chain states that contain this function unpatched
ACCEPTED_INPUT_SHA256 = {
    "460bf72d18447a935f9269f85bef0c27ba56953e12aed3b52bdcb28e75822ee6",  # + game-in-focus
    "53d1670fc4122dacc31343e0f00529037badaaa8166ebf4d48b154c5d13cf74d",  # + focus-skip only
    "3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627",  # original
}
OUTPUT_SHA256 = "5f0f37829a7db69dcb601f920e4b24d079d878ede90d8a7a662119ba4d39273b"

PATCH_OFFSET = 0x1D330  # Play_Movie entry
ORIGINAL_BYTE = 0x51  # push %ecx
PATCHED_BYTE = 0xC3  # ret

# Signature at bytes 1–4 after patched byte for extra safety check
SITE_SIGNATURE = b"\x56\x57\x55\x81"  # push esi; push edi; push ebp; sub ...


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    if data[PATCH_OFFSET] == PATCHED_BYTE:
        print(f"{path}: already patched (td-vqa-skip)")
        return 0

    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print("       accepted inputs:")
        for h in sorted(ACCEPTED_INPUT_SHA256):
            print(f"         {h}")
        return 1

    if data[PATCH_OFFSET] != ORIGINAL_BYTE:
        print(
            f"ERROR: byte at 0x{PATCH_OFFSET:x} is 0x{data[PATCH_OFFSET]:02x}, expected 0x{ORIGINAL_BYTE:02x}"
        )
        return 1

    sig_actual = bytes(data[PATCH_OFFSET + 1 : PATCH_OFFSET + 5])
    if sig_actual != SITE_SIGNATURE:
        print(
            f"ERROR: signature mismatch at 0x{PATCH_OFFSET + 1:x}: {sig_actual.hex()}"
        )
        print(f"       expected: {SITE_SIGNATURE.hex()}")
        return 1

    if dry_run:
        print(f"  DRY RUN: would write 0xC3 at 0x{PATCH_OFFSET:x} (Play_Movie -> ret)")
        return 0

    backup = path + ".td_vqa_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[PATCH_OFFSET] = PATCHED_BYTE
    print(f"  Patched 0x{PATCH_OFFSET:x}: Play_Movie entry -> ret")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != OUTPUT_SHA256:
        print(f"WARNING: output SHA-256 mismatch: {out_digest}")
        print(f"         expected: {OUTPUT_SHA256}")
    else:
        print(f"{path}: td-vqa-skip patch applied ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    dry_run = "--dry-run" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not paths:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry_run)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
