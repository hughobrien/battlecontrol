#!/usr/bin/env python3
"""
Patch RA95.EXE to use a fixed gameplay random seed.

The retail binary initializes the single-player seed with:

    time(NULL); srand(...); Seed = rand();

For screenshot parity this makes Wine and native diverge before the first
captured frame. This opt-in patch replaces the time/srand/rand call sequence
with "mov eax, <seed>" and leaves the original store to the Seed global intact.
"""

import argparse
import hashlib
import shutil
import struct
import sys


SITES = [
    (
        0x004FF345,
        bytes.fromhex("31c0e8856d0b00e8dd6d0b00e8b46d0b00"),
        "single-player Init_Random seed",
    ),
]


def va_to_file_offset(va: int) -> int:
    if 0x00410000 <= va < 0x005CCE00:
        return 0x00000400 + (va - 0x00410000)
    if 0x005D0000 <= va < 0x00605000:
        return 0x001BD200 + (va - 0x005D0000)
    raise ValueError(f"VA 0x{va:08x} not in mapped sections")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, seed: int, dry_run: bool) -> int:
    if seed < 0 or seed > 0xFFFFFFFF:
        print(f"ERROR: seed out of 32-bit range: {seed}", file=sys.stderr)
        return 1

    with open(path, "rb") as f:
        data = bytearray(f.read())

    replacement = b"\xb8" + struct.pack("<I", seed) + b"\x90" * 12
    applied = 0

    for va, expected, label in SITES:
        off = va_to_file_offset(va)
        actual = bytes(data[off : off + len(expected)])
        already = actual == replacement
        if already:
            print(f"  VA 0x{va:08x}: already fixed ({label})")
            applied += 1
            continue
        if actual != expected:
            print(f"SKIP VA 0x{va:08x}: expected {expected.hex()}, got {actual.hex()}")
            continue
        if not dry_run:
            data[off : off + len(expected)] = replacement
        print(f"  VA 0x{va:08x}: Seed={seed} ({label})")
        applied += 1

    if applied == 0:
        print("ERROR: no seed patch sites applied")
        print(f"  SHA-256: {sha256(bytes(data))[:32]}...")
        return 1

    if dry_run:
        return 0

    backup = path + ".random_seed_orig"
    try:
        with open(backup, "rb"):
            pass
    except FileNotFoundError:
        shutil.copy2(path, backup)

    with open(path, "wb") as f:
        f.write(data)

    print(
        f"{path}: {applied}/{len(SITES)} seed patch site(s), SHA-256: {sha256(bytes(data))[:16]}..."
    )
    return 0 if applied == len(SITES) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("exe_path")
    ap.add_argument("seed", type=lambda s: int(s, 0))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    return patch(args.exe_path, args.seed, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
