#!/usr/bin/env python3
"""
TIM-747 — Stub SetDisplayMode in C&C95.EXE (CnCNet build).

The CnCNet binary already uses DDSCL_NORMAL (windowed DDraw), so only the
SetDisplayMode stub is needed — no SetCooperativeLevel patch required.

⚠️  TIM-1100 (2026-05-19): the analogous RA patch (`ra-ddscl-patch.py`) used to
stub SetDisplayMode for the same Wine/Xvfb reason. Once the RA pipeline
standardised on cnc-ddraw (loaded as native ddraw.dll via
`WINEDLLOVERRIDES=ddraw=n`), the stub became actively harmful: cnc-ddraw's
`IDirectDraw::SetDisplayMode` interceptor needs the call to reach it so it can
size its X11-backed surface, otherwise the framebuffer comes back half-width
with a mangled palette. The TD pipeline (`scripts/td/wine-gdi-m1.sh`) loads
cnc-ddraw too, so this patch likely needs the same treatment — verify with a
TD parity capture before relying on the rendering.

Why (historical context, pre-cnc-ddraw):
  C&C95.EXE calls IDirectDraw::SetDisplayMode(640, 400, 8) during init.
  Wine routes that call to NtUserChangeDisplaySettings, which Xvfb refuses
  with DISP_CHANGE_FAILED (-2).  TD treats any non-DD_OK result as fatal:
  it releases the DirectDraw object, shows a MessageBoxA warning, and exits.
  Stubbing the call so it returns DD_OK (xor eax,eax = 0) lets initialization
  continue with the existing 640x400 window that Xvfb already presents.

Stack-balance design:
  IDirectDraw::SetDisplayMode is a stdcall method — the callee cleans up its
  arguments from the stack (`ret 16` for 4 args: this+width+height+bpp).
  Simply replacing the `call` with `xor eax,eax; nop` leaves those 4 pushes
  on the stack, corrupting the epilog and causing TD to return to address 0x190
  (= 400 = screen height) instead of the real caller.  The fix NOPs out all
  4 push instructions as well, keeping the stack balanced.

Patch sites (inside the DDraw init function, Set_Video_Mode equivalent):
  0xbc6b9  FF 53 50  call [ebx+0x50] ; SetCooperativeLevel (guard: intact)
  ...
  0xbc6c3  57        push %edi       ; bpp=8 arg    → NOP
  0xbc6c8  51        push %ecx       ; height arg   → NOP
  0xbc6ce  56        push %esi       ; width arg    → NOP
  0xbc6d1  50        push %eax       ; this (DD*)   → NOP
  0xbc6d2  FF 53 54  call [ebx+0x54] ; SetDisplayMode → xor eax,eax; nop
  0xbc6d5  85 C0     test %eax,%eax  ; (unchanged: re-checks eax=0)
  0xbc6d7  74 17     je <success>    ; (unchanged: ZF=1 → taken)

Expected input SHA-256 (C&C95.EXE after TIM-743 patch chain):
  46a6d902963e4f613d550704877f4abae173b4c2e43d6a478518b2fba6fcda4a

Expected output SHA-256:
  46dc1eb4a81143610161e4f1930aec7a95a76f0b367e99454d08b01a6a3ccc9c
"""

import sys
import hashlib
import shutil

INPUT_SHA256 = "46a6d902963e4f613d550704877f4abae173b4c2e43d6a478518b2fba6fcda4a"
PATCHED_SHA256 = "46dc1eb4a81143610161e4f1930aec7a95a76f0b367e99454d08b01a6a3ccc9c"

# (offset, original_byte, patched_byte, description)
SITES = [
    # NOP the 4 push instructions that would have been args to SetDisplayMode.
    # Without these NOPs, the callee stack-cleanup (ret 16) is never executed
    # and the function's epilog returns to address 0x190 (= height 400 pushed
    # as arg) instead of the real caller — a guaranteed crash.
    (0xBC6C3, 0x57, 0x90, "NOP push %edi (bpp arg to SetDisplayMode)"),
    (0xBC6C8, 0x51, 0x90, "NOP push %ecx (height arg to SetDisplayMode)"),
    (0xBC6CE, 0x56, 0x90, "NOP push %esi (width arg to SetDisplayMode)"),
    (0xBC6D1, 0x50, 0x90, "NOP push %eax (this/IDirectDraw* arg)"),
    # Stub SetDisplayMode call as 'xor eax,eax; nop' so Wine never invokes
    # NtUserChangeDisplaySettings (which Xvfb refuses) and init continues.
    (0xBC6D2, 0xFF, 0x31, "SetDisplayMode call -> xor eax,eax (fake DD_OK)"),
    (0xBC6D3, 0x53, 0xC0, "SetDisplayMode call -> xor eax,eax (cont)"),
    (0xBC6D4, 0x54, 0x90, "SetDisplayMode call -> nop"),
]

# Sanity guard: SetCooperativeLevel call immediately before SetDisplayMode.
# If a different C&C95.EXE build shifts things, this guard catches it.
GUARD_OFFSET = 0xBC6B9
GUARD_BYTES = b"\xff\x53\x50"  # call DWORD PTR [ebx+0x50] = SetCooperativeLevel


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
        print(f"       expected: {INPUT_SHA256}  (C&C95.EXE after TIM-743 patch chain)")
        print("       apply td-focus-skip-patch.py, td-game-in-focus-patch.py,")
        print("       td-vqa-skip-patch.py, td-activateapp-patch.py first")
        return 1

    if bytes(data[GUARD_OFFSET : GUARD_OFFSET + 3]) != GUARD_BYTES:
        print(
            f"ERROR: guard bytes mismatch at 0x{GUARD_OFFSET:x}: "
            f"{bytes(data[GUARD_OFFSET : GUARD_OFFSET + 3]).hex()} != {GUARD_BYTES.hex()}"
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

    backup = path + ".ddmode_orig"
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
