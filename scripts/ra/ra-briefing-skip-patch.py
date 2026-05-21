#!/usr/bin/env python3
"""Skip RA95's text mission briefing dialog for Wine capture builds.

Some Red Alert missions do not have a briefing VQA and instead open the
blocking text mission briefing from Start_Scenario(). Synthetic input through
Wine is unreliable on that dialog, which makes frame-exact capture fail before
gameplay starts. The capture harness already skips VQA movies; this patch makes
the text briefing path match by no-oping the single Restate_Mission call in
Start_Scenario().
"""

import hashlib
import shutil
import sys

print(
    "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
    file=sys.stderr,
)


CALL_VA = 0x00542E96
EXPECTED = bytes.fromhex("e8a1110000")
PATCHED = bytes.fromhex("9090909090")


def va_to_file_offset(va: int) -> int:
    if 0x00410000 <= va < 0x005CCE00:
        return 0x00000400 + (va - 0x00410000)
    raise ValueError(f"VA 0x{va:08x} not in .text")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    off = va_to_file_offset(CALL_VA)
    actual = bytes(data[off : off + len(EXPECTED)])
    if actual == PATCHED:
        print(f"{path}: already patched")
        return 0
    if actual != EXPECTED:
        print(
            f"ERROR: unexpected bytes at VA 0x{CALL_VA:08x}: "
            f"{actual.hex()} != {EXPECTED.hex()}"
        )
        print(f"  SHA-256: {sha256(bytes(data))[:32]}...")
        return 1

    backup = path + ".briefing_skip_orig"
    shutil.copy2(path, backup)
    data[off : off + len(PATCHED)] = PATCHED

    with open(path, "wb") as f:
        f.write(data)

    print(
        f"{path}: text briefing Restate_Mission call no-op at "
        f"VA 0x{CALL_VA:08x}, SHA-256: {sha256(bytes(data))[:16]}..."
    )
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <RA95.EXE> [RA95.EXE ...]", file=sys.stderr)
        return 1
    rc = 0
    for path in sys.argv[1:]:
        rc |= patch(path)
    return rc


if __name__ == "__main__":
    sys.exit(main())
