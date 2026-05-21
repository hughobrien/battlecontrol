#!/usr/bin/env python3
"""
TIM-735 — quarantined legacy patch originally believed to pin GameInFocus.

This standalone script is retained only for historical reproduction. It was
written from an incorrect address assumption: the patched address behaves as
Session.Type, not GameInFocus. Normal capture must use the unified mission
patcher instead:

  python3 scripts/ra/patch_ra95.py mission RA95.EXE --scenario SCG02EA.INI

Direct execution is blocked by default. To reproduce the historical patch for
diagnosis only, set:

  RA_ALLOW_QUARANTINED_GAME_IN_FOCUS=1
"""

import hashlib
import os
import shutil
import sys


def _warn_deprecated() -> None:
    print(
        "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
        file=sys.stderr,
    )


def _check_quarantine_override() -> bool:
    if os.environ.get("RA_ALLOW_QUARANTINED_GAME_IN_FOCUS") == "1":
        return True
    print(
        "ERROR: ra-game-in-focus-patch.py is quarantined because it writes to "
        "Session.Type, not GameInFocus.",
        file=sys.stderr,
    )
    print(
        "Use scripts/ra/patch_ra95.py for normal captures. For historical "
        "reproduction only, set RA_ALLOW_QUARANTINED_GAME_IN_FOCUS=1.",
        file=sys.stderr,
    )
    return False

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
    _warn_deprecated()
    if not _check_quarantine_override():
        sys.exit(1)
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
