#!/usr/bin/env python3
"""
TIM-747 — NOP the VGA vblank port-I/O polling loop in C&C95.EXE (CnCNet build).

Why:
  C&C95.EXE contains a dual-phase VGA vertical-blanking sync loop at VA 0x4CD5B4
  (file offset 0xcd9b4).  The loop reads I/O port 0x3DA (VGA Input Status
  Register 1) via the `in al, dx` instruction in a tight spin, waiting for
  bit 3 (VBlank active) to cycle.

  On Linux, user-mode code cannot execute `in`/`out` I/O port instructions.
  Wine generates EXCEPTION_PRIV_INSTRUCTION (c0000096) on each attempt and
  delivers it as an SEH exception.  With the game stuck in the tight spin, the
  main thread processes thousands of these exceptions per second and never
  reaches Init_Game.  The result is a black primary surface for the entire run.

Fix — two-site NOP:
  1. File offset 0xcd9b4 (3 bytes):
       ec a8 08  →  31 c0 90
       `in al, dx; test al, 0x08`  →  `xor eax, eax; nop`
     al is now always 0 after the synthetic "read".  The subsequent
     `jz +3` (74 03) is taken every time — the inner loop exits immediately
     instead of spinning on the port.

  2. File offset 0xcd9bf (2 bytes):
       7d cc  →  90 90
       `jge -0x34`  →  NOP NOP
     The outer loop back-edge is removed so the timing function falls through
     after one pass, eliminating the PRIV_INSTRUCTION flood entirely.

Expected input SHA-256 (C&C95.EXE after TIM-743+TIM-747 setcoop-hwnd chain):
  935b32578dfc39d3e4bd928fe87d7703e39a974f7eb2e827a2249e119d925429

Expected output SHA-256:
  29d3d9d15fbe6332f9834508ab581dded4962bd3ac48bd473a75641ee69b4749
"""
import sys
import hashlib
import shutil

INPUT_SHA256   = "935b32578dfc39d3e4bd928fe87d7703e39a974f7eb2e827a2249e119d925429"
PATCHED_SHA256 = "29d3d9d15fbe6332f9834508ab581dded4962bd3ac48bd473a75641ee69b4749"

# Site 1: replace `in al,dx; test al,0x08` with `xor eax,eax; nop`
SITE1_OFFSET  = 0xcd9b4
SITE1_ORIG    = bytes.fromhex("eca808")   # in al,dx; test al,0x08
SITE1_PATCHED = bytes.fromhex("31c090")   # xor eax,eax; nop

# Site 2: NOP the outer timing-loop back-edge `jge -0x34`
SITE2_OFFSET  = 0xcd9bf
SITE2_ORIG    = bytes.fromhex("7dcc")     # jge -0x34
SITE2_PATCHED = bytes.fromhex("9090")     # nop nop


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
        print(f"       td-activateapp, td-setcoop-hwnd patches first")
        return 1

    if bytes(data[SITE1_OFFSET:SITE1_OFFSET + len(SITE1_ORIG)]) != SITE1_ORIG:
        print(f"ERROR: guard bytes mismatch at 0x{SITE1_OFFSET:x}: "
              f"{bytes(data[SITE1_OFFSET:SITE1_OFFSET + len(SITE1_ORIG)]).hex()} "
              f"!= {SITE1_ORIG.hex()}")
        return 1

    if bytes(data[SITE2_OFFSET:SITE2_OFFSET + len(SITE2_ORIG)]) != SITE2_ORIG:
        print(f"ERROR: guard bytes mismatch at 0x{SITE2_OFFSET:x}: "
              f"{bytes(data[SITE2_OFFSET:SITE2_OFFSET + len(SITE2_ORIG)]).hex()} "
              f"!= {SITE2_ORIG.hex()}")
        return 1

    if dry_run:
        print(f"{path}: DRY RUN — would patch 0x{SITE1_OFFSET:x} (in→xor) "
              f"and 0x{SITE2_OFFSET:x} (jge→nop)")
        return 0

    backup = path + ".ioport_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[SITE1_OFFSET:SITE1_OFFSET + len(SITE1_PATCHED)] = SITE1_PATCHED
    data[SITE2_OFFSET:SITE2_OFFSET + len(SITE2_PATCHED)] = SITE2_PATCHED

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    print(f"  Patched 0x{SITE1_OFFSET:x}: in al,dx → xor eax,eax (fake VGA port read)")
    print(f"  Patched 0x{SITE2_OFFSET:x}: jge → nop nop (remove timing-loop back-edge)")
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
