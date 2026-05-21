#!/usr/bin/env python3
"""
TIM-708 — Focus-skip patch for RA95.EXE.

RA95.EXE contains three `while (!GameInFocus)` spin loops that block progression
until the game window receives a WM_ACTIVATEAPP(1) Windows message. Under Wine
running in Xvfb (no window manager), this message is never delivered, so the game
spins indefinitely.

This patch NOPs out the three backward JZ_near instructions that implement these
spin loops, so the game always proceeds regardless of WM_ACTIVATEAPP state.

Each patch site: CMP is at CMP_OFFSET (7 bytes), JZ_near at CMP_OFFSET+7 (6 bytes).
We NOP the 6-byte JZ_near.

Patch sites (JZ_near offsets = CMP_offset + 7):
  JZ at file=0x154005  VA=0x563c05  0f 84 55 ff ff ff  (JZ_near -171)
  JZ at file=0x15f2f1  VA=0x56eef1  0f 84 7b ff ff ff  (JZ_near -133)
  JZ at file=0x15f583  VA=0x56f183  0f 84 7a ff ff ff  (JZ_near -134)

Accepted input SHA-256:
  f55e92c706cb87e4e5972388f4b4c6cf6f7b282ff1fe15012d2584df07ca43a0
    (nocd + ddscl + cdlabel — i.e. output of .#ra-patched-exe)
"""

import sys

print(
    "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
    file=sys.stderr,
)

import hashlib
import shutil

ACCEPTED_SHA256 = {
    "f55e92c706cb87e4e5972388f4b4c6cf6f7b282ff1fe15012d2584df07ca43a0",  # .#ra-patched-exe
}

# (jz_file_offset, expected_6_bytes, description)
PATCH_SITES = [
    (0x154005, bytes.fromhex("0f8455ffffff"), "GameInFocus spin loop #1"),
    (0x15F2F1, bytes.fromhex("0f847bffffff"), "GameInFocus spin loop #2"),
    (0x15F583, bytes.fromhex("0f847affffff"), "GameInFocus spin loop #3"),
]
NOP6 = b"\x90" * 6


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    # Check if already patched
    already = all(bytes(data[off : off + 6]) == NOP6 for off, _, _ in PATCH_SITES)
    if already:
        print(f"{path}: already patched (focus-skip)")
        return 0

    if digest not in ACCEPTED_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print("       accepted inputs (any of):")
        for h in sorted(ACCEPTED_SHA256):
            print(f"         {h}")
        return 1

    # Verify each patch site
    for off, expected, desc in PATCH_SITES:
        actual = bytes(data[off : off + 6])
        if actual != expected:
            print(f"ERROR: unexpected bytes at 0x{off:x} ({desc}): {actual.hex()}")
            print(f"       expected: {expected.hex()}")
            return 1

    if dry_run:
        for off, _, desc in PATCH_SITES:
            print(f"  DRY RUN: would NOP 6 bytes at 0x{off:x} ({desc})")
        return 0

    backup = path + ".focus_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    for off, _, desc in PATCH_SITES:
        data[off : off + 6] = NOP6
        print(f"  Patched 0x{off:x}: {desc}")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: focus-skip patch applied ({out_digest[:16]}…)")
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
