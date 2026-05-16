#!/usr/bin/env python3
"""
TIM-747 — NOP all VGA port-I/O polling loops in C&C95.EXE (CnCNet build).

Why:
  C&C95.EXE contains multiple VGA vertical-blanking synchronization loops that
  poll I/O port 0x3DA (VGA Input Status Register 1) via the `in al, dx`
  instruction.  On Linux, user-mode code cannot execute I/O port instructions;
  Wine generates EXCEPTION_PRIV_INSTRUCTION (c0000096) on each attempt.

  The game has two kinds of port-I/O loops:

  1. Timing loop at VA 0x4CD5B4 (file 0xcd9b4): reads port 0x3DA and loops on
     `jge -0x34` counting down a frame timer.  Generates thousands of exceptions
     per second → Init_Game never runs → game window stays black.

  2. Dual-phase VBlank sync helpers at VA 0x4D3EDC/0x4D3EF9 (file 0xd2edc /
     0xd2ef9): two small functions that spin until bit 3 of port 0x3DA matches
     an expected VBlank state (active / inactive).  Called from the render loop;
     each call generates a fresh exception flood.

Fix — four-site NOP:

  Site 1: file 0xcd9b4 (3 bytes)
    ec a8 08  →  31 c0 90
    `in al,dx; test al,0x08`  →  `xor eax,eax; nop`
    Fake port read returns 0 (VBlank bit clear); subsequent `jz +3` exits inner
    loop immediately.

  Site 2: file 0xcd9bf (2 bytes)
    7d cc  →  90 90
    `jge -0x34`  →  NOP NOP
    Removes outer timing-loop back-edge; function falls through.

  Site 3: file 0xd2edc (7 bytes)
    ec 24 08 32 c4 75 f4  →  90×7
    `in al,dx; and al,0x08; xor al,ah; jne -12`  →  NOP×7
    NOP the "spin until VBlank active" helper entirely.

  Site 4: file 0xd2ef9 (7 bytes)
    ec 24 08 32 c4 74 f4  →  90×7
    `in al,dx; and al,0x08; xor al,ah; je -12`  →  NOP×7
    NOP the "spin until VBlank inactive" helper entirely.

Expected input SHA-256 (C&C95.EXE after TIM-743+TIM-747 full chain: ddmode + setcoop-hwnd):
  19ab8620eadfe1b31ce340922fc426b7fcd407a044ba890b543144f25d1dbf58

Expected output SHA-256:
  42664f2aa13fe1dc661326ecbf01ad7c6b8c0c2e7b1bd1bc01938fa2e98e31d0
"""
import sys
import hashlib
import shutil

INPUT_SHA256   = "19ab8620eadfe1b31ce340922fc426b7fcd407a044ba890b543144f25d1dbf58"
PATCHED_SHA256 = "42664f2aa13fe1dc661326ecbf01ad7c6b8c0c2e7b1bd1bc01938fa2e98e31d0"

SITES = [
    # (offset, orig_bytes, patched_bytes, description)
    (0xcd9b4,
     bytes.fromhex("eca808"),
     bytes.fromhex("31c090"),
     "in al,dx → xor eax,eax (timing loop fake read)"),
    (0xcd9bf,
     bytes.fromhex("7dcc"),
     bytes.fromhex("9090"),
     "jge → nop nop (timing-loop back-edge)"),
    (0xd2edc,
     bytes.fromhex("ec240832c475f4"),
     bytes.fromhex("90909090909090"),
     "VBlank-sync helper 1: spin-until-active → nop×7"),
    (0xd2ef9,
     bytes.fromhex("ec240832c474f4"),
     bytes.fromhex("90909090909090"),
     "VBlank-sync helper 2: spin-until-inactive → nop×7"),
]


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
        print(f"       apply td-focus-skip, td-game-in-focus, td-vqa-skip,")
        print(f"       td-activateapp, td-ddmode, td-setcoop-hwnd patches first")
        return 1

    for offset, orig, patched, desc in SITES:
        actual = bytes(data[offset:offset + len(orig)])
        if actual != orig:
            print(f"ERROR: guard bytes mismatch at 0x{offset:x}: "
                  f"{actual.hex()} != {orig.hex()}")
            return 1

    if dry_run:
        for offset, orig, patched, desc in SITES:
            print(f"  DRY RUN 0x{offset:x}: {desc}")
        return 0

    backup = path + ".ioport_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    for offset, orig, patched, desc in SITES:
        data[offset:offset + len(patched)] = patched
        print(f"  Patched 0x{offset:x}: {desc}")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    print(f"{path}: td-ioport patch applied ({out_digest[:16]}…)")
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
