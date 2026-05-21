#!/usr/bin/env python3
"""
TIM-727 — Windowed-DirectDraw cooperative-level patch for RA95.EXE.

At the IDirectDraw::Set_Video_Mode call site, change the SetCooperativeLevel
flags from DDSCL_EXCLUSIVE|FULLSCREEN to DDSCL_NORMAL so the game gets a
windowed surface. The pipeline pairs this with cnc-ddraw (loaded as a native
ddraw.dll via WINEDLLOVERRIDES=ddraw=n), which intercepts the subsequent
SetDisplayMode(640,480,8) call and sizes its own X11-backed surface.

The SetDisplayMode call itself is left alone. Earlier revisions of this patch
also stubbed it (to dodge wined3d's NtUserChangeDisplaySettings → Xvfb BADMODE
path), but with cnc-ddraw in place the call routes to cnc-ddraw's vtable and
must reach it for the surface to be sized correctly. Stubbing it produced
half-width, palette-mangled frames.

Patch sites (IDirectDraw::Set_Video_Mode in retail RA95.EXE):
  0x1a4a33  6A 51        push 0x51     ; DDSCL_EXCLUSIVE|FULLSCREEN|ALLOWMODEX
  0x1a4a3e  6A 11        push 0x11     ; DDSCL_EXCLUSIVE|FULLSCREEN
  0x1a4a45  FF 52 50     call [edx+0x50]  ; SetCooperativeLevel
  0x1a4a69  FF 53 54     call [ebx+0x54]  ; SetDisplayMode — left intact

Patches:
  0x1a4a34: 0x51 -> 0x08   (push DDSCL_NORMAL — ALLOWMODEX branch)
  0x1a4a3f: 0x11 -> 0x08   (push DDSCL_NORMAL — else branch)

Expected input SHA-256 (NoCD-patched RA95.EXE, see scripts/ra/ra-nocd-patch.py):
  292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf
"""

import hashlib
import shutil
import sys


def _warn_deprecated() -> None:
    print(
        "WARNING: this standalone patch script is deprecated; use scripts/ra/patch_ra95.py",
        file=sys.stderr,
    )

INPUT_SHA256 = "292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf"

# (offset, original_byte, patched_byte, description)
SITES = [
    (0x1A4A34, 0x51, 0x08, "DDSCL_EXCLUSIVE|FULLSCREEN|ALLOWMODEX -> DDSCL_NORMAL"),
    (0x1A4A3F, 0x11, 0x08, "DDSCL_EXCLUSIVE|FULLSCREEN -> DDSCL_NORMAL"),
]

# Sanity-guard: the SetCooperativeLevel call (right after the push sites) is
# left intact and at this offset. Different RA95.EXE builds may shift; this
# catches a wrong target before we touch bytes.
CALL_OFFSET = 0x1A4A45
CALL_BYTES = b"\xff\x52\x50"  # call DWORD PTR [edx+0x50] = SetCooperativeLevel


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _is_patched(data: bytes) -> bool:
    return all(data[off] == new for off, _, new, _ in SITES)


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    if _is_patched(bytes(data)):
        print(f"{path}: already patched (DDSCL_NORMAL at both sites)")
        return 0

    if digest != INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected: {INPUT_SHA256}  (NoCD-patched RA95.EXE)")
        print("       run scripts/ra/ra-nocd-patch.py first")
        return 1

    if bytes(data[CALL_OFFSET : CALL_OFFSET + 3]) != CALL_BYTES:
        print(
            f"ERROR: call bytes mismatch at 0x{CALL_OFFSET:x}: "
            f"{bytes(data[CALL_OFFSET : CALL_OFFSET + 3]).hex()} != {CALL_BYTES.hex()}"
        )
        return 1

    for off, orig, _, why in SITES:
        if data[off] != orig:
            print(
                f"ERROR: byte at 0x{off:x} is 0x{data[off]:02x}, expected 0x{orig:02x}  [{why}]"
            )
            return 1

    if dry_run:
        for off, orig, new, why in SITES:
            print(
                f"{path}: DRY RUN — would patch 0x{off:x}: 0x{orig:02x} -> 0x{new:02x}  [{why}]"
            )
        return 0

    backup = path + ".ddscl_orig"
    shutil.copy2(path, backup)
    print(f"  Backup: {backup}")

    for off, _, new, why in SITES:
        data[off] = new

    with open(path, "wb") as f:
        f.write(data)

    out_digest = sha256(bytes(data))
    for off, orig, new, why in SITES:
        print(f"  Patched 0x{off:x}: 0x{orig:02x} -> 0x{new:02x}  [{why}]")
    print(f"{path}: patched OK ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
    _warn_deprecated()
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        print(f"Usage: {__file__} <exe-path> [exe-path ...]", file=sys.stderr)
        sys.exit(1)
    dry = "--dry-run" in sys.argv
    paths = args
    rc = 0
    for p in paths:
        try:
            rc |= patch(p, dry_run=dry)
        except FileNotFoundError:
            print(f"SKIP: {p} not found")
    sys.exit(rc)
