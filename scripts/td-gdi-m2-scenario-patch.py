#!/usr/bin/env python3
"""
TIM-807 — Binary patch to unlock Scenario=2 in CnC95.EXE for GDI Mission 2.

Problem: the CnCNet TD build hardcodes Scenario=1 in Select_Game()'s
SEL_START_NEW_GAME case (INIT.CPP:83 in the CnCNet fork). The strategic map
only shows Mission 1 nodes, preventing capture of GDI Mission 2 frame-level
reference traces.

Patch strategy: find the `mov dword [Scenario], 1` instruction and change the
immediate value from 1 to 2.  The instruction is:
    C7 05 <Scenario_addr> 01 00 00 00  →  C7 05 <Scenario_addr> 02 00 00 00

How to find the offset (one-time):
  The Scenario variable is an `unsigned` (4 bytes) in .bss.  Its address is
  not yet determined.  To find it at runtime:
    1.  Start C&C95.EXE under winedbg --gdb
    2.  Let the game run for a few seconds, then attach gdb
    3.  Search .bss (0x530000–0x5a3000) for the Scenario value (initially 0,
        becomes 1 after Select_Game begins; or search for 2 if running GDI M2)
    4.  Set watchpoint: awatch *<address>
    5.  Restart the process and note the instruction that writes 1 to Scenario
    6.  Update PATCH_OFFSET below with that instruction's file offset

  Until then, this script will report an error when PATCH_OFFSET is unset (0).

Chain order: focus-skip → game-in-focus → vqa-skip → activateapp → ddmode
             → setcoop-hwnd → ioport → side-preview-skip → scenario-patch

Expected input SHA-256 (after side-preview-skip):
  700e61a8fba5b23a4c8a2f666d4526e3de8303d53489e01b0b525ff3cb7c9acc
"""

import sys
import hashlib
import shutil
import os

# ── Configuration ────────────────────────────────────────────────────────────

# TODO: Set this to the file offset of the `mov dword [Scenario], 1` instruction
# The instruction bytes at this offset should start with: C7 05 <addr> 01 00 00 00
PATCH_OFFSET = 0  # <<<< SET ME AFTER RUNTIME ANALYSIS

# Value to patch from and to
OLD_VALUE = 1
NEW_VALUE = 2

# Known-good input SHA-256 (after td-side-preview-skip-patch.py)
ACCEPTED_INPUT_SHA256 = [
    "700e61a8fba5b23a4c8a2f666d4526e3de8303d53489e01b0b525ff3cb7c9acc",
]

# ── Implementation ───────────────────────────────────────────────────────────

def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def patch(path: str) -> int:
    if PATCH_OFFSET == 0:
        print(f"ERROR: PATCH_OFFSET is not set in {__file__}")
        print(f"  See script header for instructions on finding the right offset.")
        return 1

    if not os.path.exists(path):
        print(f"ERROR: {path} not found")
        return 1

    with open(path, 'rb') as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    # Idempotency
    guard_byte_off = PATCH_OFFSET + 6  # immediate value byte position
    if data[guard_byte_off] == NEW_VALUE:
        print(f"{path}: scenario patch already applied (Scenario={NEW_VALUE}) — skipping")
        return 0

    # Verify input hash (warn but don't fail if testing)
    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"WARNING: unexpected input SHA-256 {digest[:16]}…")
        print(f"  Expected: {ACCEPTED_INPUT_SHA256[0][:16]}…")
        print(f"  Apply prerequisite patches in order first")
        # Continue for development testing

    # Verify we're patching the right instruction
    expected_opcode = data[PATCH_OFFSET:PATCH_OFFSET+2]
    if expected_opcode != b'\xc7\x05':
        print(f"ERROR: instruction at 0x{PATCH_OFFSET:x} is not C7 05 (mov dword [mem], imm32)")
        print(f"  Found: {expected_opcode.hex()}")
        return 1

    if data[guard_byte_off] != OLD_VALUE:
        print(f"ERROR: byte at 0x{guard_byte_off:x} is {data[guard_byte_off]:#x}, expected {OLD_VALUE:#x}")
        print(f"  This instruction writes {data[guard_byte_off]}, not {OLD_VALUE}")
        return 1

    # Backup
    backup = path + ".scenario_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    # Apply
    data[guard_byte_off] = NEW_VALUE

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: Scenario={OLD_VALUE} → Scenario={NEW_VALUE} patch applied")
    print(f"  Output SHA-256: {out_digest}")
    return 0


if __name__ == "__main__":
    paths = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not paths:
        paths = ["/opt/tiberiandawn/C&C95.EXE"]
    rc = 0
    for p in paths:
        try:
            rc |= patch(p)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
            rc = 1
    sys.exit(rc)
