#!/usr/bin/env python3
"""
TIM-save-patch — Binary patches for RA95.EXE to auto-boot into any
mission on Normal difficulty.

When combined with vqa-skip (VQA movies skip), cdlabel (CurrentCD=0,
Allies), and ra-scenario-patch (target scenario name), the game will:

  Boot → VQAs skip → menu bypassed → DIFF_NORMAL → no faction dialog
  → "SCG01EA.INI" (patched to target) → mission loads

Six patches to Select_Game() in the RA95.EXE binary:

  1. selection=SEL_NONE(8) → selection=SEL_START_NEW_GAME(1)
     Redirect the normal cold-start path into the new-game handler instead of
     drawing the main menu. This is the critical zero-input mission-start patch.

  2. selection=SEL_MULTIPLAYER(4) → selection=SEL_START_NEW_GAME(1)
     Redirect the alternate non-normal-session path as well, so returning from
     a previous mode cannot fall back to the menu during capture.

  3. NOP je after testb IsFromInstall in SEL_START_NEW_GAME handler.
     Always takes the DIFF_NORMAL branch — skips Fetch_Difficulty dialog.

  4. Change jne to jmp after second IsFromInstall test.
     Always jumps to the Choose_Side path (Play_Movie call which
     vqa-skip already NOPs) instead of the faction WWMessageBox.

  5. Patch jne after Choose_Side returns (CurrentCD flag check).
     By default this NOPs the branch to force the Allied/SCG01EA.INI string
     path.  With --side soviet it becomes an unconditional jump to the
     Soviet/SCU01EA.INI string path.  ra-scenario-patch replaces the chosen
     string with the target mission name.

  6. Set the runtime Special.IsFromInstall bit at the first install check.
     Several startup branches key off this global beyond the patched decision
     points; setting it makes RA95 follow the same install/autostart state that
     the original code was written for.

Usage (apply after vqa-skip + cdlabel + game-in-focus):
  python3 scripts/ra-autostart-patch.py RA95.EXE

Must run AFTER all other patches (vqa-skip, game-in-focus, cdlabel).
"""

import argparse
import hashlib
import os
import shutil
import sys

print(
    "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
    file=sys.stderr,
)


# Core patches: (VA, expected_bytes, replacement_bytes)
# Each modifies one decision point in Select_Game().
PATCHES = [
    # 0. Convert the first install-mode test into an install-mode setter.
    #    Same length as the original `test byte ptr [Special], 4`, and it leaves
    #    ZF clear so the following `je` falls through to the install setup call.
    #    VA 0x4fd00e: test byte [0x655d0c], 4  →  or byte [0x655d0c], 4
    (
        0x004FD00E,
        b"\xf6\x05\x0c\x5d\x65\x00\x04",
        b"\x80\x0d\x0c\x5d\x65\x00\x04",
    ),
    # 1. selection = SEL_START_NEW_GAME (value 1) instead of SEL_NONE (value 8).
    #    This is the normal cold-start path when Session.Type == GAME_NORMAL.
    #    VA 0x4fd4fe: mov esi, 8   →  mov esi, 1
    (0x004FD4FE, b"\xbe\x08\x00\x00\x00", b"\xbe\x01\x00\x00\x00"),
    # 2. selection = SEL_START_NEW_GAME (value 1) instead of SEL_MULTIPLAYER (value 4)
    #    Alternate path used when the previous Session.Type is not GAME_NORMAL.
    #    VA 0x4fd505: mov esi, 4   →  mov esi, 1
    (0x004FD505, b"\xbe\x04\x00\x00\x00", b"\xbe\x01\x00\x00\x00"),
    # 3. NOP je after IsFromInstall->testb in SEL_START_NEW_GAME handler.
    #    VA 0x4fdc67: je +0x68   →  nop nop
    (0x004FDC67, b"\x74\x68", b"\x90\x90"),
    # 4. Change jne->jmp after IsFromInstall test for faction/Choose_Side.
    #    VA 0x4fdd10: jne +0x5d  →  jmp +0x5d
    (0x004FDD10, b"\x75\x5d", b"\xeb\x5d"),
]

SIDE_PATCH = {
    "allied": (
        0x004FDD8F,
        b"\x75\x07",
        b"\x90\x90",
        "5. NOP jne -> always Allies/SCG01EA.INI after Choose_Side",
    ),
    "soviet": (
        0x004FDD8F,
        b"\x75\x07",
        b"\xeb\x07",
        "5. jne->jmp -> always Soviets/SCU01EA.INI after Choose_Side",
    ),
}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def va_to_file_offset(va: int) -> int:
    """Convert VA to PE file offset for this RA95.EXE binary."""
    if 0x00410000 <= va < 0x005CCE00:  # BEGTEXT (.text)
        return 0x00000400 + (va - 0x00410000)
    if 0x005D0000 <= va < 0x00605000:  # DGROUP (.data)
        return 0x001BD200 + (va - 0x005D0000)
    raise ValueError(f"VA 0x{va:08x} not in mapped sections")


def patch(path: str, side: str = "allied", dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    applied = 0
    patch_list = PATCHES + [SIDE_PATCH[side][:3]]
    for va, expected, replacement in patch_list:
        fo = va_to_file_offset(va)
        actual = bytes(data[fo : fo + len(expected)])

        if actual != expected:
            print(f"SKIP VA 0x{va:08x}: expected {expected.hex()}, got {actual.hex()}")
            continue

        if not dry_run:
            data[fo : fo + len(replacement)] = replacement

        old_mnem = disasm_hint(expected, replacement, side)
        print(f"  VA 0x{va:08x} file 0x{fo:08x}: {old_mnem}")
        applied += 1

    if applied == 0:
        print("ERROR: no patches applied — binary incompatible")
        print(f"  SHA-256: {sha256(bytes(data))[:32]}...")
        return 1

    if applied < len(patch_list):
        print(f"WARNING: only {applied}/{len(patch_list)} patches applied")

    if dry_run:
        return 0

    backup = path + ".autostart_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: {applied} patch(es) applied, SHA-256: {out_digest[:16]}...")
    return 0


def disasm_hint(old: bytes, new: bytes, side: str = "allied") -> str:
    """Return a human-readable description of the patch."""
    hints = {
        (
            b"\xbe\x04\x00\x00\x00",
            b"\xbe\x01\x00\x00\x00",
        ): "2. selection = SEL_START_NEW_GAME (1) instead of SEL_MULTIPLAYER (4)",
        (
            b"\xbe\x08\x00\x00\x00",
            b"\xbe\x01\x00\x00\x00",
        ): "1. selection = SEL_START_NEW_GAME (1) instead of SEL_NONE (8)",
        (
            b"\xf6\x05\x0c\x5d\x65\x00\x04",
            b"\x80\x0d\x0c\x5d\x65\x00\x04",
        ): "0. set Special.IsFromInstall at first install-mode check",
        (
            b"\x74\x68",
            b"\x90\x90",
        ): "3. NOP je -> always DIFF_NORMAL (skip Fetch_Difficulty)",
        (
            b"\x75\x5d",
            b"\xeb\x5d",
        ): "4. jne->jmp -> always Choose_Side (skip faction dialog)",
        (b"\x75\x07", b"\x90\x90"): SIDE_PATCH["allied"][3],
        (b"\x75\x07", b"\xeb\x07"): SIDE_PATCH["soviet"][3],
    }
    key = (bytes(old), bytes(new))
    if key in hints:
        return hints[key]
    return f"{old.hex()} -> {new.hex()}"


def restore(path: str) -> int:
    backup = path + ".autostart_orig"
    if not os.path.exists(backup):
        print(f"ERROR: no backup at {backup}")
        return 1
    shutil.copy2(backup, path)
    print(f"{path}: restored from {backup}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    ap.add_argument("--side", choices=("allied", "soviet"), default="allied")
    ap.add_argument("exe_path", nargs="+")
    args = ap.parse_args()

    if args.restore:
        return restore(args.exe_path[0])

    rc = 0
    for p in args.exe_path:
        try:
            rc |= patch(p, side=args.side)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
            rc |= 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
