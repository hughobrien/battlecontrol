#!/usr/bin/env python3
"""
TIM-869 — Replace the `SC%c%02d%c%c.INI` format string in C&C95.EXE with a
hardcoded scenario name so Set_Scenario_Name always produces the target
mission regardless of the dynamic parameters.

Unlike RA95.EXE which hardcodes "SCG01EA.INI"/"SCU01EA.INI" string literals,
C&C95.EXE uses a printf format string at file offset 0xdb375.  This script
replaces it with a 16-byte fixed name (12 chars + 4 nulls), causing every
call to Set_Scenario_Name to produce the same scenario INI name.

The format string is in .rdata and is untouched by the existing TIM-743/
TIM-747 code patches (they only modify .text), so this patch can run before
or after them.

Usage:
  python3 scripts/td-scenario-patch.py C&C95.EXE SCG02EA    # GDI M2
  python3 scripts/td-scenario-patch.py C&C95.EXE SCB01EA    # Nod M1
  python3 scripts/td-scenario-patch.py C&C95.EXE --restore
"""

import argparse
import hashlib
import os
import shutil
import sys


FMT_OFFSET = 0xdb375
FMT_ORIGINAL = b"SC%c%02d%c%c.INI"
MAX_FIXED_LEN = 16


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, target: str) -> int:
    target = target.upper().strip()
    if not target.endswith(".INI"):
        target += ".INI"
    if len(target) > 12:
        print(f"ERROR: scenario name too long: '{target}' (max 12 chars)")
        return 1

    with open(path, 'rb') as f:
        data = bytearray(f.read())

    actual = bytes(data[FMT_OFFSET:FMT_OFFSET + len(FMT_ORIGINAL)])
    if actual != FMT_ORIGINAL:
        print(f"ERROR: unexpected bytes at 0x{FMT_OFFSET:x}: {actual.hex()}")
        print(f"       expected: {FMT_ORIGINAL.hex()}")
        try:
            current = actual.rstrip(b'\x00').decode('ascii')
            print(f"       current value: '{current}' (already patched)")
        except UnicodeDecodeError:
            pass
        return 1

    fixed = target.encode('ascii')[:12]
    fixed_padded = fixed.ljust(MAX_FIXED_LEN, b'\x00')

    backup = path + ".scenario_orig"
    if not os.path.exists(backup):
        shutil.copy2(path, backup)
        print(f"  Backup: {backup}")

    data[FMT_OFFSET:FMT_OFFSET + MAX_FIXED_LEN] = fixed_padded

    with open(path, 'wb') as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: scenario patch applied: {FMT_ORIGINAL.decode()} -> {fixed.decode()}")
    print(f"  new SHA-256: {out_digest[:16]}...")
    return 0


def restore(path: str) -> int:
    backup = path + ".scenario_orig"
    if not os.path.exists(backup):
        print(f"ERROR: no backup found at {backup}")
        return 1
    shutil.copy2(backup, path)
    print(f"{path}: restored from {backup}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('exe_path', help='Path to C&C95.EXE')
    ap.add_argument('scenario', nargs='?', default=None,
                    help='Target scenario name (e.g. SCG02EA, SCB01EA)')
    ap.add_argument('--restore', action='store_true',
                    help='Restore from .scenario_orig backup')
    args = ap.parse_args()

    if args.restore:
        return restore(args.exe_path)
    if not args.scenario:
        print("ERROR: specify a scenario name or --restore")
        return 1
    return patch(args.exe_path, args.scenario)


if __name__ == "__main__":
    sys.exit(main())
