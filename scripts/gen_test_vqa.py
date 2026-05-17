#!/usr/bin/env python3
"""
Generate a minimal synthetic VQA test file for the pixel-diff CI harness.

The generated file exercises:
  - CBF0 full codebook with 4 entries
  - VPT0 pointer array with regular codebook lookups
  - Solid-colour marker (hi=0xFF for blockH=4) via pre-filled codebook range
  - 6-bit VGA palette (CPL0)
  - CBPZ partial codebook (cbParts=1, completes immediately, new CB active next frame)

Output: e2e/goldens/vqa/test.vqa  (8×8 pixels, blockW=4, blockH=4, 3 frames)

Usage: python3 scripts/gen_test_vqa.py [output_path]
"""

import struct
import sys
import os


def be32(n: int) -> bytes:
    return struct.pack(">I", n)


def le16(n: int) -> bytes:
    return struct.pack("<H", n)


def chunk(tag: bytes, body: bytes) -> bytes:
    """Wrap body in a VQA IFF chunk; pad to even length."""
    assert len(tag) == 4
    data = tag + be32(len(body)) + body
    if len(body) & 1:
        data += b"\x00"
    return data


def lcw_encode_literal(data: bytes) -> bytes:
    """
    Minimal LCW (Format80) encoder: encodes as literal runs only.
    Each literal run: opcode 0x80|n (1-byte count), n payload bytes.
    Terminates with 0x80 (end marker).
    """
    out = bytearray()
    i = 0
    while i < len(data):
        run_len = min(63, len(data) - i)
        out.append(0x80 | run_len)  # literal run opcode
        out.extend(data[i : i + run_len])
        i += run_len
    out.append(0x80)  # end marker
    return bytes(out)


def make_vqa(path: str) -> None:
    """
    Build a synthetic 8×8 VQA with 3 frames and write it to path.

    Canvas: 8×8 pixels, 4×4 blocks → 2×2 = 4 blocks per frame.
    Palette: 6-bit VGA colours (0-63 per channel); indices 1-5 are colourful.
    cbParts=1 so CBPZ completes within one frame (tests partial-codebook path).

    Frame 1 — CBFZ full codebook + VPTZ regular lookup:
      Block 0 (top-left):     entry 0 = solid palette[1] (red)
      Block 1 (top-right):    entry 1 = solid palette[2] (green)
      Block 2 (bottom-left):  entry 2 = solid palette[3] (blue)
      Block 3 (bottom-right): entry 3 = checkerboard palette[1]/palette[2]

    Frame 2 — CBPZ partial codebook + VPTZ solid-colour pointers (hi=0xFF):
      Block 0: lo=1, hi=0xFF → solid palette[1] via pre-filled codebook
      Block 1: lo=2, hi=0xFF → solid palette[2] via pre-filled codebook
      Block 2: lo=3, hi=0xFF → solid palette[3] via pre-filled codebook
      Block 3: lo=4, hi=0xFF → solid palette[4] (yellow) via pre-filled codebook
      (CBPZ completes immediately since cbParts=1; new codebook active next frame)

    Frame 3 — VPTZ using new codebook from frame-2 CBPZ:
      New codebook entry 0 = solid palette[5] (cyan), entries 1-3 = black.
      Block 0-3: all use entry 0 from new codebook → solid cyan
    """
    blockW, blockH = 4, 4
    cbEntry = blockW * blockH  # 16 bytes per codebook entry
    width, height = 8, 8

    # --- Palette (6-bit VGA, 256 * 3 = 768 bytes) ---
    # 6-bit max is 63; 0 and 63 expand to exact 8-bit 0 and 255.
    pal = bytearray(768)
    pal[0 * 3 : 0 * 3 + 3] = [0, 0, 0]  # 0: black
    pal[1 * 3 : 1 * 3 + 3] = [63, 0, 0]  # 1: red    → R=255
    pal[2 * 3 : 2 * 3 + 3] = [0, 63, 0]  # 2: green  → G=255
    pal[3 * 3 : 3 * 3 + 3] = [0, 0, 63]  # 3: blue   → B=255
    pal[4 * 3 : 4 * 3 + 3] = [63, 63, 0]  # 4: yellow
    pal[5 * 3 : 5 * 3 + 3] = [0, 63, 63]  # 5: cyan

    # --- Codebook for frame 1 (4 entries × 16 bytes each) ---
    cb1 = bytearray(4 * cbEntry)
    # Entry 0: all palette[1] (red)
    for i in range(cbEntry):
        cb1[0 * cbEntry + i] = 1
    # Entry 1: all palette[2] (green)
    for i in range(cbEntry):
        cb1[1 * cbEntry + i] = 2
    # Entry 2: all palette[3] (blue)
    for i in range(cbEntry):
        cb1[2 * cbEntry + i] = 3
    # Entry 3: checkerboard palette[1]/palette[2] (red/green)
    for row in range(blockH):
        for col in range(blockW):
            cb1[3 * cbEntry + row * blockW + col] = 1 if (row + col) % 2 == 0 else 2

    # --- Frame 1 VPTZ: entries 0,1,2,3 from old codebook ---
    vpt1_lo = bytes([0, 1, 2, 3])
    vpt1_hi = bytes([0, 0, 0, 0])
    vpt1 = vpt1_lo + vpt1_hi

    # --- Frame 2: solid-colour pointers (hi=0xFF), carry new codebook via CBPZ ---
    vpt2_lo = bytes([1, 2, 3, 4])
    vpt2_hi = bytes([0xFF, 0xFF, 0xFF, 0xFF])
    vpt2 = vpt2_lo + vpt2_hi

    # New codebook (cbParts=1 → completes immediately after frame 2 renders)
    # Entry 0: all palette[5] (cyan); entries 1-3: black
    cb2_raw = bytearray(4 * cbEntry)
    for i in range(cbEntry):
        cb2_raw[0 * cbEntry + i] = 5  # cyan

    # --- Frame 3: uses new codebook from frame-2 CBPZ ---
    # All 4 blocks → entry 0 = solid cyan
    vpt3_lo = bytes([0, 0, 0, 0])
    vpt3_hi = bytes([0, 0, 0, 0])
    vpt3 = vpt3_lo + vpt3_hi

    # Compress VPT data (ffmpeg requires VPTZ; VPT0 is not supported by its decoder)
    vpt1z = lcw_encode_literal(vpt1)
    vpt2z = lcw_encode_literal(vpt2)
    vpt3z = lcw_encode_literal(vpt3)

    # Compress codebooks (use CBFZ/CBPZ for cross-decoder compatibility)
    cb1z = lcw_encode_literal(bytes(cb1))
    cb2z = lcw_encode_literal(bytes(cb2_raw))

    # Assemble VQFR bodies
    cpl0 = chunk(b"CPL0", bytes(pal))

    vqfr1_body = cpl0 + chunk(b"CBFZ", cb1z) + chunk(b"VPTZ", vpt1z)
    vqfr2_body = cpl0 + chunk(b"CBPZ", cb2z) + chunk(b"VPTZ", vpt2z)
    vqfr3_body = cpl0 + chunk(b"VPTZ", vpt3z)

    vqfr1 = chunk(b"VQFR", vqfr1_body)
    vqfr2 = chunk(b"VQFR", vqfr2_body)
    vqfr3 = chunk(b"VQFR", vqfr3_body)

    # VQHD header: exactly 42 bytes (matching real RA VQA files) so ffmpeg can parse it
    # Fields up to 'bits' = 28 bytes; 14 zero bytes follow for unk/reserved fields.
    vqhd_body = struct.pack(
        "<HHHHHBBBBHHHHHHBBxx",
        2,  # version
        0,  # flags
        3,  # numFrames
        width,  # width
        height,  # height
        blockW,  # blockW
        blockH,  # blockH
        15,  # fps
        1,  # cbParts (1 = completes immediately on first CBPZ)
        256,  # numColors
        4,  # maxBlocks
        0,
        0,
        0,  # unk1, unk2, unk3
        22050,  # freq
        1,  # channels
        8,  # bits
        # 2 pad bytes → 30 bytes; then extend to 42
    ) + bytes(12)  # pad to 42 total
    vqhd = chunk(b"VQHD", vqhd_body)

    # FINF: 3 dummy frame offsets (decoder skips FINF entirely)
    finf = chunk(b"FINF", struct.pack("<III", 0, 0, 0))

    # Assemble WVQA container
    wvqa_body = b"WVQA" + vqhd + finf + vqfr1 + vqfr2 + vqfr3
    form = b"FORM" + be32(len(wvqa_body)) + wvqa_body

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "wb") as f:
        f.write(form)
    print(f"Generated {path} ({len(form)} bytes)")
    print(f"  {width}x{height} px, {blockW}x{blockH} blocks, 3 frames, cbParts=1")


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "e2e/goldens/vqa/test.vqa"
    make_vqa(out)
