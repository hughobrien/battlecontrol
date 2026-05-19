#!/usr/bin/env python3
"""
TIM-763 — Side-preview animation skip patch for C&C95.EXE (Tiberian Dawn).

When the player clicks GDI / NOD on the side-select dialog, C&C95.EXE calls a
"step palette + frame" routine at 0x411254.  Inside that routine, after the
palette is clamped to 6-bit VGA and pushed to the hardware via 0x459afc, this
guarded block runs:

    411283: cmp DWORD PTR [0x5382b8], 0
    41128a: je  0x4112b8                     ; <— conditional skip
    41128c: mov eax, [0x5382bc]               ; current frame index
    411291: inc eax                           ; advance
    411292: mov ecx, 0x10000                  ; 64 KB
    411297: mov edi, 0x54430c                 ; destination framebuffer
    41129c: mov esi, [eax*4 + 0x538124]       ; source = frame_table[idx]
    4112a3: mov [0x5382bc], eax               ; store new index
    4112a8: push edi
    4112a9: mov eax, ecx
    4112ab: shr ecx, 2
    4112ae: rep movsd                          ; <— FAULT when esi == NULL
    4112b0: mov cl, al
    4112b2: and cl, 3
    4112b5: rep movsb

[0x5382b8] is a "preview animation loaded" flag set by the loader at 0x42cd98
when it successfully opens a .VQP preview file (e.g. NOD1PRE.VQP / GDI1.VQP).
[0x538124+4*idx] is the per-frame pointer table (max 100 entries), populated
by the same loader with 64 KB blocks read out of the .VQP.

In the [TIM-724](/TIM/issues/TIM-724) wine-gdi-m1.sh harness, GDI1.VQP and NOD1PRE.VQP
are 0-byte stubs (we have the disk MIX files but not the per-side preview VQPs
that live on the real game CD).  The loader's path on a 0-byte file is:

    1. fopen succeeds (the stub exists)
    2. read 4-byte count → 0 (file is empty)
    3. test ebp, ebp / jle 0x42ce91 → SKIP the allocation loop
    4. mov [0x5382b8], 1                     ; sets the flag anyway
    5. mov [0x5382bc], 0                     ; resets index to 0

So the flag is asserted while the table stays all-NULL.  The next palette step
then reads frame_table[1] == NULL and crashes at 0x4112ae.

The minimal fix is to convert the conditional skip at 0x41128a into an
unconditional jump, so the consumer always bypasses the preview-frame copy
regardless of the flag.  The palette work above and the call to 0x4cd100
below run as normal, so the side-select dialog still renders — it just
doesn't overlay a preview animation.

Patch site:
  file=0x168a  VA=0x41128a
  0x74 0x2c   je  0x4112b8     ; conditional
  ↓ patched ↓
  0xeb 0x2c   jmp 0x4112b8     ; unconditional

Only the opcode byte changes (0x74 → 0xeb); the rel8 displacement stays 0x2c.

Expected input SHA-256 set:
    3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627  # original
    42664f2aa13fe1dc661326ecbf01ad7c6b8c0c2e7b1bd1bc01938fa2e98e31d0  # after td-ioport-patch.py
Output SHA-256:
    (recorded after first apply — see PATCHED_OUTPUT_SHA256_AFTER_IOPORT)
"""

import sys
import hashlib
import shutil

# Any chain state where byte at PATCH_OFFSET is still the original 0x74.
ACCEPTED_INPUT_SHA256 = {
    # Pristine binary
    "3ead491cf25eed9865a2d088afb00941900e6f6719b550199ee35e9b4ca01627",
    # End of the wine-gdi-m1.sh chain (after td-ioport-patch.py)
    "42664f2aa13fe1dc661326ecbf01ad7c6b8c0c2e7b1bd1bc01938fa2e98e31d0",
}

# After applying to the full chain (input = 42664f2a…, post td-ioport-patch.py)
PATCHED_OUTPUT_SHA256_AFTER_IOPORT = (
    "700e61a8fba5b23a4c8a2f666d4526e3de8303d53489e01b0b525ff3cb7c9acc"
)

PATCH_OFFSET = 0x168A  # VA 0x41128a — je after [0x5382b8] flag check
ORIGINAL_BYTE = 0x74  # je rel8
PATCHED_BYTE = 0xEB  # jmp rel8 (same rel8 displacement 0x2c → target 0x4112b8)
REL8 = 0x2C  # displacement preserved unchanged

# Signature bytes immediately preceding the patch site (the cmp [0x5382b8],0)
SITE_SIG_BEFORE = b"\x83\x3d\xb8\x82\x53\x00\x00"  # cmp DWORD PTR [0x5382b8], 0
# Signature bytes immediately following (rel8 + start of the dead-code mov)
SITE_SIG_AFTER = b"\x2c\xa1\xbc\x82\x53\x00"  # 0x2c + mov eax,[0x5382bc]


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))

    if data[PATCH_OFFSET] == PATCHED_BYTE:
        print(f"{path}: already patched (td-side-preview-skip)")
        return 0

    if digest not in ACCEPTED_INPUT_SHA256:
        print(f"  WARNING: unexpected input SHA-256 {digest}")
        print("  Accepted inputs:")
        for h in sorted(ACCEPTED_INPUT_SHA256):
            print(f"    {h}")
        print("  Proceeding with byte-signature verification only.")

    sig_before = bytes(data[PATCH_OFFSET - 7 : PATCH_OFFSET])
    if sig_before != SITE_SIG_BEFORE:
        print(f"ERROR: signature-before mismatch at 0x{PATCH_OFFSET - 7:x}")
        print(f"       got:      {sig_before.hex()}")
        print(f"       expected: {SITE_SIG_BEFORE.hex()}")
        return 1

    if data[PATCH_OFFSET] != ORIGINAL_BYTE:
        print(
            f"ERROR: byte at 0x{PATCH_OFFSET:x} is 0x{data[PATCH_OFFSET]:02x}, expected 0x{ORIGINAL_BYTE:02x}"
        )
        return 1

    sig_after = bytes(data[PATCH_OFFSET + 1 : PATCH_OFFSET + 7])
    if sig_after != SITE_SIG_AFTER:
        print(f"ERROR: signature-after mismatch at 0x{PATCH_OFFSET + 1:x}")
        print(f"       got:      {sig_after.hex()}")
        print(f"       expected: {SITE_SIG_AFTER.hex()}")
        return 1

    if dry_run:
        print(f"  DRY RUN: would write 0xeb at 0x{PATCH_OFFSET:x} (je → jmp 0x4112b8)")
        return 0

    backup = path + ".td_side_preview_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    data[PATCH_OFFSET] = PATCHED_BYTE
    print(
        f"  Patched 0x{PATCH_OFFSET:x}: je 0x4112b8 → jmp 0x4112b8 (skip NULL preview-frame copy)"
    )

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    print(f"{path}: td-side-preview-skip applied ({out_digest[:16]}…)")
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
