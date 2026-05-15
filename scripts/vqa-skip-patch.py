#!/usr/bin/env python3
"""
TIM-708 — VQA-skip patch for RA95.EXE.

The original Play_Movie function at file offset 0xa53c4 calls the internal
VQA player, which blocks on audio-position synchronisation under Wine when
no real ALSA/PulseAudio device is available.  The game never advances past
the ENGLISH.VQA intro screen.

This patch replaces the function prologue byte (0x55 push %ebp) with a
RET (0xC3), causing Play_Movie to return immediately for every call, so
the game goes straight to the main menu.

All cut-scenes (intro, mission briefings, win/lose movies) are skipped.
This is intentional for headless screenshot capture.  Revert to the backup
to restore normal behaviour.

Patch site:
  0x0a53c4  55                   push %ebp   <- patched: c3 (ret)
  0x0a53c5  89 e5                mov %esp,%ebp
  0x0a53c7  56                   push %esi
  0x0a53c8  3c ff                cmp $0xff,%al

Expected input SHA-256 (all prior patches already applied):
  08f89ab8c85d38650f981a6e1f998e2dacd164142bde5aa22146e5d57382d03c
"""
import sys
import hashlib
import shutil

ORIGINAL_SHA256 = "08f89ab8c85d38650f981a6e1f998e2dacd164142bde5aa22146e5d57382d03c"

PATCH_OFFSET = 0x0a53c4    # Play_Movie entry
ORIGINAL_BYTE = 0x55       # push %ebp
PATCHED_BYTE  = 0xC3       # ret

# Signature to verify we're at the right site (bytes 1-4 after the patched byte)
SITE_SIGNATURE = b'\x89\xe5\x56\x3c\xff'   # mov %esp,%ebp; push %esi; cmp $0xff,%al


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    # Check if already patched
    if data[PATCH_OFFSET] == PATCHED_BYTE:
        sig = bytes(data[PATCH_OFFSET + 1:PATCH_OFFSET + 6])
        if sig == SITE_SIGNATURE:
            print(f"{path}: already patched")
            return 0

    # Verify expected input hash
    if digest != ORIGINAL_SHA256:
        print(f"WARNING: unexpected input SHA-256 {digest}")
        print(f"         expected: {ORIGINAL_SHA256}")
        print(f"         Proceeding anyway — verifying site signature instead.")

    # Verify site signature
    if data[PATCH_OFFSET] != ORIGINAL_BYTE:
        print(f"ERROR: byte at 0x{PATCH_OFFSET:x} is 0x{data[PATCH_OFFSET]:02x}, "
              f"expected 0x{ORIGINAL_BYTE:02x}")
        return 1
    sig = bytes(data[PATCH_OFFSET + 1:PATCH_OFFSET + 6])
    if sig != SITE_SIGNATURE:
        print(f"ERROR: site signature mismatch at 0x{PATCH_OFFSET+1:x}: "
              f"{sig.hex()} != {SITE_SIGNATURE.hex()}")
        return 1

    if dry_run:
        print(f"{path}: DRY RUN — would patch 0x{PATCH_OFFSET:x}: "
              f"0x{ORIGINAL_BYTE:02x} -> 0x{PATCHED_BYTE:02x}")
        return 0

    # Backup
    backup = path + ".vqa-skip.bak"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    # Apply patch
    data[PATCH_OFFSET] = PATCHED_BYTE

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: patched OK — Play_Movie now returns immediately")
    print(f"  New SHA-256: {out_digest}")
    return 0


if __name__ == "__main__":
    paths = sys.argv[1:] if len(sys.argv) > 1 else [
        "/opt/redalert/game/RA95.EXE",
    ]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
