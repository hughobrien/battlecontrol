#!/usr/bin/env python3
"""
TIM-821 — GDI Mission 2 Scenario patch.
Patches C&C95.EXE so that Scenario=2 loads Mission 2 directly without Map_Selection.

Two patches:
  Patch A (offset 0x6754B): Change `mov byte [Scenario], 1` → `mov byte [Scenario], 2`
    This sets Scenario=2 (GDI Mission 2) instead of Scenario=1.

  Patch B (offset 0x68DAC): Change `jne +0x57` (75 57) → `jmp +0` (EB 00) at the
    dh==5 comparison in Start_Scenario's state mapper (function at 0x478558). This
    makes the function always fall through to the "skip map, load directly" path.
    
    Without Patch B, Scenario=2 triggers Map_Selection because the code's
    selection-mode value (dh) is not 5. The `jne` redirects to the Map_Selection
    path (dh==6 branch). Changing to `jmp +0` makes it fall through to the dh==5
    path which sets state=2 and loads the mission directly.

    Wine reference: The check is at dlls/ntdll/... — not applicable; this is a
    binary patch on the original PE32, not a Wine component.

Usage:
    python3 scripts/td-gdi-m2-scenario-patch.py /path/to/C&C95.EXE
"""

import sys

PATCH_A_OFFSET = 0x6754B
PATCH_A_ORIG = 0x01   # Scenario = 1
PATCH_A_NEW = 0x02    # Scenario = 2

PATCH_B_OFFSET = 0x68DAC
PATCH_B_ORIG_BYTES = bytes([0x75, 0x57])   # jne +0x57 → dh==6 (Map_Selection) check
PATCH_B_NEW_BYTES  = bytes([0xEB, 0x00])   # jmp +0 → dh==5 (skip map) path

def patch(exe_path: str) -> None:
    with open(exe_path, "rb") as f:
        data = bytearray(f.read())

    # Verify Patch A
    if data[PATCH_A_OFFSET] != 0xC6 or data[PATCH_A_OFFSET+1] != 0x05:
        print(f"ERROR: Unexpected bytes at 0x{PATCH_A_OFFSET:X}: "
              f"{' '.join(f'{b:02x}' for b in data[PATCH_A_OFFSET:PATCH_A_OFFSET+7])}")
        sys.exit(1)
    if data[PATCH_A_OFFSET + 6] != PATCH_A_ORIG:
        print(f"WARNING: Patch A already applied or unexpected value: "
              f"expected {PATCH_A_ORIG:#04x}, got {data[PATCH_A_OFFSET + 6]:#04x}")

    # Verify Patch B (2 bytes)
    cur_b = bytes(data[PATCH_B_OFFSET:PATCH_B_OFFSET+2])
    if cur_b != PATCH_B_ORIG_BYTES:
        print(f"WARNING: Patch B already applied or unexpected bytes: "
              f"expected {' '.join(f'{b:02x}' for b in PATCH_B_ORIG_BYTES)}, "
              f"got {' '.join(f'{b:02x}' for b in cur_b)}")

    # Apply patches
    data[PATCH_A_OFFSET + 6] = PATCH_A_NEW
    data[PATCH_B_OFFSET:PATCH_B_OFFSET+2] = PATCH_B_NEW_BYTES

    with open(exe_path, "wb") as f:
        f.write(data)

    print(f"Patch A applied: offset 0x{PATCH_A_OFFSET:X}  0x{PATCH_A_ORIG:02X} → 0x{PATCH_A_NEW:02X}  (Scenario=2)")
    print(f"Patch B applied: offset 0x{PATCH_B_OFFSET:X}  "
          f"{' '.join(f'{b:02x}' for b in PATCH_B_ORIG_BYTES)} → "
          f"{' '.join(f'{b:02x}' for b in PATCH_B_NEW_BYTES)}  (skip Map_Selection)")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} /path/to/C&C95.EXE")
        sys.exit(1)
    patch(sys.argv[1])
