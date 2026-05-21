#!/usr/bin/env python3
"""
TIM-735 — Pin GameInFocus = TRUE in RA95.EXE for headless Wine runs.

TIM-732 established the root cause for the perpetually-black DDraw surface
under Wine 10 + cnc-ddraw + Xvfb+openbox: RA's main render branch is gated on
`GameInFocus`, a global bool that the WM_ACTIVATEAPP window handler sets to
wParam. Under Xvfb+openbox WM_ACTIVATEAPP is never delivered, so GameInFocus
stays FALSE and the render path is skipped every frame. `ra-focus-skip-patch.py`
only NOPs three `while (!GameInFocus)` spin loops; the render guards remain.

Strategy
--------
Two cooperating runtime writes ensure the GameInFocus byte is `1` from
process start through every gated path:

  1. Entry-point detour. The PE entry point is rewritten to jump into a
     code cave at the .text zero-padding region. The cave does
     `mov byte [GameInFocus], 1`, replays the original first entry
     instruction, then jumps to the original second-instr target. Sets the
     byte in .bss before any user code runs.

  2. Runtime re-writes at the focus-skip spin loops. Where ra-focus-skip-patch
     replaced 6 bytes of the loop's JZ with NOPs, this patch replaces the
     preceding `cmp byte [GameInFocus], 0` (7 bytes) + the 6 NOPs with
     `mov byte [GameInFocus], 1` (7 bytes) + 6 NOPs. So the moment any of
     the three Watcom-emitted spin loops in Init_Game / title / netdlg is
     entered (which happens after CRT init), GameInFocus is re-pinned —
     defending against any path that the C runtime might have re-zeroed
     .bss across.

Static cmp-imm flips were considered and rejected: flipping
`cmp byte [GameInFocus], 0` to `cmp byte [GameInFocus], 1` inverts the
branch direction at every check, which conflicts with the runtime writes
in (1)/(2) — when GameInFocus actually IS 1 after the writes, the flipped
cmp produces ZF=1 and the "GameInFocus is FALSE" branch is taken instead.
Use either runtime writes or imm flip, never both. Runtime writes are
preferred because they also cover access patterns like
`mov al, [GameInFocus]; test al, al` that the imm flip cannot reach.

GameInFocus address
-------------------
Determined empirically from the cmp opcode used at the three known
ra-focus-skip sites in `ra-focus-skip-patch.py`:

    file 0x153FFE: 80 3D B8 B6 66 00 00   cmp byte ptr [0x0066B6B8], 0
                                          (and the same disp32 at 0x15F2EA and 0x15F57C)

so GameInFocus_VA = 0x0066B6B8 (in .bss). The 1996 EXE has no ASLR, so the
absolute address encoded in the shim is correct without adding .reloc
entries.

Code cave layout (file 0x1BCABF, VA 0x005CC6BF, 22 of 65 zero bytes used):

    C6 05 B8 B6 66 00 01            mov byte [0x66B6B8], 1
    C7 05 4C 79 6D 00 B0 94 55 00   mov [0x6D794C], 0x005594B0  (replay entry insn 1)
    E9 B3 93 FF FF                  jmp 0x005C5A88              (continue to CRT)

Entry patch (file 0x1AD8CA, VA 0x005BD4CA):

    Original: C7 05 4C 79 6D 00 B0 94 55 00   mov [...], ...
              E9 AF 85 00 00                  jmp 0x005C5A88
    Patched:  E9 F0 F1 00 00                  jmp 0x005CC6BF  (cave)
              90 ×10

Accepted input SHA-256:
  9e34d336469e42b5a33499a37b34c0ab513e54ec0844f890873090a423be972b
    (.#ra-patched-exe + focus-skip)

(ra-focus-skip-patch.py must run first.)
"""

import sys

print(
    "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
    file=sys.stderr,
)

import hashlib
import shutil

ACCEPTED_INPUT_SHA256 = {
    "9e34d336469e42b5a33499a37b34c0ab513e54ec0844f890873090a423be972b",  # .#ra-patched-exe + focus-skip
}

# (1) Entry detour
ENTRY_FILE_OFFSET = 0x1AD8CA
ENTRY_ORIG_BYTES = bytes.fromhex("c7054c796d00b0945500e9af850000")  # 15 bytes
ENTRY_PATCHED_BYTES = bytes.fromhex("e9f0f1000090909090909090909090")  # 5 + 10 nops
assert len(ENTRY_PATCHED_BYTES) == len(ENTRY_ORIG_BYTES) == 15

# Code cave
CAVE_FILE_OFFSET = 0x1BCABF
CAVE_ORIG_BYTES = b"\x00" * 22
CAVE_PATCHED_BYTES = bytes.fromhex(
    "c605b8b6660001"  # mov byte [0x66B6B8], 1
    "c7054c796d00b0945500"  # mov [0x6D794C], 0x005594B0
    "e9b393ffff"  # jmp 0x005C5A88
)
assert len(CAVE_PATCHED_BYTES) == 22

# (2) Spin-loop CMP+NOPs -> mov [GIF],1 + NOPs
# ra-focus-skip-patch leaves the cmp intact and NOPs the 6-byte JZ after it.
# Each site is `80 3D B8 B6 66 00 00 90 90 90 90 90 90` (13 bytes) after
# focus-skip. We rewrite to `c6 05 B8 B6 66 00 01 90 90 90 90 90 90`.
SPIN_LOOP_CMP_OFFSETS = [0x153FFE, 0x15F2EA, 0x15F57C]
SPIN_ORIG_AFTER_FOCUS_SKIP = bytes.fromhex(
    "803db8b66600009090909090 90".replace(" ", "")
)
SPIN_ORIG_PRE_FOCUS_SKIP = {
    0x153FFE: bytes.fromhex("803db8b66600000f8455ffffff"),
    0x15F2EA: bytes.fromhex("803db8b66600000f847bffffff"),
    0x15F57C: bytes.fromhex("803db8b66600000f847affffff"),
}
SPIN_PATCHED_BYTES = bytes.fromhex("c605b8b66600019090909090 90".replace(" ", ""))
assert len(SPIN_ORIG_AFTER_FOCUS_SKIP) == len(SPIN_PATCHED_BYTES) == 13


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    digest = sha256(bytes(data))

    entry_already = (
        bytes(data[ENTRY_FILE_OFFSET : ENTRY_FILE_OFFSET + 15]) == ENTRY_PATCHED_BYTES
    )
    cave_already = (
        bytes(data[CAVE_FILE_OFFSET : CAVE_FILE_OFFSET + 22]) == CAVE_PATCHED_BYTES
    )
    spins_already = all(
        bytes(data[off : off + 13]) == SPIN_PATCHED_BYTES
        for off in SPIN_LOOP_CMP_OFFSETS
    )
    if entry_already and cave_already and spins_already:
        print(f"{path}: already patched (game-in-focus pin, all three mechanisms)")
        return 0

    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print("       accepted inputs (any of):")
        for h in sorted(ACCEPTED_INPUT_SHA256):
            print(f"         {h}")
        return 1

    # Entry / cave preconditions
    if not entry_already:
        actual = bytes(data[ENTRY_FILE_OFFSET : ENTRY_FILE_OFFSET + 15])
        if actual != ENTRY_ORIG_BYTES:
            print(f"ERROR: entry bytes mismatch at 0x{ENTRY_FILE_OFFSET:x}")
            print(f"  expected: {ENTRY_ORIG_BYTES.hex()}")
            print(f"  actual:   {actual.hex()}")
            return 1
    if not cave_already:
        actual = bytes(data[CAVE_FILE_OFFSET : CAVE_FILE_OFFSET + 22])
        if actual != CAVE_ORIG_BYTES:
            print(f"ERROR: code cave at 0x{CAVE_FILE_OFFSET:x} is not zero-padded")
            return 1

    # Spin-loop precondition: either post-focus-skip state or original cmp+jz.
    for off in SPIN_LOOP_CMP_OFFSETS:
        actual = bytes(data[off : off + 13])
        if actual == SPIN_PATCHED_BYTES:
            continue  # already patched
        if actual == SPIN_ORIG_AFTER_FOCUS_SKIP:
            continue  # focus-skip applied, ready to overwrite
        if actual == SPIN_ORIG_PRE_FOCUS_SKIP[off]:
            print(
                f"warn: ra-focus-skip-patch.py not yet applied at 0x{off:x} — proceeding"
            )
            continue
        print(f"ERROR: unexpected bytes at spin-loop site 0x{off:x}: {actual.hex()}")
        return 1

    if dry_run:
        print(
            f"  DRY RUN: entry detour, code cave, {len(SPIN_LOOP_CMP_OFFSETS)} spin-loop rewrites"
        )
        return 0

    backup = path + ".game_in_focus_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[ENTRY_FILE_OFFSET : ENTRY_FILE_OFFSET + 15] = ENTRY_PATCHED_BYTES
    data[CAVE_FILE_OFFSET : CAVE_FILE_OFFSET + 22] = CAVE_PATCHED_BYTES
    for off in SPIN_LOOP_CMP_OFFSETS:
        data[off : off + 13] = SPIN_PATCHED_BYTES

    print(f"  Patched entry at 0x{ENTRY_FILE_OFFSET:x} -> jmp 0x5CC6BF")
    print(
        f"  Patched code cave at 0x{CAVE_FILE_OFFSET:x} ({len(CAVE_PATCHED_BYTES)} bytes)"
    )
    print(
        f"  Rewrote {len(SPIN_LOOP_CMP_OFFSETS)} spin-loop cmp+nops -> mov [GIF],1 + nops"
    )

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: game-in-focus pin applied ({out_digest[:16]}…)")
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
