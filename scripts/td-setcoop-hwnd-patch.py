#!/usr/bin/env python3
"""
TIM-747 — Fix SetCooperativeLevel HWND=NULL in C&C95.EXE (CnCNet build).

Why:
  C&C95.EXE calls SetCooperativeLevel(hwnd=0, DDSCL_NORMAL) during DDraw init.
  EBP is the hwnd argument, but the DDraw-init helper function receives hwnd=0
  from its caller (the CnCNet binary never passes the game window handle here).
  cnc-ddraw intercepts SetCooperativeLevel and uses the hwnd to know which
  window to blit rendered game frames into.  With hwnd=NULL, cnc-ddraw has no
  target and produces a blank (white) window.

  The real window HWND is stored at global 0x567848 immediately after
  CreateWindowExA returns (at VA 0x411100: mov [0x567848], ebx).

Fix — code-cave jmp:
  The 5-byte DDSCL_NORMAL preamble `6a 08 a1 40 78` at file offset 0xbc6ae is
  replaced with a near-jmp to a 24-byte code cave at 0xd639b.  The cave
  executes the full SetCooperativeLevel call with the real HWND loaded from
  0x567848, then jumps back to the instruction after the original call.

  The dead bytes 0xbc6b3–0xbc6bc (original instruction fragments bypassed by
  the jmp, including the 3-byte guard `ff 53 50`) remain intact and unmodified;
  td-ddmode-patch.py runs before this patch and rewrites bytes at 0xbc6c3…0xbc6d4.

Patch sites:
  0xbc6ae  6a 08 a1 40 78  → e9 e8 9c 01 00   (jmp to cave at VA 0x4e5f9b)
  0xd639b  (24 zero bytes) → code cave:
           6a 08                    push $0x8 (DDSCL_NORMAL)
           a1 40 78 56 00           mov eax, [0x567840]  (DD* global)
           8b 18                    mov ebx, [eax]       (vtable ptr)
           ff 35 48 78 56 00        push [0x567848]      (real HWND global)
           50                       push eax             (this = DD*)
           ff 53 50                 call [ebx+0x50]      (SetCooperativeLevel)
           e9 09 63 fe ff           jmp 0x4cc2bc         (resume after call)

Expected input SHA-256 (C&C95.EXE after TIM-743 chain + td-ddmode-patch.py):
  46dc1eb4a81143610161e4f1930aec7a95a76f0b367e99454d08b01a6a3ccc9c

Expected output SHA-256:
  19ab8620eadfe1b31ce340922fc426b7fcd407a044ba890b543144f25d1dbf58
"""
import sys
import hashlib
import shutil

INPUT_SHA256   = "46dc1eb4a81143610161e4f1930aec7a95a76f0b367e99454d08b01a6a3ccc9c"
PATCHED_SHA256 = "19ab8620eadfe1b31ce340922fc426b7fcd407a044ba890b543144f25d1dbf58"

# 5-byte jmp at 0xbc6ae replacing the DDSCL_NORMAL path preamble
JMP_OFFSET  = 0xbc6ae
JMP_ORIG    = bytes.fromhex("6a08a14078")   # push $0x8; mov eax,[0x567840] partial
JMP_PATCHED = bytes.fromhex("e9e89c0100")   # jmp 0x4e5f9b (rel32 = +0x019ce8)

# 24-byte code cave at 0xd639b (verified zero-filled in the original binary)
CAVE_OFFSET  = 0xd639b
CAVE_ORIG    = bytes(24)                     # must be all zeros
CAVE_PATCHED = bytes.fromhex(
    "6a08"           # push $0x8  (DDSCL_NORMAL)
    "a140785600"     # mov eax,[0x567840]  (DD*)
    "8b18"           # mov ebx,[eax]        (vtable)
    "ff3548785600"   # push [0x567848]      (real HWND)
    "50"             # push eax             (this)
    "ff5350"         # call [ebx+0x50]      (SetCooperativeLevel)
    "e90963feff"     # jmp 0x4cc2bc         (resume)
)

# Sanity guard: original DDSCL_NORMAL preamble byte at jmp site
GUARD_OFFSET = JMP_OFFSET
GUARD_BYTES  = JMP_ORIG


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    if digest == PATCHED_SHA256:
        print(f"{path}: already patched ({PATCHED_SHA256[:16]}…)")
        return 0

    if digest != INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected: {INPUT_SHA256}")
        print(f"       apply td-focus-skip, td-game-in-focus, td-vqa-skip,")
        print(f"       td-activateapp, then td-ddmode-patch.py first")
        return 1

    if bytes(data[GUARD_OFFSET:GUARD_OFFSET + len(GUARD_BYTES)]) != GUARD_BYTES:
        print(f"ERROR: guard bytes mismatch at 0x{GUARD_OFFSET:x}: "
              f"{bytes(data[GUARD_OFFSET:GUARD_OFFSET + len(GUARD_BYTES)]).hex()} "
              f"!= {GUARD_BYTES.hex()}")
        return 1

    if bytes(data[CAVE_OFFSET:CAVE_OFFSET + len(CAVE_ORIG)]) != CAVE_ORIG:
        print(f"ERROR: code cave at 0x{CAVE_OFFSET:x} is not zero-filled: "
              f"{bytes(data[CAVE_OFFSET:CAVE_OFFSET + len(CAVE_ORIG)]).hex()}")
        return 1

    if dry_run:
        print(f"{path}: DRY RUN — would patch 0x{JMP_OFFSET:x} (jmp) and "
              f"0x{CAVE_OFFSET:x} (cave, {len(CAVE_PATCHED)} bytes)")
        return 0

    backup = path + ".setcoop_hwnd_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[JMP_OFFSET:JMP_OFFSET + len(JMP_PATCHED)] = JMP_PATCHED
    data[CAVE_OFFSET:CAVE_OFFSET + len(CAVE_PATCHED)] = CAVE_PATCHED

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    print(f"  Patched 0x{JMP_OFFSET:x}: jmp → cave at VA 0x4e5f9b")
    print(f"  Patched 0x{CAVE_OFFSET:x}: code cave ({len(CAVE_PATCHED)} bytes) with real HWND")
    print(f"{path}: td-setcoop-hwnd patch applied ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    dry = "--dry-run" in sys.argv
    paths = args if args else [
        "/opt/tiberiandawn/C&C95.EXE",
    ]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
