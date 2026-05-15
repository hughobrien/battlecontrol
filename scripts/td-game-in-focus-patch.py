#!/usr/bin/env python3
"""
TIM-743 — Pin GameInFocus = 1 in C&C95.EXE for headless Wine runs.

td-focus-skip-patch.py NOPs the three backward-JE spin loops, but the game's
render path is also gated on the global DWORD at VA 0x53dd44 (TD's equivalent
of RA's GameInFocus bool). Under Xvfb+openbox WM_ACTIVATEAPP is never
delivered, so 0x53dd44 stays 0 and rendering is skipped every frame.

Strategy
--------
Two cooperating writes ensure 0x53dd44 stays 1 from process start onward:

  1. Entry-point detour. The PE entry point (VA 0x4d9c94) is rewritten to
     jump to a code cave in the .text zero-padding at VA 0x4e5c58. The cave
     does `mov byte [0x53dd44], 1`, replays the original first entry
     instruction (`movl $0x4a9720, 0x5a2e68`), then jumps back to the second
     entry instruction. This sets the byte in .bss before any user code runs.

  2. Runtime re-pins at the focus-skip spin-loop CMP sites. Each site was:
         cmpl   $0x0, 0x53dd44  (7 bytes)
         je     <loop_top>      (2 bytes — already NOPd by td-focus-skip-patch)
     This patch replaces the 7-byte CMP+2 NOPs (9 bytes) with:
         mov byte [0x53dd44], 1  (7 bytes: c6 05 44 dd 53 00 01)
         nop nop                 (2 bytes)
     So each time the old spin site is executed, the global is re-pinned.

GameInFocus address: VA=0x53dd44 (.bss). C&C95.EXE has no ASLR.

Entry patch (file 0xca094, VA 0x4d9c94):
    Original:  c7 05 68 2e 5a 00 20 97 4a 00   (movl $0x4a9720, 0x5a2e68)
    Patched:   e9 bf bf 00 00 90 90 90 90 90   (jmp 0x4e5c58 + 5 NOPs)

Code cave (file 0xd6058, VA 0x4e5c58, 22 of 160 zero bytes used):
    c6 05 44 dd 53 00 01        mov byte [0x53dd44], 1
    c7 05 68 2e 5a 00 20 97 4a 00   replay entry insn 1
    e9 30 40 ff ff              jmp 0x4d9c9e (entry+10, second instruction)

Spin-loop re-pin (9 bytes at each of 3 sites, applied after focus-skip):
    c6 05 44 dd 53 00 01 90 90  mov byte [0x53dd44], 1 + 2 NOPs

Accepted input SHA-256:
    3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627  (original)
    53d1670fc4122dacc31343e0f00529037badaaa8166ebf4d48b154c5d13cf74d  (+ focus-skip)
Output SHA-256:
    460bf72d18447a935f9269f85bef0c27ba56953e12aed3b52bdcb28e75822ee6
"""
import sys
import hashlib
import shutil
import struct

ACCEPTED_INPUT_SHA256 = {
    "3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627",  # original
    "53d1670fc4122dacc31343e0f00529037badaaa8166ebf4d48b154c5d13cf74d",  # + focus-skip
}
OUTPUT_SHA256 = "460bf72d18447a935f9269f85bef0c27ba56953e12aed3b52bdcb28e75822ee6"

# (1) Entry detour
ENTRY_FILE_OFFSET = 0xca094
ENTRY_ORIG_BYTES = bytes.fromhex('c705682e5a0020974a00')   # 10 bytes (first entry insn)
ENTRY_PATCHED_BYTES = bytes.fromhex('e9bfbf00009090909090')  # jmp 0x4e5c58 + 5 NOPs
assert len(ENTRY_PATCHED_BYTES) == len(ENTRY_ORIG_BYTES) == 10

# (2) Code cave
CAVE_FILE_OFFSET = 0xd6058
CAVE_ORIG_BYTES = b'\x00' * 22
CAVE_PATCHED_BYTES = bytes.fromhex(
    'c60544dd530001'              # mov byte [0x53dd44], 1
    'c705682e5a0020974a00'        # movl $0x4a9720, 0x5a2e68  (replay entry insn 1)
    'e93040ffff'                  # jmp 0x4d9c9e  (entry+10)
)
assert len(CAVE_PATCHED_BYTES) == 22

# (3) Spin-loop CMP sites re-pin
# Each site: file offset of the CMP instruction (7 bytes CMP + 2 bytes NOP after focus-skip)
# Pre-focus-skip: 7-byte CMP + 2-byte JE (short); post-focus-skip: 7-byte CMP + 2-byte NOP
SPIN_CMP_OFFSETS = [
    0x1e3b4 - 7,  # 0x1e3ad — spin loop 1 CMP offset
    0x448f7 - 7,  # 0x448f0 — spin loop 2 CMP offset
    0x6c5fb - 7,  # 0x6c5f4 — spin loop 3 CMP offset
]
SPIN_ORIG_AFTER_FOCUS_SKIP = bytes.fromhex('833d44dd530000' + '9090')  # CMP + 2 NOPs (9 bytes)
SPIN_ORIG_PRE_FOCUS_SKIP = {
    0x1e3ad: bytes.fromhex('833d44dd53000074ed'),
    0x448f0: bytes.fromhex('833d44dd53000074eb'),
    0x6c5f4: bytes.fromhex('833d44dd530000749a'),
}
SPIN_PATCHED_BYTES = bytes.fromhex('c60544dd53000190 90'.replace(' ', ''))  # mov byte + 2 NOPs
assert len(SPIN_PATCHED_BYTES) == 9


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    digest = sha256(bytes(data))

    entry_already = bytes(data[ENTRY_FILE_OFFSET:ENTRY_FILE_OFFSET + 10]) == ENTRY_PATCHED_BYTES
    cave_already = bytes(data[CAVE_FILE_OFFSET:CAVE_FILE_OFFSET + 22]) == CAVE_PATCHED_BYTES
    spins_already = all(
        bytes(data[off:off + 9]) == SPIN_PATCHED_BYTES for off in SPIN_CMP_OFFSETS
    )
    if entry_already and cave_already and spins_already:
        print(f"{path}: already patched (td-game-in-focus pin, all mechanisms)")
        return 0

    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       accepted inputs:")
        for h in sorted(ACCEPTED_INPUT_SHA256):
            print(f"         {h}")
        return 1

    # Entry precondition
    if not entry_already:
        actual = bytes(data[ENTRY_FILE_OFFSET:ENTRY_FILE_OFFSET + 10])
        if actual != ENTRY_ORIG_BYTES:
            print(f"ERROR: entry bytes mismatch at 0x{ENTRY_FILE_OFFSET:x}")
            print(f"  expected: {ENTRY_ORIG_BYTES.hex()}")
            print(f"  actual:   {actual.hex()}")
            return 1

    # Cave precondition
    if not cave_already:
        actual = bytes(data[CAVE_FILE_OFFSET:CAVE_FILE_OFFSET + 22])
        if actual != CAVE_ORIG_BYTES:
            print(f"ERROR: code cave at 0x{CAVE_FILE_OFFSET:x} is not zero-padded")
            return 1

    # Spin-loop preconditions
    for off in SPIN_CMP_OFFSETS:
        actual = bytes(data[off:off + 9])
        if actual == SPIN_PATCHED_BYTES:
            continue  # already patched
        if actual == SPIN_ORIG_AFTER_FOCUS_SKIP:
            continue  # focus-skip applied, ready to overwrite
        if actual == SPIN_ORIG_PRE_FOCUS_SKIP.get(off):
            print(f"warn: td-focus-skip-patch.py not applied at 0x{off:x} — proceeding")
            continue
        print(f"ERROR: unexpected bytes at spin-loop site 0x{off:x}: {actual.hex()}")
        return 1

    if dry_run:
        print(f"  DRY RUN: entry detour, code cave, {len(SPIN_CMP_OFFSETS)} spin-loop re-pins")
        return 0

    backup = path + ".td_game_in_focus_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    if not entry_already:
        data[ENTRY_FILE_OFFSET:ENTRY_FILE_OFFSET + 10] = ENTRY_PATCHED_BYTES
        print(f"  Patched entry at 0x{ENTRY_FILE_OFFSET:x} -> jmp 0x4e5c58")

    if not cave_already:
        data[CAVE_FILE_OFFSET:CAVE_FILE_OFFSET + 22] = CAVE_PATCHED_BYTES
        print(f"  Patched code cave at 0x{CAVE_FILE_OFFSET:x} (22 bytes)")

    for off in SPIN_CMP_OFFSETS:
        if bytes(data[off:off + 9]) != SPIN_PATCHED_BYTES:
            data[off:off + 9] = SPIN_PATCHED_BYTES
            print(f"  Re-pinned spin site at 0x{off:x}")

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    if out_digest != OUTPUT_SHA256:
        print(f"WARNING: output SHA-256 mismatch: {out_digest}")
        print(f"         expected: {OUTPUT_SHA256}")
    else:
        print(f"{path}: td-game-in-focus pin applied ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    dry_run = "--dry-run" in sys.argv
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not paths:
        paths = [
            "/opt/tiberiandawn/C&C95.EXE",
        ]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry_run)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
