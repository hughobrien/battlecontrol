#!/usr/bin/env python3
"""
TIM-743 — Prevent WM_ACTIVATEAPP from clearing GameInFocus in C&C95.EXE.

Under Xvfb+openbox, WM_ACTIVATEAPP(0) is delivered to the game window when
focus is lost (e.g. on startup before focus arrives, or any transient loss).
The WinProc handler at VA=0x410f41 stores wParam directly into GameInFocus
(0x53dd44), overwriting the 1 set by td-game-in-focus-patch.py. This causes
the render gate at CONQUER.CPP:1543
    if (SpecialDialog == SDLG_NONE && GameInFocus)
to fail on every frame, producing a permanently white window.

Fix: NOP the 6-byte `mov %ecx, 0x53dd44` instruction. GameInFocus stays pinned
to 1 from the entry-detour. The subsequent `test %ecx, %ecx; jne` still works
correctly (ECX retains wParam), so Focus_Loss() is called normally on focus-loss
events (it only pauses audio / hides mouse — harmless).

Patch site:
  file=0x1341  VA=0x410f41
  89 0d 44 dd 53 00   mov %ecx, 0x53dd44  <- patched: 6x NOP
  85 c9               test %ecx, %ecx
  75 05               jne  0x410f50
  e8 14 fc ff ff      call Focus_Loss      <- only called when wParam=0

Accepted input SHA-256: output of td-vqa-skip-patch.py
    5f0f37829a7db69dcb601f920e4b24d079d878ede90d8a7a662119ba4d39273b
"""
import sys
import hashlib
import shutil

ACCEPTED_INPUT_SHA256 = {
    "5f0f37829a7db69dcb601f920e4b24d079d878ede90d8a7a662119ba4d39273b",
}

PATCH_OFFSET = 0x1341
ORIGINAL_BYTES = bytes.fromhex("890d44dd5300")   # mov %ecx, 0x53dd44
PATCHED_BYTES  = b'\x90' * 6                     # 6x NOP

SITE_SIGNATURE = bytes.fromhex("85c9")           # test %ecx, %ecx (bytes +6 onwards)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    if data[PATCH_OFFSET:PATCH_OFFSET+6] == PATCHED_BYTES:
        print(f"{path}: already patched (td-activateapp)")
        return 0

    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       accepted inputs:")
        for h in sorted(ACCEPTED_INPUT_SHA256):
            print(f"         {h}")
        return 1

    if data[PATCH_OFFSET:PATCH_OFFSET+6] != ORIGINAL_BYTES:
        print(f"ERROR: bytes at 0x{PATCH_OFFSET:x}: {bytes(data[PATCH_OFFSET:PATCH_OFFSET+6]).hex()}")
        print(f"       expected: {ORIGINAL_BYTES.hex()}")
        return 1

    sig = bytes(data[PATCH_OFFSET+6:PATCH_OFFSET+8])
    if sig != SITE_SIGNATURE:
        print(f"ERROR: signature mismatch at +6: {sig.hex()} expected {SITE_SIGNATURE.hex()}")
        return 1

    if dry_run:
        print(f"  DRY RUN: would NOP 6 bytes at 0x{PATCH_OFFSET:x} (GameInFocus WM_ACTIVATEAPP store)")
        return 0

    backup = path + ".td_activateapp_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[PATCH_OFFSET:PATCH_OFFSET+6] = PATCHED_BYTES
    print(f"  Patched 0x{PATCH_OFFSET:x}: WM_ACTIVATEAPP GameInFocus store -> NOP x6")

    out_digest = sha256(bytes(data))
    with open(path, 'wb') as f:
        f.write(data)

    print(f"{path}: td-activateapp patch applied ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    dry_run = "--dry-run" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not paths:
        paths = ["/opt/tiberiandawn/C&C95.EXE"]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry_run)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
