#!/usr/bin/env python3
"""
TIM-727 — Wine windowed-DirectDraw patch for RA95.EXE (NoCD-patched Allied CD).

Two cooperating patches at the IDirectDraw::Set_Video_Mode call site that make
RA95.EXE create an X11-capturable window under Wine instead of the off-screen
wined3d/OpenGL surface produced by DDSCL_EXCLUSIVE|FULLSCREEN.

Why both patches:
  1. SetCooperativeLevel(DDSCL_EXCLUSIVE|FULLSCREEN) makes Wine route DDraw
     through wined3d's GL path; the resulting surface is never composited into
     X11. Patching it to DDSCL_NORMAL switches Wine to the windowed XPutImage
     path that ffmpeg x11grab / import / scrot can capture.
  2. The retail binary unconditionally calls SetDisplayMode(640, 480, 8) right
     after SetCooperativeLevel. Wine implements that by calling
     NtUserChangeDisplaySettings, which Xvfb refuses (returns -2 / BADMODE).
     The game treats SetDisplayMode failure as fatal: it Releases the
     DirectDrawObject and returns FALSE from Set_Video_Mode, killing init.
     Stubbing the call so it 'returns' DD_OK lets initialization continue and
     the game's existing 640x480 window stays as-is on whatever Xvfb screen
     is presented.

Verified result: with both patches applied, RA95.EXE under Wine 10 + Xvfb
640x480x24 creates a 640x400 'Red Alert' X11 window and reaches the message
loop (xwininfo -root -tree shows the window; ddraw trace shows
SetCooperativeLevel returning DD_OK and CreateSurface succeeding).

Patch sites (one IDirectDraw::Set_Video_Mode function in retail RA95.EXE):
  0x1a4a33  6A 51        push 0x51     ; DDSCL_EXCLUSIVE|FULLSCREEN|ALLOWMODEX
  0x1a4a35  EB 09        jmp +9        ; (skip else branch)
  ...
  0x1a4a3e  6A 11        push 0x11     ; DDSCL_EXCLUSIVE|FULLSCREEN
  0x1a4a40  8B 5D EC     mov ebx, [ebp-0x14]   ; hwnd
  0x1a4a43  53           push ebx
  0x1a4a44  50           push eax              ; this (DirectDrawObject)
  0x1a4a45  FF 52 50     call [edx+0x50]       ; SetCooperativeLevel
  ...
  0x1a4a69  FF 53 54     call [ebx+0x54]       ; SetDisplayMode
  0x1a4a6c  89 45 FC     mov [ebp-4], eax      ; save result

Patches:
  0x1a4a34: 0x51 -> 0x08   (push DDSCL_NORMAL  — ALLOWMODEX branch)
  0x1a4a3f: 0x11 -> 0x08   (push DDSCL_NORMAL  — else branch)
  0x1a4a69-0x1a4a6b: FF 53 54 -> 31 C0 90   (xor eax,eax; nop  — fake DD_OK)

Expected input SHA-256 (NoCD-patched RA95.EXE, see scripts/nocd-patch.py):
  292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf

Expected output SHA-256 (NoCD + windowed-DDraw patched):
  c9e9be012953c2cd0db68f30861dbe29f9709332c832bf8483998200315a1af7
"""

import sys
import hashlib
import shutil

INPUT_SHA256 = "292f858724dc215ea1db7ad36c9617fdd1acd808b4fb01593e0719ff87ee8edf"
PATCHED_SHA256 = "c9e9be012953c2cd0db68f30861dbe29f9709332c832bf8483998200315a1af7"

# (offset, original_byte, patched_byte, description)
SITES = [
    (0x1A4A34, 0x51, 0x08, "DDSCL_EXCLUSIVE|FULLSCREEN|ALLOWMODEX -> DDSCL_NORMAL"),
    (0x1A4A3F, 0x11, 0x08, "DDSCL_EXCLUSIVE|FULLSCREEN -> DDSCL_NORMAL"),
    # Stub SetDisplayMode call as 'xor eax, eax; nop' so Wine never invokes
    # NtUserChangeDisplaySettings (which Xvfb refuses) and Set_Video_Mode
    # continues with the window-bound primary surface.
    (0x1A4A69, 0xFF, 0x31, "SetDisplayMode call -> xor eax,eax (fake DD_OK)"),
    (0x1A4A6A, 0x53, 0xC0, "SetDisplayMode call -> xor eax,eax (cont)"),
    (0x1A4A6B, 0x54, 0x90, "SetDisplayMode call -> nop (cont)"),
]

# Sanity-guard: the SetCooperativeLevel call (right before SetDisplayMode)
# is left intact and at this offset. If a different RA95.EXE build shifts
# things, this guard catches it before we patch the wrong bytes.
CALL_OFFSET = 0x1A4A45
CALL_BYTES = b"\xff\x52\x50"  # call DWORD PTR [edx+0x50] = SetCooperativeLevel


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def patch(path: str, dry_run: bool = False) -> int:
    with open(path, "rb") as f:
        data = bytearray(f.read())

    digest = sha256(bytes(data))
    if digest == PATCHED_SHA256:
        print(f"{path}: already patched ({PATCHED_SHA256[:16]}…)")
        return 0

    if digest != INPUT_SHA256:
        print(f"ERROR: unexpected SHA-256 {digest}")
        print(f"       expected: {INPUT_SHA256}  (NoCD-patched RA95.EXE)")
        print("       run scripts/nocd-patch.py first")
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
    if out_digest != PATCHED_SHA256:
        print(f"ERROR: post-patch SHA-256 mismatch: {out_digest}")
        return 1

    for off, orig, new, why in SITES:
        print(f"  Patched 0x{off:x}: 0x{orig:02x} -> 0x{new:02x}  [{why}]")
    print(f"{path}: patched OK ({out_digest[:16]}…)")
    return 0


if __name__ == "__main__":
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
