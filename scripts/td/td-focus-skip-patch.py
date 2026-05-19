#!/usr/bin/env python3
"""
TIM-743 — Focus-skip patch for C&C95.EXE (Tiberian Dawn).

C&C95.EXE contains three `while (!GameInFocus)` spin loops that block progression
until the game window receives a WM_ACTIVATEAPP(1) message. Under Wine running in
Xvfb (no window manager delivering WM_ACTIVATEAPP), the game spins indefinitely.

Each loop checks the DWORD at VA 0x53dd44 (TD's GameInFocus-equivalent):
    cmpl   $0x0, 0x53dd44   ; 83 3d 44 dd 53 00 00  (7 bytes)
    je     <loop_top>        ; 74 XX                 (2 bytes short JE)

This patch replaces each 2-byte JE with NOP NOP so execution always falls through.

Patch sites (JE at file offset):
    file=0x1e3b4  VA=0x42dfb4  74 ed  (spin loop 1)
    file=0x448f7  VA=0x4544f7  74 eb  (spin loop 2)
    file=0x6c5fb  VA=0x47c1fb  74 9a  (spin loop 3)

Expected input SHA-256 (original unpatched C&C95.EXE):
    3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627
Output SHA-256:
    53d1670fc4122dacc31343e0f00529037badaaa8166ebf4d48b154c5d13cf74d
"""

import sys
import hashlib
import shutil

INPUT_SHA256 = "3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627"
OUTPUT_SHA256 = "53d1670fc4122dacc31343e0f00529037badaaa8166ebf4d48b154c5d13cf74d"

# (je_file_offset, expected_9_bytes, description)
# 9 bytes = 7-byte CMP + 2-byte JE
PATCH_SITES = [
    (0x1E3B4, bytes.fromhex("833d44dd53000074ed"), "GameInFocus spin loop #1"),
    (0x448F7, bytes.fromhex("833d44dd53000074eb"), "GameInFocus spin loop #2"),
    (0x6C5FB, bytes.fromhex("833d44dd530000749a"), "GameInFocus spin loop #3"),
]
NOP2 = b"\x90\x90"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    # Check if already patched
    already = all(bytes(data[off : off + 2]) == NOP2 for off, _, _ in PATCH_SITES)
    if already:
        print(f"{path}: already patched (td-focus-skip)")
        return 0

    if digest != INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected original: {INPUT_SHA256}")
        return 1

    # Verify each patch site (check CMP+JE 9 bytes)
    for off, expected, desc in PATCH_SITES:
        cmp_off = off - 7
        actual = bytes(data[cmp_off : cmp_off + 9])
        if actual != expected:
            print(f"ERROR: unexpected bytes at 0x{cmp_off:x} ({desc}): {actual.hex()}")
            print(f"       expected: {expected.hex()}")
            return 1

    if dry_run:
        for off, _, desc in PATCH_SITES:
            print(f"  DRY RUN: would NOP 2 bytes at 0x{off:x} ({desc})")
        return 0

    backup = path + ".td_focus_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    for off, _, desc in PATCH_SITES:
        data[off : off + 2] = NOP2
        print(f"  Patched 0x{off:x}: {desc}")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != OUTPUT_SHA256:
        print(f"WARNING: output SHA-256 mismatch: {out_digest}")
        print(f"         expected: {OUTPUT_SHA256}")
    else:
        print(f"{path}: td-focus-skip patch applied ({out_digest[:16]}…)")
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
